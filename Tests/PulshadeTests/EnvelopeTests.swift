import Testing
import Foundation
@testable import Pulshade

@Suite struct EnvelopeTests {
    let alice = Identity.generate()
    let bob = Identity.generate()

    private func message(_ text: String) -> Payload {
        .message(WireMessage(id: UUID(), conversation: nil, kind: .direct, text: text, image: nil, date: Date(timeIntervalSince1970: 1_800_000_000)))
    }

    @Test func roundTripRevealsSenderOnlyInside() throws {
        let payload = message("hi bob")
        let blob = try Envelope.seal(payload, from: alice, to: bob.recipient, introduce: true)
        let (opened, signer) = try Envelope.open(blob, with: bob)
        #expect(opened == payload)
        #expect(signer == alice.card.signing)
        // Neither key appears on the outside.
        #expect(blob.range(of: alice.card.signing) == nil)
        #expect(blob.range(of: alice.card.agreement) == nil)
    }

    @Test func wrongRecipientCannotOpen() throws {
        let blob = try Envelope.seal(message("secret"), from: alice, to: bob.recipient)
        #expect(throws: (any Error).self) { try Envelope.open(blob, with: Identity.generate()) }
    }

    @Test func tamperingIsDetected() throws {
        var blob = try Envelope.seal(message("x"), from: alice, to: bob.recipient)
        blob[blob.count / 2] ^= 0x01
        #expect(throws: (any Error).self) { try Envelope.open(blob, with: bob) }
    }

    /// Framed, a big message goes without base64 round it: it opens the same, and takes about what it holds
    /// rather than nearly twice that. Sealed the old way it still opens, for apps that haven't updated.
    @Test func aFramedEnvelopeCarriesBigBytesRawAndOpensTheSame() throws {
        let bytes = Data((0..<400_000).map { _ in UInt8.random(in: 0...255) })
        let header = RatchetHeader(dh: Data(repeating: 7, count: 32), pn: 3, n: 9)
        let payload = Payload.ratchet(RatchetMessage(header: header, ciphertext: bytes))
        let framed = try Envelope.seal(payload, from: alice, device: Data([1, 2]), to: bob.recipient, framed: true)
        let plain = try Envelope.seal(payload, from: alice, device: Data([1, 2]), to: bob.recipient)
        for blob in [framed, plain] {
            let opened = try Envelope.openFull(blob, with: bob)
            #expect(opened.payload == payload && opened.signer == alice.card.signing && opened.device == Data([1, 2]))
            #expect(opened.readsFrames, "every envelope says its sender reads frames")
        }
        #expect(framed.count < 600_000, "400 KB fits the 512 KB bucket")
        #expect(plain.count > 2_000_000, "base64 twice over pushed it into the 2 MiB one")
        var broken = framed
        broken[broken.count / 2] ^= 0x01
        #expect(throws: (any Error).self) { try Envelope.open(broken, with: bob) }
    }

    @Test func framesAreReadStrictly() throws {
        let part = Payload.storyPart(id: UUID(), index: 1, of: 2, bytes: Data([9, 8, 7, 0, 1]))
        #expect(try Payload.fromWire(part.wire(framed: true)) == part)
        #expect(try Payload.fromWire(part.wire(framed: false)) == part)
        #expect(try part.wire(framed: true).first == Frame.mark)
        // Short payloads have nothing worth framing, and stay plain JSON.
        #expect(try message("hi").wire(framed: true).first == UInt8(ascii: "{"))
        // A length that runs past the end, a frame round something that has no big field, and a bare mark are refused.
        #expect(Frame.split(Data([0, 0, 0, 0, 9, 1, 2])) == nil)
        #expect(throws: (any Error).self) { try Payload.fromWire(Frame.join(JSONEncoder.pulshade.encode(message("hi")), Data([1]))) }
        #expect(throws: (any Error).self) { try Payload.fromWire(Data([0])) }
    }

    @Test func sizesAreBucketed() throws {
        let short = try Envelope.seal(message("a"), from: alice, to: bob.recipient)
        let longer = try Envelope.seal(message(String(repeating: "b", count: 900)), from: alice, to: bob.recipient)
        #expect(short.count == longer.count)
    }

    @Test func sameMessageLooksDifferentEachTime() throws {
        let p = message("same")
        let a = try Envelope.seal(p, from: alice, to: bob.recipient)
        let b = try Envelope.seal(p, from: alice, to: bob.recipient)
        #expect(a != b)
    }

    @Test func anyoneElseClaimingToBeTheSenderIsRefused() throws {
        // Mallory pairs Alice's signing key with her own agreement key: the binding doesn't check out.
        let mallory = Identity.generate()
        let blob = try Envelope.seal(message("trust me"), from: mallory, to: bob.recipient, introduce: true)
        let (_, signer) = try Envelope.open(blob, with: bob)
        #expect(signer == mallory.card.signing && signer != alice.card.signing)
    }

    @Test func relaysMustUseHTTPSOutsideYourNetwork() {
        #expect(Invite.validRelay("http://203.0.113.5:7878") == nil)
        #expect(Invite.validRelay("http://relay.example.com") == nil)
        #expect(Invite.validRelay("https://relay.example.com") != nil)
        #expect(Invite.validRelay("http://192.168.1.20:7878") != nil)
        #expect(Invite.validRelay("http://127.0.0.1:7878") != nil)
        #expect(Invite.validRelay("http://my-mac.local:7878") != nil)
        // Tor encrypts an onion service end to end, so plain http is fine there.
        #expect(Invite.validRelay("http://pulshadexyz.onion") != nil)
        #expect(Invite.validRelay("http://relay.onion.example.com") == nil)
    }

    @Test func chatCodesAreTwentyDigitsSealedToAFixedSize() throws {
        let code = ChatCode.make()
        #expect(code.digits.count == 20 && code.digits.allSatisfy(\.isNumber))
        #expect(ChatCode(code.display) == code)
        #expect(ChatCode("1234-5678-9012-3456-7890")?.display == "1234 5678 9012 3456 7890")
        #expect(ChatCode("1234 5678 9012 3456 789") == nil)
        #expect(ChatCode("pshchat1abc") == nil)
        // SEC-107: twelve digits, from an older app, are refused and recognised as old, never used.
        #expect(ChatCode("1234 5678 9012") == nil && ChatCode.isOutdated("1234 5678 9012") && !ChatCode.isOutdated(code.display))
        #expect(Set((0..<50).map { _ in ChatCode.make().digits }).count == 50)

        let link = ChatLink(invite: try Invite(kind: .contact, identity: .generate(), sendID: .random(32)).code,
                            endsAt: Date(timeIntervalSince1970: Date().addingTimeInterval(600).timeIntervalSince1970.rounded(.down)))
        let (_, seal) = code.keys()
        let blob = try #require(ChatCode.seal(link, with: seal))
        #expect(blob.count == ChatCode.sealedSize + 28)
        #expect(ChatCode.open(blob, with: seal) == link)
        #expect(ChatCode.open(blob, with: ChatCode.make().keys().seal) == nil)
    }

    @Test func profilesCarryBannersAndOlderOnesStillRead() throws {
        let banner = Data(repeating: 7, count: 64)
        let sent = Payload.profile(name: "Ann", avatar: nil, color: 2, banner: banner)
        #expect(try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(sent)) == sent)
        // From an app before banners: no banner field at all.
        let old = Data(#"{"profile":{"name":"Ann","color":2}}"#.utf8)
        #expect(try JSONDecoder.pulshade.decode(Payload.self, from: old) == .profile(name: "Ann", avatar: nil, color: 2, banner: nil))
    }
}
