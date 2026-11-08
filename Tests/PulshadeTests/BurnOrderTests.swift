import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// The burn order: what stays on a wiped phone until the relay confirms.
struct BurnOrderTests {
    private func store() -> BurnOrderStore {
        let name = "burn-test-\(UUID().uuidString)"
        return BurnOrderStore(file: FileManager.default.temporaryDirectory.appendingPathComponent(name + ".sealed"), service: "app.pulshade.test." + name)
    }

    private func order() -> BurnOrder {
        var o = BurnOrder(ts: UInt64(Date().timeIntervalSince1970), relay: "http://127.0.0.1:7890")
        o.backup = .init(key: Data.random(32), sig: Data.random(64))
        o.handles = [.init(key: Data.random(32), sig: Data.random(64))]
        o.recall = [Data.random(32)]
        o.blobs = [BlobWipe(id: Data.random(16).hex, secret: .random(32), expires: Date(timeIntervalSince1970: 1_900_000_000))]
        o.mailboxes = [Data.random(32), Data.random(32)]
        o.farewells = [.init(sendID: .random(32), blob: .random(900), relay: "http://127.0.0.1:7890")]
        return o
    }

    @Test func stampsAreUnlinkableUntilTheKeyIsShown() {
        let key = Data.random(32)
        let a = Recall.stamp(key), b = Recall.stamp(key)
        #expect(a.hash != b.hash && a.n != b.n, "two stamps from one sender look unrelated")
        #expect(Recall.hash(recallKey: key, n: a.n) == a.hash, "the key and the number give the hash back")
        #expect(Recall.hash(recallKey: Data.random(32), n: a.n) != a.hash, "another key doesn't")
        #expect(a.hash.count == 32)
    }

    @Test func aRecallKeyIsPerIdentityAndStable() {
        let one = Identity.generate(), two = Identity.generate()
        #expect(one.recallKey == one.recallKey && one.recallKey.count == 32)
        #expect(one.recallKey != two.recallKey)
    }

    @Test func theOrderIsSealedOnDiskAndOpensOnlyWithItsKey() throws {
        let s = store()
        defer { s.delete() }
        let o = order()
        #expect(s.save(o) && s.exists)
        let raw = try Data(contentsOf: s.file)
        #expect(raw.range(of: o.mailboxes[0]) == nil && raw.range(of: o.farewells[0].blob.prefix(32)) == nil, "nothing readable on disk")
        #expect(s.load() == o)
        // Without its key (the Keychain item gone) it can't be opened.
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: s.service] as CFDictionary)
        #expect(s.load() == nil && s.exists)
    }

    @Test func deletingTheOrderRemovesFileAndKey() {
        let s = store()
        s.save(order())
        s.delete()
        #expect(!s.exists && s.load() == nil)
        // A new save after a delete works with a new key.
        #expect(s.save(order()))
        s.delete()
    }

    @Test func theRequestHasTheShapeTheRelayExpects() throws {
        let o = order()
        let json = try #require(JSONSerialization.jsonObject(with: o.requestBody()) as? [String: Any])
        #expect(Set(json.keys) == ["ts", "backup", "handles", "recall", "blobs", "mailboxes"])
        #expect((json["ts"] as? NSNumber)?.uint64Value == o.ts)
        let backup = try #require(json["backup"] as? [String: String])
        #expect(Data(base64Encoded: backup["key"] ?? "")?.count == 32 && Data(base64Encoded: backup["sig"] ?? "")?.count == 64)
        #expect((json["recall"] as? [String])?.allSatisfy { Data(base64Encoded: $0)?.count == 32 } == true)
        let blob = try #require((json["blobs"] as? [[String: String]])?.first)
        #expect(blob["id"]?.count == 32 && blob["secret"]?.count == 64)
        #expect((json["mailboxes"] as? [String])?.allSatisfy { $0.count == 64 } == true)
    }

    @Test func anOrderIsFinishedOnlyWhenEverythingIsDone() {
        var o = order()
        #expect(!o.isFinished)
        o.serverDone = true
        #expect(!o.isFinished, "farewells still to drop")
        o.farewells = []
        #expect(o.isFinished)
    }

    @Test func anOldOrderIsGivenUpOnBeforeTheRelayStopsAcceptingIt() {
        var o = order()
        #expect(!o.isTooOld)
        o.ts = UInt64(Date().timeIntervalSince1970 - 30 * 86_400)
        #expect(o.isTooOld)
    }
}
