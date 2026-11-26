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

    /// Channel codes that name their channel have their own kind byte, which apps from before read as no code at all.
    /// One from a newer app than this is met with "update", not "isn't a code"; this version's own codes aren't.
    @Test func anInviteFromANewerAppSaysToUpdate() throws {
        let id = Identity.generate()
        let named = try Invite(kind: .channel, identity: id, sendID: Mailbox.make().sendID, channel: UUID()).code
        let contact = try Invite(kind: .contact, identity: id, sendID: Mailbox.make().sendID).code
        #expect(!Invite.isFromNewer(named) && !Invite.isFromNewer(contact) && !Invite.isFromNewer("hello"))
        // A kind byte this version doesn't know, as kind 3 was to the apps before it.
        var raw = Base32.decode(String(named.dropFirst(4)).uppercased())!
        raw[raw.startIndex] = 9
        let unknownKind = "psh3" + Base32.encode(raw).lowercased()
        #expect(Invite(code: unknownKind) == nil && Invite.isFromNewer(unknownKind) && Invite.isFromNewer("pulshade://invite/" + unknownKind))
        #expect(Invite.problem(with: unknownKind) == Invite.newerNotice)
        // A later format number.
        #expect(Invite.isFromNewer("psh4" + String(named.dropFirst(4))))
        #expect(Invite.problem(with: "hello") == "That isn't a PULSHADE code.")
        #expect(Invite.problem(with: "psh1abc") == Invite.outdatedNotice)
        // What the pulsh.me page checks to say "update first" (the page's needsUpdate check).
        let bytes = Base32.decode(String(named.dropFirst(4)).uppercased())!
        #expect(bytes.first == 3 && bytes.count >= 193)
    }

    @Test func theSafetyCodeCoversBothAgreementKeys() {
        let ka = Data(repeating: 1, count: 32), kb = Data(repeating: 2, count: 32), kc = Data(repeating: 3, count: 32)
        let s = Data(repeating: 9, count: 32)
        func party(_ account: String, _ agreement: Data) -> SafetyCode.Party { .init(account: account, signing: s, agreement: agreement, pq: nil) }
        let base = SafetyCode(mine: party("aaa", ka), theirs: party("bbb", kb))
        #expect(SafetyCode(mine: party("aaa", ka), theirs: party("bbb", kc)) != base, "their agreement key")
        #expect(SafetyCode(mine: party("aaa", kc), theirs: party("bbb", kb)) != base, "my agreement key")
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
    @Test func theSafetyCodeCoversBothPostQuantumKeys() {
        let alice = Identity.generate(), bob = Identity.generate()
        func party(_ id: Identity, pq: PQPin?) -> SafetyCode.Party {
            .init(account: id.fingerprint, signing: id.card.signing, agreement: id.card.agreement, pq: pq)
        }
        let a = party(alice, pq: alice.pq.pin), b = party(bob, pq: bob.pq.pin)
        let base = SafetyCode(mine: a, theirs: b)
        #expect(SafetyCode(mine: a, theirs: party(bob, pq: alice.pq.pin)).digits != base.digits, "their keys")
        #expect(SafetyCode(mine: party(alice, pq: bob.pq.pin), theirs: b).digits != base.digits, "my keys")
        #expect(SafetyCode(mine: b, theirs: a).digits == base.digits, "the same on both screens")
        #expect(SafetyCode(mine: a, theirs: party(bob, pq: nil)).digits != base.digits, "unknown keys never match")
        #expect(base.scanText.hasPrefix("pshv4:"))
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
        let ka = Data(repeating: 1, count: 32), kb = Data(repeating: 2, count: 32), s = Data(repeating: 9, count: 32)
        let pa = SafetyCode.Party(account: "aaa", signing: s, agreement: ka), pb = SafetyCode.Party(account: "bbb", signing: s, agreement: kb)
        let a = SafetyCode(mine: pa, theirs: pb)
        let b = SafetyCode(mine: pb, theirs: pa)
        #expect(a.digits == b.digits && a.emoji == b.emoji && a.digits.count == 12)
        #expect(a.emoji.count == 10 && a.scanText.hasPrefix("pshv4:"))
        #expect(a.check(scanned: b.scanText) == .match && b.check(scanned: a.scanText) == .match)
        #expect(SafetyCode(mine: pa, theirs: .init(account: "ccc", signing: s, agreement: kb)).digits != a.digits)
    }

    @Test func shortAndBrandHandlesAreReserved() {
        #expect(DirectoryProfile.validHandle("@1") == "1")
        #expect(DirectoryProfile.isReserved("1") && DirectoryProfile.isReserved("zeekz"))
        #expect(!DirectoryProfile.isReserved("nova"))
        #expect(DirectoryProfile.validHandle("no spaces") == nil)
    }
}
