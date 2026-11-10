import Testing
import Foundation
@testable import Pulshade

@MainActor
@Suite(.serialized) struct VaultTests {
    private func freshDir() -> URL {
        testDirectory("pulshade-vault")
    }

    private func dataFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".vault") }
    }

    private func makeModel(_ dir: URL) async throws -> AppModel {
        let model = AppModel(vault: Vault(directory: dir), watchSystem: false)
        model.trafficShaping = false
        // Locking would otherwise drop every relay connection in the process, cutting off tests running alongside.
        model.cutOffOnLock = false
        try await model.create(identity: .generate(), profile: Profile(name: "Real"), passcode: "real-pass")
        return model
    }

    @Test func freshVaultLooksTheSameAsOneWithDecoys() async throws {
        let dir = freshDir()
        let model = try await makeModel(dir)
        let lockBefore = try Data(contentsOf: dir.appendingPathComponent("identity.lock"))
        #expect(dataFiles(dir).count == Vault.dataFileCount, "Real data plus filler from the start")
        try await model.setDecoy(passcode: "decoy-pass")
        try await model.setPanic(passcode: "panic-pass")
        let lockAfter = try Data(contentsOf: dir.appendingPathComponent("identity.lock"))
        #expect(lockBefore.count == lockAfter.count, "Slots are the same size either way")
        #expect(dataFiles(dir).count == Vault.dataFileCount, "Same number of files with a decoy and panic set")
        model.removeDecoy()
        #expect(dataFiles(dir).count == Vault.dataFileCount)
        model.lock()
    }

    @Test func decoyOpensSomethingElseAndRealStaysIntact() async throws {
        let dir = freshDir()
        let model = try await makeModel(dir)
        let realFP = model.fingerprint
        model.updateProfile { $0.name = "Real" }
        _ = model.startConversation(kind: .channel, title: "Secret plans", members: [])
        try await model.setDecoy(passcode: "decoy-pass")
        model.lock()

        #expect(await model.unlock(passcode: "decoy-pass"))
        #expect(model.fingerprint != realFP)
        #expect(model.data.conversations.isEmpty)
        #expect(model.data.profile.name == "Real", "Decoy wears your name")
        #expect(!model.isPrimary)
        // Its settings look like the real thing's: a decoy passcode can be "set up" there too, harmlessly.
        try await model.setDecoy(passcode: "another-pass")
        #expect(model.hasDecoy && !model.hasPanic && model.biometricsBlocked)
        model.lock()

        #expect(await model.unlock(passcode: "real-pass"))
        #expect(model.fingerprint == realFP)
        #expect(model.data.conversations.map(\.title) == ["Secret plans"])
        model.lock()
    }

    @Test func panicErasesTheRealIdentity() async throws {
        let dir = freshDir()
        let model = try await makeModel(dir)
        let realFP = model.fingerprint
        _ = model.startConversation(kind: .channel, title: "Secret plans", members: [])
        try await model.setDecoy(passcode: "decoy-pass")
        try await model.setPanic(passcode: "panic-pass")
        model.lock()

        #expect(await model.unlock(passcode: "panic-pass"))
        #expect(model.fingerprint != realFP)
        #expect(model.data.conversations.isEmpty)
        #expect(model.isPrimary, "Afterwards it's an ordinary account, with nothing that looks like a disguise")
        model.lock()

        // The real passcode and the decoy no longer open anything; the panic one is now an ordinary account.
        #expect(await model.unlock(passcode: "real-pass") == false)
        #expect(await model.unlock(passcode: "decoy-pass") == false)
        #expect(await model.unlock(passcode: "panic-pass"))
        model.lock()
    }

    @Test func passcodesMustBeDifferent() async throws {
        let model = try await makeModel(freshDir())
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.setDecoy(passcode: "real-pass") }
        try await model.setDecoy(passcode: "decoy-pass")
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.setPanic(passcode: "decoy-pass") }
        model.lock()
    }

    @Test func dataFilesAllComeInTheSameSizes() async throws {
        let dir = freshDir()
        let model = try await makeModel(dir)
        try await model.setDecoy(passcode: "decoy-pass")
        model.lock()
        let sizes = dataFiles(dir).compactMap {
            try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($0).path)[.size] as? Int
        }
        #expect(sizes.count == Vault.dataFileCount)
        #expect(sizes.allSatisfy { $0 >= 65_536 && $0.nonzeroBitCount == 1 }, "Every file is a power of two from 64 KB")
    }

    @Test func oldLockFilesStopOpeningOnceRewritten() async throws {
        let dir = freshDir()
        let lock = dir.appendingPathComponent("identity.lock")
        let vault = Vault(directory: dir)
        try vault.create(.generate(), passcode: "real-pass")
        let old = try Data(contentsOf: lock)

        // Locking rewrites the file under a new key: a copy recovered from the disk opens nothing, even here.
        vault.rotate()
        let current = try Data(contentsOf: lock)
        #expect(current.count == old.count, "Same size after every rewrite")
        try old.write(to: lock)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "real-pass") }
        try current.write(to: lock)
        #expect(throws: Never.self) { try vault.unlock(passcode: "real-pass") }

        let decoded = try JSONSerialization.jsonObject(with: current) as! [String: Any]
        #expect(decoded["sealed"] != nil && decoded["slots"] == nil, "Slots are hidden inside the seal")
    }

    /// iOS moves an app's whole folder when it's updated. The vault must still open, and adopt its key.
    @Test func aMovedVaultStillOpens() throws {
        let dir = freshDir()
        let moved = freshDir()
        try Vault(directory: dir).create(.generate(), passcode: "real-pass")
        try FileManager.default.moveItem(at: dir, to: moved)
        let vault = Vault(directory: moved)
        #expect(throws: Never.self) { try vault.unlock(passcode: "real-pass") }
        #expect(FileKeys(directory: moved, file: "identity.lock").inUse, "The key now sits under the new name")
        #expect(!FileKeys(directory: dir, file: "identity.lock").inUse, "and the old item is gone")
        vault.rotate()
        #expect(throws: Never.self) { try vault.unlock(passcode: "real-pass") }
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "wrong-pass") }
    }

    /// A right passcode with data that won't open must not open an empty account, which would save over it.
    @Test func unreadableDataIsNeverOpenedEmpty() async throws {
        let dir = freshDir()
        let model = try await makeModel(dir)
        _ = model.startConversation(kind: .channel, title: "Keep me", members: [])
        model.lock()

        let files = dataFiles(dir).map { dir.appendingPathComponent($0) }
        let originals = try files.map { try Data(contentsOf: $0) }
        for (url, data) in zip(files, originals) {
            var damaged = data
            damaged[damaged.count / 2] ^= 0xFF
            try damaged.write(to: url)
        }
        #expect(await model.unlock(passcode: "real-pass") == false)
        #expect(model.dataUnreadable && model.identity == nil && model.phase == .locked)
        #expect(model.failedAttempts == 0, "A right passcode isn't counted as a wrong guess")
        for (url, data) in zip(files, originals) {
            var damaged = data
            damaged[damaged.count / 2] ^= 0xFF
            #expect(try Data(contentsOf: url) == damaged, "Nothing was written over")
            try data.write(to: url)
        }

        #expect(await model.unlock(passcode: "real-pass"))
        #expect(!model.dataUnreadable)
        #expect(model.data.conversations.map(\.title) == ["Keep me"])
        model.lock()
    }

    @Test func destroyRevokesTheLockKey() throws {
        let dir = freshDir()
        let lock = dir.appendingPathComponent("identity.lock")
        let vault = Vault(directory: dir)
        try vault.create(.generate(), passcode: "real-pass")
        let copy = try Data(contentsOf: lock)
        vault.destroy()
        try copy.write(to: lock)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "real-pass") }
    }
}
