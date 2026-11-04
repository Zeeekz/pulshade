import Testing
import Foundation
@testable import Pulshade

@Suite(.serialized) struct IdentityTests {
    @Test func recoveryCodeRoundTrips() throws {
        let id = Identity.generate()
        let seed = try #require(Identity.seed(fromRecoveryCode: id.recoveryCode))
        #expect(seed == id.seed)
        let restored = try Identity(seed: seed)
        #expect(restored.fingerprint == id.fingerprint)
    }

    @Test func recoveryCodeRejectsTypos() {
        var code = Array(Identity.generate().recoveryCode)
        code[3] = code[3] == "A" ? "B" : "A"
        #expect(Identity.seed(fromRecoveryCode: String(code)) == nil)
    }

    @Test func recoveryCodeIgnoresCaseAndSpacing() throws {
        let id = Identity.generate()
        let messy = id.recoveryCode.lowercased().replacingOccurrences(of: " ", with: "-")
        #expect(Identity.seed(fromRecoveryCode: messy) == id.seed)
    }

    @Test func inviteRoundTrips() throws {
        let id = Identity.generate()
        let invite = Invite(kind: .channel, signingKey: id.card.signing, agreementKey: id.card.agreement,
                            sendID: Mailbox.make().sendID)
        let parsed = try #require(Invite(code: invite.code))
        #expect(parsed == invite)
        #expect(parsed.fingerprint == id.fingerprint)
    }

    @Test func sendIDDoesNotRevealReceiveKey() {
        let box = Mailbox.make()
        #expect(box.sendID != box.receiveKey)
        #expect(Mailbox.sendID(for: box.receiveKey) == box.sendID)
    }

    @Test func garbageInviteIsRejected() {
        #expect(Invite(code: "psh1hello") == nil)
        #expect(Invite(code: "") == nil)
    }

    @Test func derivedKeysDiffer() {
        let id = Identity.generate()
        #expect(id.signingKey.rawRepresentation != id.agreementKey.rawRepresentation)
    }

    /// The official app only ever uses Pulshade's own relay: an invite or code naming another is refused.
    @Test func onlyOfficialRelaysAreUsed() throws {
        let was = Invite.officialRelaysOnly
        Invite.officialRelaysOnly = true
        defer { Invite.officialRelaysOnly = was }
        let id = Identity.generate()
        func invite(_ relay: String?) -> Invite? {
            Invite(code: Invite(kind: .contact, signingKey: id.card.signing, agreementKey: id.card.agreement,
                                sendID: Mailbox.make().sendID, relay: relay).code)
        }
        #expect(invite("https://relay.crew.example") == nil, "Someone else's relay")
        #expect(invite(nil) != nil, "No relay named: Pulshade's own")
        #expect(try #require(invite(AppData.defaultRelay)).relay == AppData.defaultRelay)
        #expect(Invite.allowedRelay(AppData.defaultRelay + "/") != nil)
        #expect(Invite.allowedRelay("http://192.168.1.20:7878") == nil, "Not even one on your own network")
        let link = LinkCode(secret: Data(count: 32), sendID: Data(count: 32), relay: "https://relay.crew.example")
        #expect(LinkCode(link.text) == nil, "Linking codes too")
    }

    /// With a direct address, Pulshade's relay is reached by onion over Tor and directly with Tor off;
    /// without one, always by onion. Other relays never change.
    @Test func pulshadesRelayIsRoutedByTheTorSetting() throws {
        let onion = AppData.defaultRelay
        #expect(Invite.route(onion, overTor: false) == onion, "No direct address yet: onion only")
        setenv("PULSHADE_TEST_RELAY_DIRECT", "https://relay.pulshade.example", 1)
        defer { unsetenv("PULSHADE_TEST_RELAY_DIRECT") }
        #expect(Invite.route(onion, overTor: true) == onion)
        #expect(Invite.route(onion, overTor: false) == "https://relay.pulshade.example")
        #expect(Invite.route("https://relay.pulshade.example", overTor: true) == onion, "Either address, same relay")
        #expect(Invite.isPulshadeRelay("https://relay.pulshade.example/"))
        #expect(Invite.route("https://other.example", overTor: false) == "https://other.example")
        let was = Invite.officialRelaysOnly
        Invite.officialRelaysOnly = true
        defer { Invite.officialRelaysOnly = was }
        #expect(Invite.allowedRelay("https://relay.pulshade.example") != nil)
        #expect(Invite.allowedRelay("https://other.example") == nil)
    }

    @Test func strangeRelaysAreRefused() throws {
        let id = Identity.generate()
        let invite = Invite(kind: .contact, signingKey: id.card.signing, agreementKey: id.card.agreement,
                            sendID: Mailbox.make().sendID, relay: "file:///etc/passwd")
        #expect(Invite(code: invite.code) == nil)
    }

    @Test func safetyCodeMatchesOnBothSides() {
        let a = SafetyCode(mine: "aaa", theirs: "bbb")
        let b = SafetyCode(mine: "bbb", theirs: "aaa")
        #expect(a == b)
        #expect(a.emoji.count == 10 && a.scanText.hasPrefix("pshv1:"))
        #expect(SafetyCode(mine: "aaa", theirs: "ccc") != a)
    }

    @Test func shortAndBrandHandlesAreReserved() {
        #expect(DirectoryProfile.validHandle("@1") == "1")
        #expect(DirectoryProfile.isReserved("1") && DirectoryProfile.isReserved("zeekz"))
        #expect(!DirectoryProfile.isReserved("nova"))
        #expect(DirectoryProfile.validHandle("no spaces") == nil)
    }
}
