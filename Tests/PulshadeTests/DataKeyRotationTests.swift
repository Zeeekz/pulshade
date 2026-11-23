import Testing
import Foundation
import CryptoKit
@testable import Pulshade

/// Every data file is sealed with a Keychain key replaced on every save, so an old copy of the file (left in the disk's
/// free space or a snapshot, holding what was since deleted) stops opening, even with the passcode. Filler files have
/// keys too, so the Keychain doesn't say which files are real.
struct DataKeyRotationTests {
    private func dataURL(_ dir: URL, _ identity: Identity) -> URL {
        let name = Data(SHA256.hash(data: identity.storageKey.withUnsafeBytes { Data($0) } + Data("pulshade.file".utf8)).prefix(12)).hex
        return dir.appendingPathComponent("data-\(name).vault")
    }

    @Test func anOldCopyStopsOpeningOnceTheFileIsSavedAgain() throws {
        let dir = testDirectory("pulshade-datakey-old")
        let vault = Vault(directory: dir)
        let identity = Identity.generate()
        var data = AppData()
        data.profile.name = "Before"
        try vault.save(data, with: identity)
        let url = dataURL(dir, identity)
        let oldCopy = try Data(contentsOf: url)
        #expect(try vault.load(with: identity)?.profile.name == "Before")

        data.profile.name = "After"
        try vault.save(data, with: identity)
        #expect(try vault.load(with: identity)?.profile.name == "After")

        // The old copy put back, as someone recovering it from the disk would: it doesn't open, passcode or not.
        let current = try Data(contentsOf: url)
        try oldCopy.write(to: url)
        #expect(throws: (any Error).self) { _ = try vault.load(with: identity) }
        try current.write(to: url)
        #expect(try vault.load(with: identity)?.profile.name == "After")
        // Only the newest key is kept.
        #expect(FileKeys(directory: dir, file: url.lastPathComponent).load().count == 1)
    }

    /// A file written before data files had Keychain keys still opens, once, and is wrapped by the next save; a copy of
    /// that unwrapped file then stops opening.
    @Test func aFileFromBeforeOpensAndIsWrappedByTheNextSave() throws {
        let dir = testDirectory("pulshade-datakey-legacy")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vault = Vault(directory: dir)
        let identity = Identity.generate()
        var data = AppData()
        data.profile.name = "Old build"
        // Sealed the old way: the storage key alone, padded to its bucket.
        let plain = try JSONEncoder.pulshade.encode(data)
        var padded = Data("PSP1".utf8)
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { padded.append(contentsOf: $0) }
        padded.append(plain)
        padded.append(Data(count: Vault.paddedSize(padded.count + 28) - 28 - padded.count))
        let legacy = try AES.GCM.seal(padded, using: identity.storageKey).combined!
        let url = dataURL(dir, identity)
        try legacy.write(to: url)
        #expect(try vault.load(with: identity)?.profile.name == "Old build")

        try vault.save(data, with: identity)
        try legacy.write(to: url)
        #expect(throws: (any Error).self) { _ = try vault.load(with: identity) }
    }

    /// Every data file, filler included, has a Keychain key, and they go with Burn.
    @MainActor
    @Test func fillersHaveKeysAndBurnRemovesThemAll() async throws {
        let dir = testDirectory("pulshade-datakey-fillers")
        let model = AppModel(vault: Vault(directory: dir), watchSystem: false)
        model.cutOffOnLock = false
        try await model.create(identity: .generate(), profile: Profile(name: "Real"), passcode: "real-pass")
        model.settleSaves()
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".vault") }
        #expect(files.count == Vault.dataFileCount)
        for name in files { #expect(FileKeys(directory: dir, file: name).inUse, "\(name) has a key") }
        model.vault.destroy(leavingNoTrace: true)
        for name in files { #expect(!FileKeys(directory: dir, file: name).inUse, "\(name)'s key is gone") }
        model.lock()
    }

    /// However many saves, the Keychain holds one key for the file afterwards, and at most a few while one is under way
    /// (it never collects every key from before, each of which would open an old copy).
    @Test func theKeyListStaysShort() throws {
        let dir = testDirectory("pulshade-datakey-short")
        let vault = Vault(directory: dir)
        let identity = Identity.generate()
        for n in 0..<12 {
            var data = AppData()
            data.profile.name = "Save \(n)"
            try vault.save(data, with: identity)
            #expect(FileKeys(directory: dir, file: dataURL(dir, identity).lastPathComponent).load().count == 1)
        }
        #expect(try vault.load(with: identity)?.profile.name == "Save 11")
    }
}
