import Testing
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import Pulshade
import PulshadeShared

/// Regression tests for the findings of the independent review (SEC-2xx, SEC-3xx). None needs a relay.
@Suite(.serialized) struct ReviewFixTests {

    // MARK: SEC-302: links in chat

    @Test func chatLinksOpenOnlyAsPlainHttpsHosts() throws {
        func opens(_ text: String) -> String? { LinkPreviews.openable(URL(string: text))?.absoluteString }
        #expect(opens("https://example.com/a?b=1") == "https://example.com/a?b=1")
        #expect(opens("HTTPS://Example.COM/x") == "https://example.com/x", "the host is lowercased")
        #expect(opens("http://example.com/x") == "https://example.com/x", "plain http is never opened as http")
        #expect(opens("https://example.com/x#frag") == "https://example.com/x", "no fragment")
        // Look-alike letters, addresses, user info, ports and other schemes are refused.
        #expect(opens("https://exаmple.com/") == nil, "a Cyrillic a")
        #expect(opens("https://192.168.0.1/") == nil)
        #expect(opens("https://0x7f.0.0.1/") == nil)
        #expect(opens("https://localhost/") == nil)
        #expect(opens("https://good.com@evil.com/") == nil)
        #expect(opens("https://example.com:8443/") == nil)
        #expect(opens("javascript:alert(1)") == nil)
        #expect(opens("file:///etc/passwd") == nil)
        #expect(opens("https://example.com/a\u{202E}fdp.exe")?.contains("%E2%80%AE") == true, "an override stays visible, as escapes")
        #expect(LinkPreviews.openable(nil) == nil)
    }

    @Test func publicHostsAreTheOnlyOnesAPreviewConnectsTo() {
        #expect(!LinkPreviews.resolvesToPublicAddresses("localhost"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("127.0.0.1"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("10.1.2.3"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("169.254.1.1"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("::1"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("fe80::1"))
        #expect(!LinkPreviews.resolvesToPublicAddresses("this-name-does-not-exist.invalid"))
    }

    // MARK: SEC-202: confirming a linked account

    // MARK: SEC-201: the backup header

    @Test @MainActor func theBackupAlwaysCarriesAForgetHashThatLooksTheSame() throws {
        let identity = Identity.generate()
        let decoy = AppModel.decoyForgetHash(for: identity)
        #expect(decoy.count == 32, "as long as a real one")
        #expect(decoy == AppModel.decoyForgetHash(for: identity), "the same on every upload")
        #expect(decoy != AppModel.decoyForgetHash(for: Identity.generate()))
        let real = Data(SHA256.hash(data: AppModel.forgetToken(landingSeed: Data.random(32))))
        #expect(real != decoy)
        // The decoy is not the hash of any token the panic passcode could work out.
        #expect(decoy != Data(SHA256.hash(data: AppModel.forgetToken(landingSeed: identity.seed))))
    }

    // MARK: SEC-206

    @Test @MainActor func theRememberedLockStyleMovesFromPreferencesIntoTheLockFile() async throws {
        let defaults = UserDefaults.standard
        let saved = (defaults.string(forKey: LockStyle.key), defaults.string(forKey: LockStyle.legacyKey))
        defer {
            for (key, value) in [(LockStyle.key, saved.0), (LockStyle.legacyKey, saved.1)] {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let model = testModel("pulshade-style-move")
        try model.vault.create(.generate(), passcode: "test-passcode", settings: Vault.LockSettings())
        try model.vault.updateLockSettings { $0 = Vault.LockSettings() }
        defaults.removeObject(forKey: LockStyle.key)
        defaults.set(LockStyle.pin6.rawValue, forKey: LockStyle.legacyKey)
        model.moveLockSettingsIntoVault()
        #expect(model.lockStyle == .pin6, "an upgrade keeps the setting")
        #expect(defaults.string(forKey: LockStyle.legacyKey) == nil && defaults.string(forKey: LockStyle.key) == nil)
        model.lockStyle = .pin4
        #expect(model.lockStyle == .pin4 && model.vault.lockSettings?.style == "pin4")
    }

    // MARK: SEC-203

    @Test @MainActor func seenEnvelopeDigestsOutliveTheClockSkewTheRelayCanCause() {
        #expect(AppModel.seenRetention >= AppModel.replayWindow + 7 * 24 * 3600)
    }

    // MARK: SEC-213

    @Test func aCardThatChecksOutOnceIsStillRefusedWhenChanged() {
        let group = UUID()
        let keys = GroupMemberKeys(seed: .random(32), group: group)
        var card = MemberCard.make(keys, group: group, name: "Sam", avatar: nil, color: 3)
        #expect(card.verified(group: group))
        #expect(card.verified(group: group), "the second look comes from memory")
        card.name = "Not Sam"
        #expect(!card.verified(group: group), "a changed card is checked afresh")
        #expect(!MemberCard.make(keys, group: group, name: "Sam", avatar: nil, color: 3).verified(group: UUID()), "and so is another group")
    }

    // MARK: SEC-303

    @Test func onlyAnInstallWithNothingInItsFolderCountsAsFresh() throws {
        let fresh = Vault(directory: testDirectory("pulshade-fresh"))
        #expect(fresh.claimFreshInstall(), "no vault, no marker: leftovers of a deleted install may be cleared")
        #expect(!fresh.claimFreshInstall(), "once")
        // An existing install, updated to this build: it gets the marker and nothing is cleared.
        let live = Vault(directory: testDirectory("pulshade-live"))
        try live.create(Identity.generate(), passcode: "1234abcd")
        #expect(live.exists)
        #expect(!live.claimFreshInstall())
        #expect(!live.claimFreshInstall())
        // Even a folder with some other file in it is not treated as empty.
        let odd = Vault(directory: testDirectory("pulshade-odd"))
        FileManager.default.createFile(atPath: odd.directory.appendingPathComponent("data.vault").path, contents: Data([1]))
        #expect(!odd.claimFreshInstall())
    }

    // MARK: SEC-307

    /// A real, blank picture of this many pixels (it compresses to almost nothing).
    private func png(width: Int, height: Int) -> Data {
        let pixels = Data(count: width * height)
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: CGDataProvider(data: pixels as CFData)!, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    @Test func pictureSizeIsReadFromTheHeaderAndCapped() throws {
        #expect(ImageLimits.isReasonable(png(width: 4000, height: 3000)))
        #expect(ImageLimits.isReasonable(png(width: 7000, height: 7000)), "49 million pixels")
        #expect(!ImageLimits.isReasonable(png(width: 8000, height: 8000)), "64 million")
        #expect(PlatformImage.checked(png(width: 8000, height: 8000)) == nil, "never handed to the decoder")
        #expect(PlatformImage.checked(png(width: 400, height: 300)) != nil)
        #expect(!ImageLimits.isReasonable(Data([1, 2, 3])))
        #expect(!ImageLimits.isReasonable(Data()))
    }

    // MARK: SEC-310

    private func named(_ name: String) -> Pulshade.Attachment {
        Pulshade.Attachment(id: Data.random(16).hex, key: .random(32), size: 10, kind: .file, name: name, type: nil,
                            sha256: .random(32), secret: .random(32), expires: Date().addingTimeInterval(3600))
    }

    @Test func fileNamesLoseDirectionOverridesAndInvisibleMarks() {
        let sneaky = named( "invoice\u{202E}fdp.exe")
        #expect(!sneaky.shownName.unicodeScalars.contains { $0.value == 0x202E })
        #expect(sneaky.shownName == "invoicefdp.exe")
        #expect(named( "a\u{200B}b\u{2066}c\u{FEFF}.txt").shownName == "abc.txt")
        #expect(named( "\u{202E}\u{200B}").shownName == "File")
        #expect(named( "../../etc/photo.png").shownName == "photo.png")
    }

    // MARK: SEC-305

    final class Stub: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var announced: Int64 = -1
        nonisolated(unsafe) static var chunks = 0
        nonisolated(unsafe) static var sent = 0
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: Self.announced >= 0 ? ["Content-Length": String(Self.announced)] : [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for _ in 0..<Self.chunks {
                Self.sent += 1
                client?.urlProtocol(self, didLoad: Data(count: 100_000))
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub.self]
        return URLSession(configuration: config, delegate: RelayPinning.shared, delegateQueue: nil)
    }

    @Test func anAnswerBiggerThanItsCapIsDroppedNotBuffered() async throws {
        let request = URLRequest(url: URL(string: "https://relay.test/x")!)
        // Within the cap.
        Stub.announced = -1; Stub.chunks = 3
        let (data, _) = try await RelayPinning.shared.collect(stubSession().dataTask(with: request), limit: 1_000_000)
        #expect(data.count == 300_000)
        // Announced too big: refused before any of it is read.
        Stub.announced = 50_000_000; Stub.chunks = 3; Stub.sent = 0
        await #expect(throws: URLError.self) { _ = try await RelayPinning.shared.collect(stubSession().dataTask(with: request), limit: 1_000_000) }
        // Not announced, but more arrives than the cap: stops, with an error.
        Stub.announced = -1; Stub.chunks = 40
        await #expect(throws: URLError.self) { _ = try await RelayPinning.shared.collect(stubSession().uploadTask(with: request, from: Data([1])), limit: 1_000_000) }
    }

    // MARK: SEC-210

    /// A Burn cut short between keeping its order and wiping (the app killed, the battery gone) is wiped at the next
    /// launch, before the lock screen can open the burned account.
    @Test @MainActor func aBurnCutShortIsWipedAtTheNextLaunch() async throws {
        let directory = testDirectory("pulshade-cutshort")
        let model = AppModel(vault: Vault(directory: directory), watchSystem: false)
        try await model.create(identity: .generate(), profile: Profile(name: "Ada"), passcode: "test-passcode")
        model.lock()
        #expect(model.vault.exists)
        AppModel.markWipeDue(model.burnStore)

        let relaunched = AppModel(vault: Vault(directory: directory), watchSystem: false)
        #expect(!relaunched.vault.exists && relaunched.phase == .welcome)
        #expect(!FileManager.default.fileExists(atPath: AppModel.wipeDueFile(relaunched.burnStore).path), "the mark goes with the wipe")
        #expect(await relaunched.unlock(passcode: "test-passcode") == false)
    }

    /// Detach marks the wipe before it talks to the relay; killed while it waits, the next launch wipes the device (keeping
    /// what a device of several needs to reach the relay, as Detach does). A Detach that fails on the network takes its
    /// mark back, and leaves the account as it was.
    @Test @MainActor func aDetachCutShortIsWipedAtTheNextLaunchAndAFailedOneTakesItsMarkBack() async throws {
        let model = testModel("pulshade-detach-cutshort")
        let directory = model.vault.directory
        let me = Identity.generate()
        try await model.create(identity: me, profile: Profile(name: "Ada"), passcode: "test-passcode")
        // No relay in reach: the backup can't be left, so nothing is wiped and nothing stays marked.
        model.data.relay = "http://127.0.0.1:9"
        await #expect(throws: (any Error).self) { try await model.detach(recoveryCode: me.recoveryCode) }
        #expect(model.vault.exists && model.isOpen)
        #expect(!FileManager.default.fileExists(atPath: AppModel.wipeDueFile(model.burnStore).path))
        model.lock()

        #expect(AppModel.markWipeDue(model.burnStore, keepingSettings: true))
        UserDefaults.standard.set(true, forKey: "pulshade.cutshort-probe")
        defer { UserDefaults.standard.removeObject(forKey: "pulshade.cutshort-probe") }
        let relaunched = AppModel(vault: Vault(directory: directory), watchSystem: false)
        #expect(!relaunched.vault.exists && relaunched.phase == .welcome)
        #expect(!FileManager.default.fileExists(atPath: AppModel.wipeDueFile(relaunched.burnStore).path))
        #expect(UserDefaults.standard.bool(forKey: "pulshade.cutshort-probe"), "a Detach of one device keeps the settings it needs")
    }
}
