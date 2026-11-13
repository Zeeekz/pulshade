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
        let invite = try Invite(kind: .channel, identity: id, sendID: Mailbox.make().sendID)
        let parsed = try #require(Invite(code: invite.code))
        #expect(parsed == invite)
        #expect(parsed.fingerprint == id.fingerprint)
    }

    // MARK: SEC-104

    /// An invite is only an invite if its signing key vouches for the agreement key it carries.
    @Test func anInviteMustCarryTheSigningKeysBindingForItsAgreementKey() throws {
        let alice = Identity.generate(), mallory = Identity.generate()
        let send = Mailbox.make().sendID
        let good = try Invite(kind: .contact, identity: alice, sendID: send)
        #expect(Invite(code: good.code) == good)
        // Her signing key with someone else's agreement key (and either one's binding) is refused.
        let swapped = Invite(kind: .contact, signingKey: alice.card.signing, agreementKey: mallory.card.agreement,
                             bind: good.bind, pqHash: good.pqHash, sendID: send)
        #expect(Invite(code: swapped.code) == nil)
        let ownBind = Invite(kind: .contact, signingKey: alice.card.signing, agreementKey: mallory.card.agreement,
                             bind: try EnvelopeCore.bind(signing: mallory.signingKey, agreement: mallory.card.agreement), pqHash: good.pqHash, sendID: send)
        #expect(Invite(code: ownBind.code) == nil)
        let blank = Invite(kind: .contact, signingKey: alice.card.signing, agreementKey: alice.card.agreement,
                           bind: Data(count: 64), pqHash: good.pqHash, sendID: send)
        #expect(Invite(code: blank.code) == nil, "an empty signature is not one")
        // A code changed after it was made no longer opens.
        var chars = Array(good.code)
        chars[chars.count / 2] = chars[chars.count / 2] == "a" ? "b" : "a"
        #expect(Invite(code: String(chars)) == nil)
    }

    @Test func anInviteFromBeforeSigningIsRefusedAndRecognisedAsOld() throws {
        let id = Identity.generate()
        let old = "psh1" + Base32.encode(Data([1]) + id.card.signing + id.card.agreement + Mailbox.make().sendID).lowercased()
        #expect(Invite(code: old) == nil)
        #expect(Invite.isOutdated(old) && Invite.isOutdated("pulshade://invite/" + old))
        #expect(!Invite.isOutdated(try Invite(kind: .contact, identity: id, sendID: Mailbox.make().sendID).code))
        #expect(!Invite.isOutdated("hello"))
    }

    @Test func theSafetyCodeCoversBothAgreementKeys() {
        let ka = Data(repeating: 1, count: 32), kb = Data(repeating: 2, count: 32), kc = Data(repeating: 3, count: 32)
        let base = SafetyCode(mine: "aaa", mineAgreement: ka, minePQ: Data(), theirs: "bbb", theirsAgreement: kb, theirsPQ: Data())
        #expect(SafetyCode(mine: "aaa", mineAgreement: ka, minePQ: Data(), theirs: "bbb", theirsAgreement: kc, theirsPQ: Data()) != base, "their agreement key")
        #expect(SafetyCode(mine: "aaa", mineAgreement: kc, minePQ: Data(), theirs: "bbb", theirsAgreement: kb, theirsPQ: Data()) != base, "my agreement key")
    }

    /// SEC-205: the invite commits to the maker's post-quantum keys, inside what its signature covers.
    @Test func anInviteCommitsToThePostQuantumKeysUnderItsSignature() throws {
        let alice = Identity.generate(), mallory = Identity.generate()
        let send = Mailbox.make().sendID
        let good = try Invite(kind: .contact, identity: alice, sendID: send)
        #expect(good.pqHash == alice.pq.pin.commitment && good.pqHash.count == 16)
        #expect(good.pqHash != mallory.pq.pin.commitment)
        #expect(Invite(code: good.code)?.pqHash == good.pqHash)
        // Someone else's keys' hash with her signature is not an invite: the signature covers the hash.
        let swapped = Invite(kind: .contact, signingKey: alice.card.signing, agreementKey: alice.card.agreement, bind: good.bind,
                             pqHash: mallory.pq.pin.commitment, sendID: send)
        #expect(Invite(code: swapped.code) == nil)
        // And a signature made the old way (over the agreement key alone) doesn't do.
        let old = Invite(kind: .contact, signingKey: alice.card.signing, agreementKey: alice.card.agreement,
                         bind: try EnvelopeCore.bind(signing: alice.signingKey, agreement: alice.card.agreement), pqHash: good.pqHash, sendID: send)
        #expect(Invite(code: old.code) == nil)
        // Codes from before the commitment are recognised as old.
        let psh2 = "psh2" + Base32.encode(Data([1]) + alice.card.signing + alice.card.agreement + good.bind + send).lowercased()
        #expect(Invite(code: psh2) == nil && Invite.isOutdated(psh2))
    }

    /// SEC-205: the safety code covers both sides' post-quantum keys.
    @Test func theSafetyCodeCoversBothPostQuantumCommitments() {
        let k = Data(repeating: 1, count: 32), a = Data(repeating: 7, count: 16), b = Data(repeating: 8, count: 16)
        let base = SafetyCode(mine: "aaa", mineAgreement: k, minePQ: a, theirs: "bbb", theirsAgreement: k, theirsPQ: b)
        #expect(SafetyCode(mine: "aaa", mineAgreement: k, minePQ: a, theirs: "bbb", theirsAgreement: k, theirsPQ: a) != base, "their keys")
        #expect(SafetyCode(mine: "aaa", mineAgreement: k, minePQ: b, theirs: "bbb", theirsAgreement: k, theirsPQ: b) != base, "my keys")
        #expect(SafetyCode(mine: "bbb", mineAgreement: k, minePQ: b, theirs: "aaa", theirsAgreement: k, theirsPQ: a) == base, "the same on both screens")
        #expect(SafetyCode(mine: "aaa", mineAgreement: k, minePQ: a, theirs: "bbb", theirsAgreement: k, theirsPQ: Data()) != base, "unknown keys never match")
        #expect(base.scanText.hasPrefix("pshv3:"))
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
            Invite(code: (try! Invite(kind: .contact, identity: id, sendID: Mailbox.make().sendID, relay: relay)).code)
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
        let invite = try Invite(kind: .contact, identity: id, sendID: Mailbox.make().sendID, relay: "file:///etc/passwd")
        #expect(Invite(code: invite.code) == nil)
    }

    @Test func safetyCodeMatchesOnBothSides() {
        let ka = Data(repeating: 1, count: 32), kb = Data(repeating: 2, count: 32)
        let a = SafetyCode(mine: "aaa", mineAgreement: ka, minePQ: Data(), theirs: "bbb", theirsAgreement: kb, theirsPQ: Data())
        let b = SafetyCode(mine: "bbb", mineAgreement: kb, minePQ: Data(), theirs: "aaa", theirsAgreement: ka, theirsPQ: Data())
        #expect(a == b)
        #expect(a.emoji.count == 10 && a.scanText.hasPrefix("pshv3:"))
        #expect(SafetyCode(mine: "aaa", mineAgreement: ka, minePQ: Data(), theirs: "ccc", theirsAgreement: kb, theirsPQ: Data()) != a)
    }

    @Test func shortAndBrandHandlesAreReserved() {
        #expect(DirectoryProfile.validHandle("@1") == "1")
        #expect(DirectoryProfile.isReserved("1") && DirectoryProfile.isReserved("zeekz"))
        #expect(!DirectoryProfile.isReserved("nova"))
        #expect(DirectoryProfile.validHandle("no spaces") == nil)
    }
}
