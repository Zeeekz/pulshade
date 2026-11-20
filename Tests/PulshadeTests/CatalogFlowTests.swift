import Testing
import Foundation
import CryptoKit
@testable import Pulshade
import PulshadeShared

/// The collectibles list through a real relay: the admin app uploads pictures and publishes a signed list, apps fetch
/// it with every picture, and a collectible of a new item, given out afterwards, shows with its name and picture.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct CatalogFlowTests {
    private func operate(_ action: String, _ arg: String = "") async throws -> (status: Int, body: Any?) {
        let token = try String(contentsOfFile: try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"]) + "/admin.token", encoding: .utf8)
        var request = URLRequest(url: URL(string: AppData.defaultRelay + "/v1/admin")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "X-Pulshade-Admin-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action, "arg": arg])
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    private func nextVersion() async throws -> UInt64 {
        let summary = try #require(try await operate("catalog").body as? [String: Any])
        return ((summary["version"] as? NSNumber)?.uint64Value ?? 0) + 1
    }

    @Test func aPublishedListReachesAppsAndItsCollectiblesShow() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        await AdminKeyGate.shared.acquire()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous; Task { await AdminKeyGate.shared.release() } }
        CollectibleLibrary.shared.clear()
        let bob = testModel("pulshade-test")
        try await bob.create(identity: .generate(), profile: Profile(name: "Bob"), passcode: "test-passcode")
        defer { bob.lock() }

        // The relay holds one list for the whole test run, so this one is the next after whatever it has.
        let version = try await nextVersion()
        let id = "globe\(Int.random(in: 10000...99999))"
        let (item, data) = catalogTestItem(id, frames: 6)
        let (medal, medalData) = catalogTestItem("medal\(Int.random(in: 10000...99999))", frames: 1, transferable: false, seed: 0.4)
        let list = CollectibleCatalog(version: version, issued: UInt64(Date().timeIntervalSince1970), items: [item, medal])
        let signed = try list.sign(with: admin)
        let publish = String(decoding: try JSONEncoder().encode(signed), as: UTF8.self)
        #expect(try await operate("catalog-publish", publish).status == 400, "not until every picture is up")
        for picture in [data, medalData] {
            let up = try await operate("catalog-art", picture.base64EncodedString())
            #expect(up.status == 200)
            #expect((up.body as? [String: Any])?["sha256"] as? String == CollectibleCatalog.hex(SHA256.hash(data: picture)))
        }
        #expect(try await operate("catalog-publish", publish).status == 200)
        #expect(try await operate("catalog-publish", publish).status == 400, "the same version again is refused")

        await bob.refreshCatalog()
        let library = CollectibleLibrary.shared
        #expect(library.catalog == list)
        #expect(library.hasAllArt)
        #expect(library.info(id).name == "Snow Globe" && library.info(id).known)

        // An app that has this list is told so with a bare 304.
        let relay = try #require(bob.client(nil))
        #expect(try await relay.catalog(since: version) == nil)
        #expect(try await relay.catalog(since: nil) == signed)

        // A collectible of the new item, given out now, is genuine and shows by name.
        let bobKey = try #require(bob.me(nil)).card.signing
        let globe = try Collectible.make(item: id, serial: 1, owner: bobKey, signedBy: admin)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(globe), as: UTF8.self)).status == 200)
        try await bob.refreshCollectibles()
        #expect(bob.activeProfile.collectibles?.contains(globe) == true)
        #expect(globe.info.name == "Snow Globe")
        bob.wear(globe)
        #expect(bob.activeProfile.badge == globe)

        // One the list marks as earned can't get a backup code or be gifted, on the relay too.
        let earned = try Collectible.make(item: medal.id, serial: 1, owner: bobKey, signedBy: admin)
        #expect(try await operate("give-collectible", String(decoding: try JSONEncoder().encode(earned), as: UTF8.self)).status == 200)
        try await bob.refreshCollectibles()
        #expect(bob.activeProfile.collectibles?.contains(earned) == true)
        #expect(!earned.info.transferable)

        // Kept sealed for the next unlock: locked and opened again, the list is there before anything is fetched.
        bob.lock()
        #expect(library.catalog == nil, "a locked app holds no list")
        #expect(await bob.unlock(passcode: "test-passcode"))
        #expect(library.catalog == list && library.hasAllArt)

        // A newer list replaces it; the picture already held isn't fetched again, and one no longer listed goes.
        var newer = list
        newer.version += 1
        newer.items = [item]
        #expect(try await operate("catalog-publish", String(decoding: try JSONEncoder().encode(try newer.sign(with: admin)), as: UTF8.self)).status == 200)
        await bob.refreshCatalog()
        #expect(library.catalog == newer)
        let summary = try #require(try await operate("catalog").body as? [String: Any])
        #expect(summary["art"] as? [String] == [item.art.sha256])
        CollectibleLibrary.shared.clear()
    }

    @Test func aListNotSignedByTheAdminKeyIsIgnored() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        await AdminKeyGate.shared.acquire()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous; Task { await AdminKeyGate.shared.release() } }
        CollectibleLibrary.shared.clear()
        let carol = testModel("pulshade-test")
        try await carol.create(identity: .generate(), profile: Profile(name: "Carol"), passcode: "test-passcode")
        defer { carol.lock() }
        let (item, data) = catalogTestItem("forged\(Int.random(in: 10000...99999))")
        let forged = CollectibleCatalog(version: try await nextVersion(), issued: 0, items: [item])
        #expect(try await operate("catalog-art", data.base64EncodedString()).status == 200)
        // The relay doesn't hold the admin key's public half, so it takes this; the apps are what refuse it.
        #expect(try await operate("catalog-publish", String(decoding: try JSONEncoder().encode(try forged.sign(with: .init())), as: UTF8.self)).status == 200)
        await carol.refreshCatalog()
        #expect(CollectibleLibrary.shared.catalog == nil)
        #expect(!CollectibleLibrary.shared.info(item.id).known)
    }
}
