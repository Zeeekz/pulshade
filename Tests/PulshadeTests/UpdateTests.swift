#if os(macOS)
import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Mac updates: signed by the operator with OpenSSL, checked by the app with CryptoKit.
struct UpdateTests {
    /// A throwaway key and a release it signed with `openssl pkeyutl -sign -rawin`, as the release command does.
    static let key = try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: "2sB/ysHbHDR3jv0beHSFOYYl/40byrZ75pdGoE2/J5w=")!)
    static let release = Release(
        version: "0.1.1", build: 202611030900, size: 1234,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        notes: "Faster sending.",
        signature: "e+PIP9/UnyGBVrxcpIGmYiLIV4izSn0pm8AJN4l1w3BuNvO7/teRbR3KFeLkNzla+gUUyIMyCjp+1Y4ME/QACw==")

    @Test func acceptsAReleaseSignedByTheReleaseKey() {
        #expect(Self.release.verified(by: Self.key))
    }

    @Test func refusesAnyChangeToWhatWasSigned() {
        var tampered = [Self.release, Self.release, Self.release, Self.release]
        tampered[0].build += 1
        tampered[1].sha256 = String(repeating: "0", count: 64)
        tampered[2].notes = "Install this instead."
        tampered[3].size = 1235
        for release in tampered { #expect(!release.verified(by: Self.key)) }
        #expect(!Self.release.verified(by: Curve25519.Signing.PrivateKey().publicKey), "Another key's signature")
    }

    /// Once a build has been offered, a replayed signed manifest for anything older is refused, even though it's
    /// still newer than whatever's installed: that's the rollback a withheld-then-replayed manifest relies on.
    @Test @MainActor func refusesAReplayedOlderManifestOnceANewerOneHasBeenSeen() {
        UserDefaults.standard.removeObject(forKey: "pulshade.updateHighWaterMark")
        defer { UserDefaults.standard.removeObject(forKey: "pulshade.updateHighWaterMark") }

        #expect(Updater.acceptable(100))
        #expect(Updater.acceptable(200))
        // A signed manifest for build 150 is real and newer than nothing installed, but it's older than 200,
        // which this device has already been offered: accepting it would roll the app back.
        #expect(!Updater.acceptable(150))
        #expect(Updater.highWaterMark == 200)
        // The mark only ever moves up.
        #expect(Updater.acceptable(200))
        #expect(Updater.acceptable(201))
    }

    /// The relay hands out whatever release sits in its folder, untouched. Needs a throwaway relay.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"))
    func theRelayHandsOutTheReleaseInItsFolder() async throws {
        let relay = try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"].flatMap(URL.init(string:)))
        let scratch = try #require(ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"])
        let folder = URL(filePath: scratch).appending(path: "pulshade-release")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let zip = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let manifest = """
            {"version":"0.1.1","build":202611030900,"size":\(zip.count),"sha256":"\(Data(SHA256.hash(data: zip)).hex)",
             "notes":"Faster sending.","signature":"\(Self.release.signature)"}
            """
        try zip.write(to: folder.appending(path: "mac.zip"))
        try Data(manifest.utf8).write(to: folder.appending(path: "mac.json"))

        Tor.enabled = false
        let client = RelayClient(base: relay, lane: "update")
        let fetched = try #require(try await client.latestRelease())
        #expect(fetched.build == 202611030900 && fetched.size == zip.count)
        #expect(try await client.releaseArchive() == zip)
    }
}
#endif
