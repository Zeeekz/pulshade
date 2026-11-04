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
        let blob = try Envelope.seal(payload, from: alice, to: bob.card.agreement)
        let (opened, signer) = try Envelope.open(blob, with: bob)
        #expect(opened == payload)
        #expect(signer == alice.card.signing)
        // Neither key appears on the outside.
        #expect(blob.range(of: alice.card.signing) == nil)
        #expect(blob.range(of: alice.card.agreement) == nil)
    }

    @Test func wrongRecipientCannotOpen() throws {
        let blob = try Envelope.seal(message("secret"), from: alice, to: bob.card.agreement)
        #expect(throws: (any Error).self) { try Envelope.open(blob, with: Identity.generate()) }
    }

    @Test func tamperingIsDetected() throws {
        var blob = try Envelope.seal(message("x"), from: alice, to: bob.card.agreement)
        blob[blob.count / 2] ^= 0x01
        #expect(throws: (any Error).self) { try Envelope.open(blob, with: bob) }
    }

    @Test func sizesAreBucketed() throws {
        let short = try Envelope.seal(message("a"), from: alice, to: bob.card.agreement)
        let longer = try Envelope.seal(message(String(repeating: "b", count: 900)), from: alice, to: bob.card.agreement)
        #expect(short.count == longer.count)
    }

    @Test func sameMessageLooksDifferentEachTime() throws {
        let p = message("same")
        let a = try Envelope.seal(p, from: alice, to: bob.card.agreement)
        let b = try Envelope.seal(p, from: alice, to: bob.card.agreement)
        #expect(a != b)
    }

    @Test func anyoneElseClaimingToBeTheSenderIsRefused() throws {
        // Mallory pairs Alice's signing key with her own agreement key: the binding doesn't check out.
        let mallory = Identity.generate()
        let blob = try Envelope.seal(message("trust me"), from: mallory, to: bob.card.agreement)
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

    @Test func chatCodesAreTwelveDigitsSealedToAFixedSize() throws {
        let code = ChatCode.make()
        #expect(code.digits.count == 12 && code.digits.allSatisfy(\.isNumber))
        #expect(ChatCode(code.display) == code)
        #expect(ChatCode("1234-5678-9012")?.display == "1234 5678 9012")
        #expect(ChatCode("1234 5678 901") == nil)
        #expect(ChatCode("pshchat1abc") == nil)

        let link = ChatLink(invite: Invite(kind: .contact, signingKey: .random(32), agreementKey: .random(32), sendID: .random(32)).code,
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
