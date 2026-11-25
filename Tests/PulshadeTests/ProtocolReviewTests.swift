import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Fixes from the review of one-to-one encryption, key checks, calls, backups and files (2026-11-24), without a relay.
@Suite struct ProtocolReviewTests {
    // MARK: Pulse check: a fingerprint per person (#2)

    private func party(_ id: Identity, pq: PQPin? = nil) -> SafetyCode.Party {
        .init(account: id.fingerprint, signing: id.card.signing, agreement: id.card.agreement, pq: pq ?? id.pq.pin)
    }

    /// Each half of the code is one person's own: someone in the middle who swaps Bob's keys changes only Bob's half, so
    /// they'd have to make keys whose fingerprint matches Bob's, not just two codes that match each other.
    @Test func eachPersonHasAFingerprintOfTheirOwn() {
        let alice = Identity.generate(), bob = Identity.generate(), mallory = Identity.generate()
        let real = SafetyCode(mine: party(alice), theirs: party(bob))
        let swapped = SafetyCode(mine: party(alice), theirs: party(mallory))
        #expect(real.mine == swapped.mine, "Alice's half is hers alone")
        #expect(real.theirs != swapped.theirs)
        #expect(SafetyCode.fingerprint(of: party(bob)) == real.theirs, "worked out from Bob's keys alone")
        // A swapped signing key, agreement key, post-quantum key or account each changes Bob's fingerprint.
        var p = party(bob)
        p.signing = mallory.card.signing
        #expect(SafetyCode.fingerprint(of: p) != real.theirs)
        p = party(bob); p.agreement = mallory.card.agreement
        #expect(SafetyCode.fingerprint(of: p) != real.theirs)
        p = party(bob); p.pq = PQPin(kem: bob.pq.pin.kem, dsa: mallory.pq.pin.dsa)
        #expect(SafetyCode.fingerprint(of: p) != real.theirs)
        p = party(bob); p.account = mallory.fingerprint
        #expect(SafetyCode.fingerprint(of: p) != real.theirs)
        #expect(real.digits.count == 12 && real.digits.allSatisfy { $0.count == 5 && $0.allSatisfy(\.isNumber) })
        #expect(Set(real.digits) .isSuperset(of: SafetyCode.digits(of: real.mine)) && Set(real.digits).isSuperset(of: SafetyCode.digits(of: real.theirs)),
                "the 60 digits are both people's 30")
    }

    /// The fingerprint is SHA-512 iterated 5,200 times over the person's keys, as specified in docs/protocol.md.
    @Test func theFingerprintIsTheIteratedHashTheDocsDescribe() {
        let id = Identity.generate()
        func prefixed(_ d: Data) -> Data { withUnsafeBytes(of: UInt32(d.count).bigEndian) { Data($0) } + d }
        let pq = Data(SHA512.hash(data: Data("pulshade.safety.pq".utf8) + id.pq.pin.kem + id.pq.pin.dsa))
        let keys = Data("pulshade.safety.v4".utf8) + prefixed(Data(id.fingerprint.utf8)) + prefixed(id.card.signing)
            + prefixed(id.card.agreement) + prefixed(pq)
        var hash = Data(SHA512.hash(data: Data([0, 4]) + keys))
        for _ in 0..<5_200 { hash = Data(SHA512.hash(data: hash + keys)) }
        #expect(SafetyCode.fingerprint(of: party(id)) == hash.prefix(32))
        #expect(SafetyCode.iterations == 5_200 && SafetyCode.version == 4)
    }

    /// Scanning checks both fingerprints the right way round; a code from an app before this is recognised as old, so the
    /// person is told the other needs to update instead of being shown a mismatch.
    @Test func scanningChecksBothFingerprintsAndSpotsAnOldApp() {
        let alice = Identity.generate(), bob = Identity.generate(), mallory = Identity.generate()
        let mine = SafetyCode(mine: party(alice), theirs: party(bob))
        let theirs = SafetyCode(mine: party(bob), theirs: party(alice))
        #expect(mine.check(scanned: theirs.scanText) == .match)
        #expect(theirs.check(scanned: mine.scanText) == .match)
        #expect(mine.check(scanned: mine.scanText) == .mismatch, "my own screen isn't theirs")
        let fooled = SafetyCode(mine: party(mallory), theirs: party(alice))
        #expect(mine.check(scanned: fooled.scanText) == .mismatch)
        let middle = SafetyCode(mine: party(bob), theirs: party(mallory))
        #expect(mine.check(scanned: middle.scanText) == .mismatch, "Bob holds someone else's keys for Alice")
        #expect(mine.check(scanned: "pshv3:" + Data.random(20).hex) == .outdated)
        #expect(mine.check(scanned: "pshv4:" + Data.random(10).hex) == .mismatch)
        #expect(mine.check(scanned: "hello") == .mismatch)
    }

    // MARK: Ratchet: skipped keys age out, few old chains, a stalled post-quantum ratchet is noticed (#19)

    private func pair() throws -> (alice: Ratchet, bob: Ratchet) {
        let a = Identity.generate(), b = Identity.generate()
        let (pending, request) = try Handshake.start()
        let (bob, answer) = try Handshake.accept(request, me: b, initiatorAgreement: a.card.agreement, initiatorPin: Data(), responderPin: Data())
        let alice = try Handshake.complete(pending, answer, me: a, responderAgreement: b.card.agreement, responderPin: Data())
        return (alice, bob)
    }

    /// A message held back (by the relay, say) can't be opened with the device's state 30 days after its key was kept.
    @Test func keysForSkippedMessagesGoAfterThirtyDays() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        let late = try alice.encrypt(Data("held back".utf8))
        let next = try alice.encrypt(Data("next".utf8))
        _ = try bob.decrypt(next)
        #expect(bob.skippedCount == 1)
        var soon = bob
        soon.dropExpiredSkipped(now: Date().addingTimeInterval(29 * 86_400))
        #expect(try soon.decrypt(late) == Data("held back".utf8), "still readable within the 30 days")
        #expect(bob.hasExpiredSkipped(now: Date().addingTimeInterval(31 * 86_400)))
        bob.dropExpiredSkipped(now: Date().addingTimeInterval(31 * 86_400))
        #expect(bob.skippedCount == 0)
        #expect(throws: (any Error).self) { try bob.decrypt(late) }
    }

    /// Keys are kept for skipped messages of the newest few of the other side's chains only, as libsignal does.
    @Test func onlyTheNewestFewChainsKeepSkippedKeys() throws {
        var (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        var lost: [RatchetMessage] = []
        for round in 0..<(Ratchet.maxSkippedChains + 2) {
            lost.append(try alice.encrypt(Data("lost \(round)".utf8)))
            _ = try bob.decrypt(alice.encrypt(Data("got \(round)".utf8)))
            _ = try alice.decrypt(bob.encrypt(Data("reply \(round)".utf8)))
        }
        #expect(bob.skippedCount == Ratchet.maxSkippedChains)
        var copy = bob
        #expect(throws: (any Error).self) { try copy.decrypt(lost[0]) }
        #expect(throws: (any Error).self) { try copy.decrypt(lost[1]) }
        #expect(try bob.decrypt(lost[2]) == Data("lost 2".utf8))
        #expect(try bob.decrypt(lost.last!) == Data("lost \(lost.count - 1)".utf8))
    }

    /// Sending on and on with no post-quantum secret going in counts as a stall; a chat going both ways never does.
    @Test func aStalledPostQuantumRatchetIsNoticed() throws {
        var (alice, bob) = try pair()
        #expect(!bob.postQuantumStalled)
        for n in 0..<Int(Ratchet.pqStallMessages) - 1 { _ = try bob.encrypt(Data("\(n)".utf8)) }
        #expect(!bob.postQuantumStalled)
        _ = try bob.encrypt(Data("one more".utf8))
        #expect(bob.postQuantumStalled, "200 messages and nothing from the other side")

        (alice, bob) = try pair()
        _ = try alice.decrypt(bob.encrypt(Data("open".utf8)))
        for n in 0..<120 {
            _ = try alice.decrypt(bob.encrypt(Data("b\(n)".utf8)))
            _ = try bob.decrypt(alice.encrypt(Data("a\(n)".utf8)))
        }
        #expect(alice.postQuantumEpochs.offered > 0 && bob.postQuantumEpochs.offered > 0)
        #expect(!alice.postQuantumStalled && !bob.postQuantumStalled)
    }

    /// Messages sent well after the last post-quantum secret went in, with none going in since, count as a stall too.
    @Test func aPostQuantumSecretOverAWeekOldWithMessagesSinceIsAStall() throws {
        var (_, bob) = try pair()
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(bob)) as? [String: Any])
        json["pqAt"] = Date().addingTimeInterval(-8 * 86_400).timeIntervalSinceReferenceDate
        bob = try JSONDecoder().decode(Ratchet.self, from: JSONSerialization.data(withJSONObject: json))
        for n in 0..<Int(Ratchet.pqStallSoonMessages) - 1 { _ = try bob.encrypt(Data("\(n)".utf8)) }
        #expect(!bob.postQuantumStalled, "a few messages after a quiet week are not yet a stall")
        _ = try bob.encrypt(Data("more".utf8))
        #expect(bob.postQuantumStalled)
    }

    // MARK: Calls: a salt per connection (#15)

    /// Two of the callee's devices answering the same call never seal under the same key and nonce, and the caller hears
    /// both.
    @Test func twoAnsweringDevicesNeverShareAKeyAndNonce() throws {
        let key = Data.random(32)
        var caller = CallCrypto(key: key, caller: true)
        var phone = CallCrypto(key: key, caller: false), secondPhone = CallCrypto(key: key, caller: false)
        let body = Data(repeating: 0x41, count: 100)
        let sealedA = phone.seal(.audio, body), sealedB = secondPhone.seal(.audio, body)
        let a = try #require(sealedA), b = try #require(sealedB)
        #expect(a[0] == b[0] && a[(1 + CallCrypto.saltSize)..<CallCrypto.headerSize] == b[(1 + CallCrypto.saltSize)..<CallCrypto.headerSize],
                "the same kind and number")
        #expect(a[1..<(1 + CallCrypto.saltSize)] != b[1..<(1 + CallCrypto.saltSize)], "different salts")
        #expect(a.dropFirst(CallCrypto.headerSize) != b.dropFirst(CallCrypto.headerSize), "so different keys: the same words seal differently")
        #expect(caller.open(a)?.1 == body && caller.open(b)?.1 == body)
        // One device's packet under the other's salt doesn't open: the salt is in the key and the sealed header.
        var moved = b
        moved.replaceSubrange(1..<(1 + CallCrypto.saltSize), with: a[1..<(1 + CallCrypto.saltSize)])
        #expect(caller.open(moved) == nil)
        // A packet in the form from before salts doesn't open.
        let old = Data([1]) + withUnsafeBytes(of: UInt64(9).bigEndian) { Data($0) } + Data.random(CallCrypto.bodySize + 16)
        #expect(caller.open(old) == nil)
    }

    // MARK: Friend request notes aren't signed (#17)

    /// The post-quantum signature on a request covers the card and the ask, not the note: the transcript it signs is
    /// the same whatever the note says (so the note proves nothing to anyone else), while the request still opens whole.
    @Test func aRequestNoteIsLeftOutOfTheSignature() throws {
        let alice = Identity.generate(), bob = Identity.generate()
        let (_, ask) = try Handshake.start()
        let card = PeerCard(name: "Alice", signingKey: alice.card.signing, agreementKey: alice.card.agreement, sendID: Data.random(16),
                            pq: alice.pqCard)
        let payload = Payload.request(card, ask, note: "meet at nine 🌙")
        let blob = try Envelope.seal(payload, from: alice, device: Data([1]), to: bob.recipient)
        let opened = try Envelope.openFull(blob, with: bob, known: { $0 == alice.card.signing ? alice.pq.pin : nil })
        #expect(opened.payload == payload)

        let (one, notes) = try #require(try payload.requestWire())
        #expect(notes == Data("meet at nine 🌙".utf8).count)
        // The recipient could put any other note, of any length, after the same signed part.
        let words = Data("something they never said".utf8)
        let other = Data(one.dropLast(notes)) + words
        #expect(try Payload.fromWire(other) == .request(card, ask, note: "something they never said"))
        func transcript(_ body: Data, _ tail: Int) -> Data {
            EnvelopeCore.signedTranscript(ephemeral: Data(count: 32), kemCiphertext: Data(), recipient: bob.card.agreement,
                                          sender: alice.card.agreement, at: 1, device: Data([1]), body: body, unsignedTail: tail)
        }
        #expect(transcript(one, notes) == transcript(other, words.count), "the note, and its length, aren't in what's signed")
        #expect(transcript(one, notes) != transcript(one, 0), "a signature over a whole payload never stands for one over part")
        // Everything before the note is signed: a changed byte there changes the transcript.
        var changed = one
        changed[8] ^= 1
        #expect(transcript(one, notes) != transcript(changed, notes))
        // A request without a note travels as before, signed whole.
        #expect(try Payload.request(card, ask, note: "").requestWire() == nil)
    }

    /// Only a request's note may be left out of the signature: anything else that says part of it is unsigned is refused.
    @Test func onlyARequestNoteMayGoUnsigned() throws {
        let alice = Identity.generate(), bob = Identity.generate()
        let body = try Payload.erased.wire(framed: false)
        let blob = try EnvelopeCore.sealPQ(body: body, signing: alice.signingKey, agreement: alice.agreementKey, pq: alice.pq, sign: true,
                                           unsignedTail: 3, introduce: false, device: Data([1]), caps: Envelope.reads, at: Date(),
                                           to: bob.recipient)
        #expect(throws: (any Error).self) { try Envelope.openFull(blob, with: bob, known: { _ in alice.pq.pin }) }
        // Nor more than the note of a request.
        let (_, ask) = try Handshake.start()
        let card = PeerCard(name: "A", signingKey: alice.card.signing, agreementKey: alice.card.agreement, sendID: Data.random(16))
        let (framed, notes) = try #require(try Payload.request(card, ask, note: "hi").requestWire())
        let wider = try EnvelopeCore.sealPQ(body: framed, signing: alice.signingKey, agreement: alice.agreementKey, pq: alice.pq, sign: true,
                                            unsignedTail: notes + 5, introduce: false, device: Data([1]), caps: Envelope.reads, at: Date(),
                                            to: bob.recipient)
        #expect(throws: (any Error).self) { try Envelope.openFull(wider, with: bob, known: { _ in alice.pq.pin }) }
    }

    // MARK: Files: a piece is only ever sealed with the bytes it was hashed with

    /// A file changed on disk between being picked and being sent (or before an upload is resumed) isn't sealed again
    /// under the same key and piece nonces: the upload stops instead.
    @Test func aFileChangedBeforeUploadIsNotSealedAgain() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blob-change-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data.random(BlobCrypto.plainPiece + 500).write(to: url)
        let prepared = try BlobTransfer.prepare(url)
        #expect(prepared.pieceHashes.count == 2)
        try Data.random(BlobCrypto.plainPiece + 500).write(to: url)
        // Nothing listens here: the check comes before anything is sent.
        let nowhere = RelayClient(base: try #require(URL(string: "http://127.0.0.1:9")), lane: "blob-change")
        await #expect(throws: BlobError.changed) { try await BlobTransfer.upload(prepared, to: nowhere) { _ in } }
    }

    // MARK: Backups carry a count and a date (#16)

    @MainActor @Test func aSealedBackupCarriesItsCountAndDate() throws {
        let id = Identity.generate()
        var data = AppData()
        data.profile = Profile(name: "Me")
        let first = BackupStamp.next(after: nil)
        let second = BackupStamp.next(after: first)
        #expect(second.counter > first.counter)
        #expect(BackupStamp.next(after: BackupStamp(counter: UInt64.max - 1, madeAt: Date())).counter == UInt64.max)
        let sealed = try AppModel.sealedBackup(of: data, with: id, stamp: second)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: id.backupKey)
        let opened = try JSONDecoder.pulshade.decode(AppData.self, from: AppModel.unpadded(plain))
        #expect(opened.backupStamp?.counter == second.counter)
        #expect(abs((opened.backupStamp?.madeAt ?? .distantPast).timeIntervalSince(second.madeAt)) < 1)
        // Not part of what's compared to tell whether anything changed.
        data.backupStamp = second
        #expect(AppModel.backupContents(of: data).backupStamp == nil)
    }
}

/// Handshake secrets kept only as long as docs/protocol.md says (#7).
@MainActor
@Suite(.serialized) struct HandshakeSecretLifetimeTests {
    @Test func oldAsksAndRetiredSparesAreForgotten() async throws {
        let model = testModel("pulshade-ask-life")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        defer { model.lock() }
        func ask(daysAgo: Double) throws -> PendingHandshake {
            var (pending, _) = try Handshake.start()
            pending.startedAt = Date().addingTimeInterval(-daysAgo * 86_400)
            return pending
        }
        let them = Identity.generate(), stranger = Identity.generate()
        var friend = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                             agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        friend.devices[0].handshake = try ask(daysAgo: 9)
        friend.devices[0].earlierAsks = [try ask(daysAgo: 12), try ask(daysAgo: 2)]
        var old = try #require(SpareKey.make(pin: Data([1])))
        old.retiredAt = Date().addingTimeInterval(-11 * 86_400)
        var recent = try #require(SpareKey.make(pin: Data([1])))
        recent.retiredAt = Date().addingTimeInterval(-3 * 86_400)
        friend.oldSpares = [old, recent]
        var waiting = Contact(fingerprint: stranger.fingerprint, name: "Asked", signingKey: stranger.card.signing,
                              agreementKey: stranger.card.agreement, sendID: Mailbox.make().sendID, device: Data([2]))
        waiting.awaitingAcceptance = true
        waiting.devices[0].handshake = try ask(daysAgo: 20)
        model.data.contacts = [friend, waiting]

        #expect(model.pruneHandshakeSecrets())
        let f = model.data.contacts[0]
        #expect(f.devices[0].handshake == nil, "an unanswered ask goes after 8 days")
        #expect(f.devices[0].needsKeys == true, "and the device is asked again")
        #expect(f.devices[0].earlierAsks?.count == 1 && f.devices[0].earlierAsks?.first?.startedAt == friend.devices[0].earlierAsks?[1].startedAt)
        #expect(f.oldSpares?.count == 1 && f.oldSpares?.first?.retiredAt == recent.retiredAt, "a replaced spare goes 10 days after")
        #expect(model.data.contacts[1].devices[0].handshake != nil, "a friend request's ask waits longer for its answer")
        #expect(!model.pruneHandshakeSecrets(), "nothing more to do")
        #expect(model.pruneHandshakeSecrets(now: Date().addingTimeInterval(13 * 86_400)))
        #expect(model.data.contacts[1].devices[0].handshake == nil, "but not past the relay's 32 days")
        #expect(model.data.contacts[0].devices[0].earlierAsks == nil)
    }
}

/// The same fixes end to end through a real relay (see scripts/test.sh).
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ProtocolReviewFlowTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-review")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnceFully() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private var relay: RelayClient {
        get throws { RelayClient(base: try #require(URL(string: AppData.defaultRelay)), lane: "review-test") }
    }

    /// #18: an answer to a spare this device never left (or no longer has) can't add a device to a friend, or move one
    /// of theirs to another mailbox: nothing in it was checked against a device's keys. Anyone with a copy of the friend's
    /// account keys (an unlinked device, say) could otherwise send one.
    @Test func anAnswerToAnUnknownSpareChangesNoDevices() async throws {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await until([alice, bob]) { alice.visibleContacts.contains { $0.name == "Bob" } && bob.visibleContacts.contains { $0.name == "Alice" } }
        let bobSeen = try #require(alice.visibleContacts.first { $0.name == "Bob" })
        let aliceSeen = try #require(bob.visibleContacts.first { $0.name == "Alice" })
        let before = bobSeen.devices.map { ($0.id, $0.sendID) }
        let bobID = try #require(bob.identity), aliceID = try #require(alice.identity)

        func answer() -> SessionAccept {
            SessionAccept(replyTo: .random(32), ephemeral: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
                          kemCiphertext: .random(EnvelopeCore.kemCiphertextSize))
        }
        let stranger = Data.random(16)
        let added = try Envelope.seal(.spareAccept(DeviceCard(id: stranger, sendID: Mailbox.make().sendID), answer()), from: bobID,
                                      device: stranger, to: aliceID.recipient)
        let known = try #require(before.first?.0)
        let moved = try Envelope.seal(.spareAccept(DeviceCard(id: known, sendID: Mailbox.make().sendID), answer()), from: bobID,
                                      device: known, to: aliceID.recipient)
        let mailbox = try #require(aliceSeen.devices.first?.sendID)
        try await relay.deposit(added, to: mailbox)
        try await relay.deposit(moved, to: mailbox)
        for _ in 0..<6 { await alice.syncOnceFully() }

        let after = try #require(alice.contact(bobSeen.fingerprint, in: nil)).devices
        #expect(!after.contains { $0.id == stranger }, "no device added")
        #expect(after.count == before.count)
        #expect(after.first { $0.id == known }?.sendID == before.first?.1, "no device moved to another mailbox")
    }

    /// #16: every backup carries its count and date inside the seal. A copy older than one this device made is refused,
    /// and a device with none of the account's data is told its date before restoring it.
    @Test func anOlderBackupThanThisDeviceHadIsNotRestored() async throws {
        let zee = try await makeUser("Zee")
        defer { zee.lock() }
        zee.data.security.keepBackup = true
        #expect(await zee.saveBackup())
        let stamp = try #require(zee.data.backupStamp)
        await zee.settleSavesAsync()
        let id = try #require(zee.identity)

        // The relay hands back an older copy than the one this device left.
        try await Task.sleep(for: .seconds(1.1))
        let made = Date().addingTimeInterval(-3 * 86_400)
        let older = try AppModel.sealedBackup(of: zee.data, with: id, stamp: BackupStamp(counter: stamp.counter - 10, madeAt: made))
        let (key, sig, ts) = zee.backupProof("pulshade.backup.put.v1", id, body: older)
        try await relay.putBackup(older, key: key, sig: sig, ts: ts, forgetHash: AppModel.decoyForgetHash(for: id))
        guard case let .older(date) = await zee.backup(of: id) else {
            Issue.record("an older backup than this device had was offered for restoring")
            return
        }
        #expect(abs((date ?? .distantPast).timeIntervalSince(made)) < 2)

        // A device that has none of the account's data can't tell: it gets the copy, with its date to show first.
        let fresh = testModel("pulshade-review-fresh")
        guard case let .found(found) = await fresh.backup(of: id) else {
            Issue.record("the backup wasn't found")
            return
        }
        #expect(found.backupStamp?.counter == stamp.counter - 10)
        let words = RestoreFlow.backupDate(found.backupStamp?.madeAt)
        #expect(words.hasPrefix("Backup from "))
    }
}
