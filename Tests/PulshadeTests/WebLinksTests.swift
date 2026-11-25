import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Web links (`https://<domain>/name`, `/+code`) and the signed public names of groups and channels.
@Suite(.serialized)
struct WebLinksTests {
    private func withDomain<T>(_ domain: String?, _ body: () throws -> T) rethrows -> T {
        WebLinks.domainOverride = domain
        defer { WebLinks.domainOverride = nil }
        return try body()
    }

    private func groupCode(owner: Curve25519.Signing.PrivateKey) -> GroupLinkCode {
        GroupLinkCode(secret: .random(32), check: joinCheck(owner.publicKey.rawRepresentation))
    }

    @Test func linksParseBackToWhatTheyOpen() throws {
        try withDomain("Pul.sh") {
            #expect(WebLinks.domain == "pul.sh")
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova")!) == .name("nova", keyCheck: nil))
            #expect(WebLinks.parse(URL(string: "https://www.pul.sh/nova/")!) == .name("nova", keyCheck: nil))
            #expect(WebLinks.parse(URL(string: "https://pul.sh/Nova")!) == .name("nova", keyCheck: nil), "a name typed with capitals still opens")
            #expect(WebLinks.parse(URL(string: "http://pul.sh/nova")!) == nil, "https only")
            #expect(WebLinks.parse(URL(string: "https://evil.sh/nova")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh.evil.sh/nova")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova/extra")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/no-dashes")!) == nil)

            let code = groupCode(owner: .init())
            let link = WebLinks.group(code)
            #expect(link == "https://pul.sh/i/" + code.text, "a plain path that WhatsApp and the rest leave alone")
            #expect(WebLinks.parse(URL(string: link)!) == .group(code))
            #expect(WebLinks.parse(URL(string: "https://pul.sh/+#" + code.text)!) == .group(code), "links made before still open")
            #expect(WebLinks.parse(URL(string: "https://pul.sh/+" + code.text)!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/i/" + code.text + "#x")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/i/abc")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/x/" + code.text)!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/+#abc")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/+")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/#" + code.text)!) == .group(code), "the + dropped by some apps")
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova#" + code.text)!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/%2B#" + code.text)!) == nil, "an escaped + isn't one")
            #expect(WebLinks.parse(URL(string: "https://pul.sh/a%2Fb")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh:8443/nova")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://x@pul.sh/nova")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova?x=1")!) == nil)

            let invite = try Invite(kind: .channel, identity: .generate(), sendID: .random(32), channel: UUID()).code
            #expect(WebLinks.parse(URL(string: WebLinks.invite(invite))!) == .invite(invite))
            #expect(WebLinks.name("nova") == "https://pul.sh/nova")

            // A profile link keeps its key check; nothing else may follow a name.
            let me = Identity.generate()
            let profile = WebLinks.profile("nova", key: me.card.signing)
            let check = DirectoryProfile.keyCheck(of: me.card.signing)
            #expect(profile == "https://pul.sh/nova?k=" + check)
            #expect(WebLinks.parse(URL(string: profile)!) == .name("nova", keyCheck: check))
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova?k=xyz")!) == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova?k=\(check)&x=1")!) == nil)

            // A friend invite and a one-time chat, both after #.
            let friend = try Invite(kind: .contact, identity: .generate(), sendID: .random(32)).code
            #expect(WebLinks.parse(URL(string: WebLinks.invite(friend))!) == .invite(friend))
            let chat = ChatLink(invite: friend, endsAt: Date().addingTimeInterval(3600))
            let chatLink = WebLinks.chat(chat)
            #expect(chatLink.hasPrefix("https://pul.sh/i/pshchat1"))
            #expect(WebLinks.parse(URL(string: chatLink)!) == .chat(try #require(ChatLink(chat.text))))
        }
    }

    @Test func withoutADomainLinksStayPulshadeOnes() throws {
        try withDomain("") {
            #expect(WebLinks.domain == nil)
            let code = groupCode(owner: .init())
            #expect(WebLinks.group(code) == code.link)
            #expect(WebLinks.name("nova") == nil)
            #expect(WebLinks.parse(URL(string: "https://pul.sh/nova")!) == nil)
            let invite = try Invite(kind: .channel, identity: .generate(), sendID: .random(32), channel: UUID()).code
            #expect(WebLinks.invite(invite) == Invite.link(invite))
            #expect(WebLinks.profile("nova") == DirectoryProfile.link("nova"))
        }
    }

    @Test func badDomainsAreIgnored() {
        for bad in ["localhost", "a b.com", "pul.sh/x", ".pul.sh", "pul.sh.", "-pul.sh", "pül.sh"] {
            #expect(WebLinks.validDomain(bad) == nil, "\(bad)")
        }
        #expect(WebLinks.validDomain(" Links.Pulshade.app ") == "links.pulshade.app")
    }

    @Test func aGroupNameChecksOutAndOnlyForItsOwnersGroup() throws {
        let owner = Curve25519.Signing.PrivateKey()
        let group = UUID()
        let code = groupCode(owner: owner)
        let (card, key) = try PublicNameCard.make(.group, handle: "chess", code: code.text, anchor: owner, conversation: group)
        let entry = try card.entry(signedWith: key, updated: 1_000)
        #expect(PublicNameCard.verified(entry, handle: "chess") == card)
        #expect(PublicNameCard.verified(entry, handle: "chesss") == nil, "listed under another name")

        // Not a person's profile, for apps that only know those.
        let blob = try #require(Data(base64Encoded: entry.blob))
        #expect((try? JSONDecoder.pulshade.decode(DirectoryProfile.self, from: blob)) == nil)

        // Pointing at a link of someone else's group: its check names another owner.
        let other = groupCode(owner: .init())
        let (stolen, stolenKey) = try PublicNameCard.make(.group, handle: "chess", code: other.text, anchor: owner, conversation: group)
        #expect(PublicNameCard.verified(try stolen.entry(signedWith: stolenKey, updated: 1_000), handle: "chess") == nil)

        // Signed by a key the anchor didn't vouch for.
        let stranger = Curve25519.Signing.PrivateKey()
        var forged = card
        forged.nameKey = stranger.publicKey.rawRepresentation
        #expect(PublicNameCard.verified(try forged.entry(signedWith: stranger, updated: 1_000), handle: "chess") == nil)

        // Vouched for by someone who isn't the owner the link names.
        let impostor = Curve25519.Signing.PrivateKey()
        let (fake, fakeKey) = try PublicNameCard.make(.group, handle: "chess", code: code.text, anchor: impostor, conversation: group)
        #expect(PublicNameCard.verified(try fake.entry(signedWith: fakeKey, updated: 1_000), handle: "chess") == nil)

        // A changed code in a signed entry.
        var changed = try JSONDecoder.pulshade.decode(PublicNameCard.self, from: blob)
        changed.code = groupCode(owner: owner).text
        let tampered = RelayClient.DirectoryEntry(key: entry.key, blob: try JSONEncoder.pulshade.encode(changed).base64EncodedString(),
                                                  sig: entry.sig, updated: entry.updated)
        #expect(PublicNameCard.verified(tampered, handle: "chess") == nil)
    }

    @Test func aChannelNameOnlyOpensItsAdminsCode() throws {
        let admin = Identity.generate()
        let code = try Invite(kind: .channel, identity: admin, sendID: .random(32), channel: UUID()).code
        let channel = UUID()
        let (card, key) = try PublicNameCard.make(.channel, handle: "news", code: code, anchor: admin.signingKey, conversation: channel)
        #expect(PublicNameCard.verified(try card.entry(signedWith: key, updated: 5), handle: "news") == card)

        let someoneElse = try Invite(kind: .channel, identity: .generate(), sendID: .random(32), channel: UUID()).code
        let (other, otherKey) = try PublicNameCard.make(.channel, handle: "news", code: someoneElse, anchor: admin.signingKey, conversation: channel)
        #expect(PublicNameCard.verified(try other.entry(signedWith: otherKey, updated: 5), handle: "news") == nil)

        let contactCode = try Invite(kind: .contact, identity: admin, sendID: .random(32)).code
        let (contact, contactKey) = try PublicNameCard.make(.channel, handle: "news", code: contactCode, anchor: admin.signingKey, conversation: channel)
        #expect(PublicNameCard.verified(try contact.entry(signedWith: contactKey, updated: 5), handle: "news") == nil, "only a channel's code")
    }

    @Test func aNameCarriesWhatItsPageShows() throws {
        let owner = Curve25519.Signing.PrivateKey()
        let shown = PublicNameCard.Shown(title: String(repeating: "t", count: 300), about: "Late chats", picture: Data([0xFF, 0xD8, 0xFF]),
                                         members: 12)
        let (card, key) = try PublicNameCard.make(.group, handle: "owls", code: groupCode(owner: owner).text, anchor: owner,
                                                  conversation: UUID(), shown: shown)
        #expect(card.title?.count == PublicNameCard.maxTitle && card.about == "Late chats" && card.members == 12)
        #expect(PublicNameCard.verified(try card.entry(signedWith: key, updated: 1), handle: "owls") == card)

        // Too much to show is refused, even when signed.
        var big = card
        big.picture = Data(count: PublicNameCard.maxPicture + 1)
        #expect(PublicNameCard.verified(try big.entry(signedWith: key, updated: 1), handle: "owls") == nil)

        // A channel never says how many follow it.
        let admin = Identity.generate()
        let code = try Invite(kind: .channel, identity: admin, sendID: .random(32), channel: UUID()).code
        let (channel, _) = try PublicNameCard.make(.channel, handle: "news", code: code, anchor: admin.signingKey, conversation: UUID(), shown: shown)
        #expect(channel.members == nil)

        // A change to anything shown is noticed.
        var other = shown
        other.members = 13
        #expect(shown.digest != other.digest && shown.digest == shown.digest)
    }

    @Test func eachConversationHasItsOwnNameKey() {
        let anchor = Curve25519.Signing.PrivateKey()
        let a = UUID(), b = UUID()
        let keyA = PublicNameCard.nameKey(anchor: anchor, kind: .group, conversation: a).publicKey.rawRepresentation
        #expect(keyA == PublicNameCard.nameKey(anchor: anchor, kind: .group, conversation: a).publicKey.rawRepresentation, "the same on every device")
        #expect(keyA != PublicNameCard.nameKey(anchor: anchor, kind: .group, conversation: b).publicKey.rawRepresentation)
        #expect(keyA != PublicNameCard.nameKey(anchor: anchor, kind: .channel, conversation: a).publicKey.rawRepresentation)
        #expect(keyA != anchor.publicKey.rawRepresentation)
    }
}
