import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Pulshade

/// What the relay can learn from how the app talks to it (the metadata review of 24 November 2026): which lanes things go
/// on, how long receipts wait, how big files look, what a reader list says, and what a picked file gives away. No relay.
@MainActor
@Suite(.serialized) struct TrafficPrivacyTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-traffic")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    private func contact(persona: UUID? = nil) -> Contact {
        let them = Identity.generate()
        let box = Mailbox.make()
        var c = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                        agreementKey: them.card.agreement, sendID: Mailbox.make().sendID)
        c.persona = persona
        c.receiveKey = box.receiveKey
        return c
    }

    private static func shared() -> SharedGroup {
        let group = UUID()
        return SharedGroup(settings: GroupSettings(group: group, kind: .group, version: 1, epoch: 1, title: "G", owner: Data.random(32), members: []),
                           epochs: [])
    }

    // MARK: Fetch lanes

    @Test func aMailboxAlwaysGoesOnTheSameOfThreeLanes() {
        let salt = Data.random(32)
        let keys = (0..<300).map { _ in Data.random(32) }
        let buckets = keys.map { Lanes.bucket(of: $0, salt: salt, count: 3) }
        #expect(Set(buckets) == [0, 1, 2], "spread over all three")
        #expect(keys.map { Lanes.bucket(of: $0, salt: salt, count: 3) } == buckets, "and always the same one")
        // Roughly even: none of the three gets less than a fifth.
        for b in 0..<3 { #expect(buckets.count { $0 == b } > 60) }
        #expect(Lanes.fetchLane(persona: nil, bucket: 0) == "main")
        #expect(Lanes.fetchLane(persona: nil, bucket: 2) == "main/2")
    }

    @Test func overTorAPersonasMailboxesAreSplitAndGroupsReadAlone() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        model.isolateLanesForTests = true
        let persona = UUID()
        model.data.contacts = (0..<30).map { _ in contact() } + (0..<6).map { _ in contact(persona: persona) }
        var groups: [Conversation] = []
        for _ in 0..<3 {
            var g = Conversation(kind: .group, title: "G", members: [])
            g.shared = Self.shared()
            groups.append(g)
        }
        model.data.conversations = groups
        let lanes = model.currentLanes()
        let main = lanes.filter { $0.key.name == "main" || $0.key.name.hasPrefix("main/") }
        #expect(main.count == 3, "the main persona's thirty mailboxes go on three lanes")
        #expect(main.values.allSatisfy { $0.count < 30 }, "none of them names every contact")
        #expect(main.values.reduce(Set<Data>()) { $0.union($1) }.count == 30)
        let theirs = lanes.filter { $0.key.name.hasPrefix(persona.uuidString) }
        #expect(theirs.values.reduce(Set<Data>()) { $0.union($1) }.count == 6)
        #expect(Set(theirs.values.flatMap { $0 }).isDisjoint(with: Set(main.values.flatMap { $0 })), "personas never share a lane")
        for g in groups {
            let lane = AppModel.Lane(relay: nil, name: model.groupLane(g, among: groups.count))
            #expect(lanes[lane] == [], "a group's lane carries no one-to-one mailbox")
            #expect(lane.name == "group|" + g.id.uuidString, "each group on its own lane")
        }
        // The same account on another device spreads them the same way.
        #expect(model.currentLanes() == lanes)
    }

    @Test func overAFastConnectionLanesStayAsTheyWere() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        model.data.contacts = (0..<10).map { _ in contact() }
        let lanes = model.currentLanes()
        #expect(lanes.keys.map(\.name) == ["main"], "no splitting without Tor")
        #expect(lanes[AppModel.Lane(relay: nil, name: "main")]?.count == 10)
    }

    @Test func pastSixteenGroupsTheyShareSixteenLanesAmongThemselves() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        model.isolateLanesForTests = true
        var groups: [Conversation] = []
        for _ in 0..<40 {
            var g = Conversation(kind: .group, title: "G", members: [])
            g.shared = Self.shared()
            groups.append(g)
        }
        model.data.conversations = groups
        let names = Set(groups.map { model.groupLane($0, among: groups.count) })
        #expect(names.count <= Lanes.maxGroupLanes && names.allSatisfy { $0.hasPrefix("groups/") })
    }

    // MARK: Sending lanes

    @Test func aSendingLaneKeepsItsCircuitForOneBurstOnly() {
        var lanes = SendLanes()
        let t0 = Date()
        let first = lanes.current("send", now: t0)
        #expect(first.retired == nil && first.name.hasPrefix("send~"))
        #expect(lanes.current("send", now: t0.addingTimeInterval(30)).name == first.name, "the same burst")
        let later = lanes.current("send", now: t0.addingTimeInterval(30 + SendLanes.idle + 1))
        #expect(later.name != first.name && later.retired == first.name, "a fresh circuit after a quiet spell")
        // Kept busy, it moves on after `maxAge` anyway, but never while something is on its way.
        let began = t0.addingTimeInterval(30 + SendLanes.idle + 1)
        var t = began
        var current = later.name
        while t < began.addingTimeInterval(SendLanes.maxAge - 40) {
            t = t.addingTimeInterval(20)
            #expect(lanes.current("send", now: t).name == current)
        }
        lanes.note(current, busy: 1, now: t)
        t = began.addingTimeInterval(SendLanes.maxAge + 10)
        #expect(lanes.current("send", now: t).name == current, "not while a send is under way")
        lanes.note(current, busy: -1, now: t)
        t = t.addingTimeInterval(1)
        let aged = lanes.current("send", now: t)
        #expect(aged.name != current && aged.retired == current)
        current = aged.name
        #expect(lanes.takeIdle(now: t.addingTimeInterval(SendLanes.idle + 1)) == [current])
        #expect(lanes.current("send", now: t.addingTimeInterval(SendLanes.idle + 2)).name != current, "never a name used before")
    }

    // MARK: Receipts

    @Test func receiptsWaitFiveToTwentySecondsOrWhatTheBackgroundAllows() {
        for _ in 0..<200 {
            let wait = Lanes.receiptWait(room: nil)
            #expect((5...20).contains(wait))
            let short = Lanes.receiptWait(room: 3)
            #expect((0.5...3).contains(short))
            #expect(Lanes.receiptWait(room: -4) == 0.5, "out of time: as soon as it can")
        }
    }

    @Test func aDuplicateIsAnsweredOnceADayAndOnlySoOftenPerContact() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let c = contact()
        let id = UUID()
        let now = Date()
        #expect(model.allowDuplicateReceipt(id, from: c, now: now))
        #expect(!model.allowDuplicateReceipt(id, from: c, now: now.addingTimeInterval(3600)), "not again the same day")
        #expect(model.allowDuplicateReceipt(id, from: c, now: now.addingTimeInterval(Lanes.duplicateReceiptGap + 1)))
        // Many different ones from one contact: only so many an hour.
        let other = contact()
        let allowed = (0..<50).filter { _ in model.allowDuplicateReceipt(UUID(), from: other, now: now) }.count
        #expect(allowed == Lanes.duplicateReceiptsPerHour)
        #expect(model.allowDuplicateReceipt(UUID(), from: other, now: now.addingTimeInterval(3601)), "the next hour, again")
    }

    // MARK: Signals

    @Test func typingIsOffForNewAccountsAndLateTypingIsIgnored() throws {
        #expect(SecuritySettings().typingIndicators == false)
        // An account saved before the setting existed showed typing, and still does.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SecuritySettings())) as? [String: Any])
        json["typingIndicators"] = nil
        let old = try JSONDecoder().decode(SecuritySettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.typingIndicators)
        json["typingIndicators"] = false
        #expect(try JSONDecoder().decode(SecuritySettings.self, from: JSONSerialization.data(withJSONObject: json)).typingIndicators == false)
        let now = Date()
        #expect(AppModel.isFreshSignal(deposited: now.addingTimeInterval(-5), now: now))
        #expect(!AppModel.isFreshSignal(deposited: now.addingTimeInterval(-AppModel.signalLife - 1), now: now))
        #expect(AppModel.isFreshSignal(deposited: nil, now: now))
    }

    // MARK: Files on the relay

    @Test func filesArePaddedToSizeSteps() {
        #expect(BlobPadding.padded(1) == BlobPadding.smallest)
        var last = 0
        var steps: Set<Int> = []
        for size in stride(from: 1, to: 3 * 1024 * 1024, by: 7919) {
            let padded = BlobPadding.padded(size)
            #expect(padded >= size && padded >= last)
            steps.insert(padded)
            last = padded
            if padded > BlobCrypto.sealedPiece { #expect(padded % BlobCrypto.sealedPiece == 0, "whole MiB above one") }
            else if size > BlobPadding.smallest { #expect(Double(padded) <= Double(size) * BlobPadding.step + 1, "at most a quarter more") }
        }
        #expect(steps.count < 30, "a few dozen sizes, not hundreds")
        #expect(BlobPadding.padded(BlobCrypto.sealedSize(of: BlobCrypto.maxFile)) <= BlobPadding.relayMax)
        #expect(BlobPadding.padded(BlobCrypto.sealedSize(of: BlobCrypto.maxFile)) >= BlobCrypto.sealedSize(of: BlobCrypto.maxFile))
    }

    @Test func aReaderListHasAFixedShapeAndTheSenderSpendsWhatNobodyElseWill() {
        let one = BlobReaders.shape(devices: [1], size: 50_000)
        let two = BlobReaders.shape(devices: [2, 1], size: 50_000)
        #expect(one.count == 4 && two.count == 4, "a chat of two looks like a chat of three")
        #expect(one.uses == two.uses && one.uses == 2)
        #expect(BlobReaders.shape(devices: [1, 1, 1, 1, 1], size: 10_000_000).count == 8)
        #expect(BlobReaders.shape(devices: [3], size: 50_000).uses == 4)
        #expect(BlobReaders.shape(devices: Array(repeating: 1, count: 6), size: 200).count == 6, "a list longer than the file can hold isn't padded")

        let readers = [(token: Data.random(32), count: 1), (token: Data.random(32), count: 2)]
        let plan = AppModel.readerPlan(readers, size: 50_000)
        #expect(plan.records.count == 4 && Set(plan.records.map(\.uses)).count == 1, "every entry looks the same")
        let total = plan.records.reduce(0) { $0 + $1.uses }
        let spentBySender = plan.spends.reduce(0) { $0 + $1.uses }
        #expect(total == spentBySender + 3, "the readers' three devices spend the rest, and then the file is erased")
        #expect(plan.spends.contains { $0.token == readers[0].token && $0.uses == 1 }, "the one-device reader's spare use")
        #expect(!plan.spends.contains { $0.token == readers[1].token })
    }

    // MARK: Picked files

    private func taggedJPEG() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(ctx.makeImage())
        let data = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8566, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.3522, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:11:01 09:30:00"],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func properties(_ data: Data) throws -> [CFString: Any] {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    @Test func aPictureSentAsAFileLosesItsHiddenDetailsAndItsName() throws {
        let original = try taggedJPEG()
        #expect(try properties(original)[kCGImagePropertyGPSDictionary] != nil, "the test picture starts out tagged")
        let dir = testDirectory("scrub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Holiday in Paris, Anna's flat.jpg")
        try original.write(to: url)

        let prepared = try BlobTransfer.prepareForSending(url, keepName: false, lifetime: 3600)
        #expect(prepared.attachment.name == "photo.jpg")
        #expect(prepared.url == nil, "the cleaned copy is in memory, never on disk")
        let sent = try #require(prepared.memory)
        let props = try properties(sent)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        #expect(tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        #expect(exif[kCGImagePropertyExifDateTimeOriginal] == nil)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6, "which way up it goes is kept")
        let raw = String(decoding: sent, as: UTF8.self)
        #expect(!raw.contains("iPhone") && !raw.contains("2026"))

        let named = try BlobTransfer.prepareForSending(url, keepName: true, lifetime: 3600)
        #expect(named.attachment.name == "Holiday in Paris, Anna's flat.jpg", "kept when asked")
        #expect(try properties(try #require(named.memory))[kCGImagePropertyGPSDictionary] == nil, "and still cleaned")
    }

    @Test func otherFilesGoAsTheyAreUnderANeutralName() throws {
        let dir = testDirectory("scrub-doc")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = dir.appendingPathComponent("Contract - J. Smith.pdf")
        try Data("%PDF-1.4 hello".utf8).write(to: pdf)
        let prepared = try BlobTransfer.prepareForSending(pdf, keepName: false, lifetime: 3600)
        #expect(prepared.attachment.name == "document.pdf")
        #expect(FileScrub.kind(of: UTType.pdf) == .mayCarryDetails, "the person is warned before it goes")
        #expect(FileScrub.kind(of: UTType.plainText) == .plain)
        #expect(FileScrub.kind(of: UTType.jpeg) == .image)
        #expect(FileScrub.neutralName(for: URL(fileURLWithPath: "/x/a.b.weird$ext"), type: nil) == "file")
    }

    // MARK: Mailbox moves

    /// A friend with two devices, both known by id, reading this device on `fresh` since a move from `old` an hour ago.
    private func movedFriend(lastHeard second: Date) -> (Contact, old: Data) {
        var c = contact()
        let old = c.receiveKey!
        c.receiveKey = Mailbox.make().receiveKey
        c.formerMailboxes = [FormerMailbox(key: old, until: nil)]
        c.mailboxSince = Date().addingTimeInterval(-3600)
        c.devices = [DeviceLink(id: Data.random(16), sendID: Mailbox.make().sendID), DeviceLink(id: Data.random(16), sendID: Mailbox.make().sendID)]
        c.devices[0].lastHeard = Date()
        c.devices[1].lastHeard = second
        c.movedHeard = [c.devices[0].id]
        return (c, old)
    }

    /// A device of theirs silent for over a month (and so left out of sending, where it never heard of the move) doesn't
    /// hold the old mailbox open for good, which would stop this friend's mailbox from ever moving again.
    @Test func aDormantDeviceDoesNotKeepAMoveOpenForGood() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (away, _) = movedFriend(lastHeard: Date().addingTimeInterval(-AppModel.dormantAfter - 86_400))
        let (quiet, _) = movedFriend(lastHeard: Date().addingTimeInterval(-5 * 86_400))
        model.data.contacts = [away, quiet]
        #expect(model.awaitedOnNewMailbox(contact: 0).isEmpty)
        #expect(model.awaitedOnNewMailbox(contact: 1) == [quiet.devices[1].id])
        model.tendMailboxMoves()
        #expect(model.data.contacts[0].formerMailboxes?.allSatisfy { $0.until != nil } == true, "read only as long as mail can wait")
        #expect(model.data.contacts[1].formerMailboxes?.first?.until == nil, "a device only quiet a few days is still waited for")
    }

    /// A device not heard on the new mailbox three days after the move is told it again (the first word may have been
    /// lost), once every three days, and never with two copies waiting.
    @Test func aMoveNotFollowedIsToldAgain() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (friend, _) = movedFriend(lastHeard: Date())
        model.data.contacts = [friend]
        let fresh = Mailbox.sendID(for: friend.receiveKey!)
        func told(_ d: Int) -> Int {
            model.data.contacts[0].devices[d].pending.count { if case let .mailbox(id) = $0.payload { return id == fresh } else { return false } }
        }
        model.tendMailboxMoves()
        #expect(told(1) == 0, "not before three days")
        let later = Date().addingTimeInterval(AppModel.mailboxRetell)
        model.tendMailboxMoves(now: later)
        #expect(told(1) == 1, "the device not heard there yet is told again")
        #expect(told(0) == 0, "the one already writing there isn't")
        model.tendMailboxMoves(now: later.addingTimeInterval(3600))
        #expect(told(1) == 1, "not again within three days")
        model.tendMailboxMoves(now: later.addingTimeInterval(AppModel.mailboxRetell))
        #expect(told(1) == 1, "and again after them, replacing the copy still waiting")
        #expect(model.data.contacts[0].formerMailboxes?.first?.until == nil, "the old mailbox is still read meanwhile")
    }

    /// A move doesn't ask for a backup upload of its own (a PUT minutes after each would tie the backup to the mailboxes):
    /// it goes with the next one, and is in it.
    @Test func aMailboxMoveDoesNotChangeTheBackupDigest() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (friend, old) = movedFriend(lastHeard: Date())
        model.data.contacts = [friend]
        let before = try #require(AppModel.backupChangeDigest(of: model.data))
        let current = try #require(model.data.contacts[0].receiveKey)
        model.data.contacts[0].formerMailboxes?.append(FormerMailbox(key: current, until: nil))
        let moved = Mailbox.make().receiveKey
        model.data.contacts[0].receiveKey = moved
        model.data.contacts[0].mailboxSince = Date()
        model.data.contacts[0].movedHeard = []
        model.data.contacts[0].formerMailboxes?[0].until = Date().addingTimeInterval(AppModel.formerMailboxLife)
        // Their move, the other way: a device of theirs now reads a new mailbox, and the word of ours waits to go.
        model.data.contacts[0].devices[0].sendID = Mailbox.make().sendID
        model.data.contacts[0].devices[1].pending.append(PendingPayload(payload: .mailbox(sendID: Mailbox.sendID(for: moved))))
        #expect(AppModel.backupChangeDigest(of: model.data) == before)
        let contents = AppModel.backupContents(of: model.data)
        #expect(contents.contacts[0].receiveKey == moved && contents.contacts[0].formerMailboxes?.first?.key == old, "still in the backup itself")
        model.data.contacts[0].nickname = "Someone"
        #expect(AppModel.backupChangeDigest(of: model.data) != before, "anything else still asks for an upload")
    }

    // MARK: Burn

    @Test func aBurnOrderGoesInOnePartPerPersona() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let identity = try #require(model.identity)
        let persona = try #require(model.createPersona(name: "Other")).id
        model.data.contacts = [contact(), contact(), contact(persona: persona)]
        model.data.blobWipes = [BlobWipe(id: Data.random(16).hex, secret: .random(32), expires: Date().addingTimeInterval(3600))]
        let order = model.makeBurnOrder(identity: identity, outboxBefore: [])
        let parts = try #require(order.parts)
        #expect(parts.count == 3, "the main persona, the other one, and the files")
        #expect(parts.filter { $0.backup != nil }.count == 1)
        #expect(parts.allSatisfy { $0.handles.count <= 1 && $0.recall.count <= 1 }, "no part names two personas")
        let main = try #require(parts.first { $0.backup != nil })
        #expect(main.mailboxes.count == 2)
        let other = try #require(parts.first { $0.backup == nil && !$0.handles.isEmpty })
        #expect(other.mailboxes == [model.data.contacts[2].receiveKey!])
        #expect(parts.first { $0.handles.isEmpty }?.blobs.count == 1)
        var finished = order
        finished.farewells = []
        #expect(!finished.isFinished)
        finished.parts = parts.map { var p = $0; p.done = true; return p }
        #expect(finished.isFinished)
        let json = try #require(JSONSerialization.jsonObject(with: BurnOrder.requestBody(other)) as? [String: Any])
        #expect(Set(json.keys) == ["ts", "backup", "handles", "recall", "blobs", "mailboxes"] || Set(json.keys) == ["ts", "handles", "recall", "blobs", "mailboxes"])
    }

    /// Every mailbox goes in the order: past what the relay takes in one request, in more parts, each still signed; and
    /// those of a persona whose own entry is gone, without its signature, rather than not at all.
    @Test func aBurnOrderCoversEveryMailbox() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let identity = try #require(model.identity)
        var busy = contact()
        busy.formerMailboxes = (0..<3000).map { _ in FormerMailbox(key: .random(32), until: nil) }
        let orphan = UUID()
        model.data.contacts = [busy, contact(), contact(persona: orphan)]
        let order = model.makeBurnOrder(identity: identity, outboxBefore: [])
        let parts = try #require(order.parts)
        let main = parts.filter { !$0.handles.isEmpty }
        #expect(main.count == 2, "3,002 mailboxes: two parts")
        #expect(main.allSatisfy { $0.mailboxes.count <= AppModel.burnMailboxesPerPart })
        #expect(main.filter { $0.backup != nil }.count == 1 && main.filter { !$0.recall.isEmpty }.count == 1)
        let expected = Set(model.data.contacts.filter { $0.persona == nil }.flatMap(AppModel.mailboxes(of:)))
        #expect(Set(main.flatMap(\.mailboxes)) == expected && main.flatMap(\.mailboxes).count == expected.count)
        let unsigned = try #require(parts.first { $0.handles.isEmpty && !$0.mailboxes.isEmpty })
        #expect(unsigned.mailboxes == [model.data.contacts[2].receiveKey!], "the persona's mailboxes are closed all the same")
        for part in parts { #expect(try BurnOrder.requestBody(part).count < 256 * 1024, "within what the relay takes") }
    }

    // MARK: Wake-ups and the directory

    @Test func wakeUpsAreRegisteredInPartsWithEachGroupAlone() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        model.isolateLanesForTests = true
        model.data.contacts = (0..<12).map { _ in contact() }
        let parts = model.pushParts()
        #expect(parts.count >= 2 && parts.count <= 3, "one-to-one mailboxes in the same parts they're fetched in")
        model.data.conversations = (0..<2).map { _ in
            var g = Conversation(kind: .group, title: "G", members: [])
            g.shared = Self.shared()
            return g
        }
        #expect(model.pushKeys().count == 12)
    }

    /// Over a direct connection every request comes from one address, which the relay allows 60 wake-up requests an hour:
    /// a part per group (renewed every 15 minutes) used that up. There it is one part, sent 256 mailboxes at a time.
    @Test func overADirectConnectionWakeUpsGoInOnePart() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        #expect(!model.isolatesLanes, "the test relay is reached directly")
        model.data.contacts = (0..<12).map { _ in contact() }
        model.data.conversations = (0..<20).map { _ in
            var g = Conversation(kind: .group, title: "G", members: [])
            g.shared = Self.shared()
            return g
        }
        let parts = model.pushParts()
        #expect(parts.count == 1)
        #expect(parts.first == model.pushKeys())
        model.isolateLanesForTests = true
        #expect(model.pushParts().count > 1, "over Tor the parts are kept apart")
    }

    /// Mailboxes no longer woken for are taken off in the parts they were registered in, not one request each.
    @Test func wakeUpsNoLongerWantedGoOffTogether() {
        let a = Set((0..<300).map { _ in Data.random(32) }), group = Data.random(32), kept = Data.random(32)
        var told = [a.union([kept]), [group]]
        var batches = AppModel.pushRemovals(told: told, keys: [kept])
        #expect(batches.count == 3, "the 300 in two requests of at most 256, the group's alone")
        #expect(batches.allSatisfy { $0.count <= 256 })
        #expect(Set(batches.flatMap { $0 }) == a.union([group]))
        #expect(batches.contains([group]), "a group's mailbox is never named beside another part's")
        told = [[kept]]
        batches = AppModel.pushRemovals(told: told, keys: [kept])
        #expect(batches.isEmpty)
        // A refused registration is left alone for 15 to 60 minutes; an unanswered one for a few.
        for _ in 0..<50 {
            #expect((900...3600).contains(AppModel.pushRetryWait(refused: true)))
            #expect((60...300).contains(AppModel.pushRetryWait(refused: false)))
        }
    }

    @Test func directoryEntriesSayOnlyTheMinute() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let at = Date(timeIntervalSince1970: 1_800_000_012.345)
        let first = model.directoryStamp("me", now: at)
        #expect(first % 60_000 == 0 && first >= UInt64(at.timeIntervalSince1970 * 1000))
        let again = model.directoryStamp("me", now: at.addingTimeInterval(5))
        #expect(again == first + 60_000, "a second edit in the same minute is still newer")
        #expect(model.directoryStamp("other", now: at) == first + 120_000, "and newer than any handle's before it")
    }
}
