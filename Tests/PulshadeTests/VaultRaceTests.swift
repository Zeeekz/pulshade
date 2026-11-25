import Testing
import Foundation
@testable import Pulshade

/// The lock file is rewritten from more than one thread: a passcode change, a decoy or a panic passcode is set in the
/// background (stretching a passcode takes a while), while locking rotates the file's Keychain key on the main thread.
/// Each rewrite reads the slots and the Keychain's key list, changes them and writes them back, so two that overlap
/// could each undo the other: a passcode just set would be gone, or the file left sealed under a key the Keychain
/// had already dropped, and then it would never open again.
@Suite(.serialized) struct VaultRaceTests {
    @Test func rewritesFromSeveralThreadsNeverLoseAPasscodeOrTheFile() async throws {
        let dir = testDirectory("pulshade-vault-race")
        let vault = Vault(directory: dir)
        let real = Identity.generate(), decoy = Identity.generate(), landing = Identity.generate()
        try vault.create(real, passcode: "real-pass")

        let done = Done()
        // Locking, over and over, while the passcodes below are set.
        let rotating = Thread {
            while !done.value { vault.rotate() }
        }
        rotating.start()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<3 { try? vault.setSlot(1, identity: decoy, passcode: "decoy-pass-\(i)") }
            }
            group.addTask {
                for i in 0..<3 { try? vault.setSlot(2, identity: landing, passcode: "panic-pass-\(i)", panic: true) }
            }
        }
        done.value = true
        while rotating.isExecuting { try await Task.sleep(for: .milliseconds(10)) }

        // The file still opens, and both passcodes set last are there.
        guard case let .identity(opened, slot) = try vault.unlock(passcode: "real-pass") else {
            Issue.record("The real passcode no longer opens the real identity")
            return
        }
        #expect(opened.fingerprint == real.fingerprint && slot == 0)
        guard case let .identity(openedDecoy, decoySlot) = try vault.unlock(passcode: "decoy-pass-2") else {
            Issue.record("The decoy passcode set last was lost")
            return
        }
        #expect(openedDecoy.fingerprint == decoy.fingerprint && decoySlot == 1)
        guard case let .panic(openedLanding, panicSlot) = try vault.unlock(passcode: "panic-pass-2") else {
            Issue.record("The panic passcode set last was lost")
            return
        }
        #expect(openedLanding.fingerprint == landing.fingerprint && panicSlot == 2)
    }
}

/// Adding the Secure Enclave binding to an older lock file must never cost a decoy or panic passcode. It used to rebuild
/// every slot from filler (and rebalance the data files), trusting the account's saved data to say none was set.
@Suite(.serialized) struct VaultBindingTests {
    private func vaultWithDecoyAndPanic(_ dir: URL) throws -> (Vault, real: Identity, decoy: Identity, landing: Identity) {
        let vault = Vault(directory: dir)
        let real = Identity.generate(), decoy = Identity.generate(), landing = Identity.generate()
        try vault.create(real, passcode: "real-pass")
        try vault.setSlot(1, identity: decoy, passcode: "decoy-pass")
        try vault.setSlot(2, identity: landing, passcode: "panic-pass", panic: true)
        var decoyData = AppData()
        decoyData.profile.name = "Decoy"
        try vault.save(decoyData, with: decoy)
        return (vault, real, decoy, landing)
    }

    private func expectAllOpen(_ vault: Vault, real: Identity, decoy: Identity, landing: Identity) throws {
        guard case let .identity(r, 0) = try vault.unlock(passcode: "real-pass") else { Issue.record("real lost"); return }
        #expect(r.fingerprint == real.fingerprint)
        guard case let .identity(d, 1) = try vault.unlock(passcode: "decoy-pass") else { Issue.record("decoy lost"); return }
        #expect(d.fingerprint == decoy.fingerprint)
        guard case let .panic(l, 2) = try vault.unlock(passcode: "panic-pass") else { Issue.record("panic lost"); return }
        #expect(l.fingerprint == landing.fingerprint)
        #expect(try vault.load(with: decoy)?.profile.name == "Decoy", "the decoy's data is still there")
    }

    @Test func replacingTheLockKeepsEveryOtherSlotAndItsData() throws {
        let (vault, real, decoy, landing) = try vaultWithDecoyAndPanic(testDirectory("pulshade-vault-bind"))
        try vault.create(real, passcode: "real-pass", replacing: true)
        try expectAllOpen(vault, real: real, decoy: decoy, landing: landing)
    }

    /// A file that's gone (a Burn got there first) is never made again by the binding upgrade.
    @Test func replacingAFileThatIsGoneMakesNothing() throws {
        let dir = testDirectory("pulshade-vault-bind-gone")
        let vault = Vault(directory: dir)
        let real = Identity.generate()
        try vault.create(real, passcode: "real-pass")
        vault.destroy(leavingNoTrace: true)
        #expect(throws: VaultError.self) { try vault.create(real, passcode: "real-pass", replacing: true) }
        #expect(!vault.exists)
    }

    /// With this machine's real Secure Enclave: an unbound file is bound, its old slots keep opening, and a slot rewritten
    /// afterwards is bound too. Skipped where there's no Secure Enclave, the run switched it off, or it won't make a key
    /// right now (the machine is locked, or the run has no login session).
    @Test func bindingAnOlderFileKeepsItsDecoyAndPanicOpening() throws {
        Vault.bindingOffForTests = false
        guard Vault.canBindToDevice, Vault.enclaveMakesKeysNow else { return }
        Vault.bindingOffForTests = true
        let made = try vaultWithDecoyAndPanic(testDirectory("pulshade-vault-bind-enclave"))
        Vault.bindingOffForTests = false
        let (vault, real, decoy, landing) = made
        #expect(!vault.isDeviceBound)
        try vault.create(real, passcode: "real-pass", replacing: true)
        #expect(vault.isDeviceBound)
        try expectAllOpen(vault, real: real, decoy: decoy, landing: landing)
        // Rewritten now, the decoy slot is sealed with the device's secret like the rest.
        try vault.setSlot(1, identity: decoy, passcode: "decoy-pass-2")
        guard case let .identity(d, 1) = try vault.unlock(passcode: "decoy-pass-2") else { Issue.record("new decoy lost"); return }
        #expect(d.fingerprint == decoy.fingerprint)
        #expect((try? vault.unlock(passcode: "decoy-pass")) == nil, "the old decoy passcode is gone")
        // Locking rotates the key and keeps all of it.
        vault.rotate()
        guard case .panic = try vault.unlock(passcode: "panic-pass") else { Issue.record("panic lost after rotate"); return }
    }
}

private final class Done: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
        get { lock.withLock { flag } }
        set { lock.withLock { flag = newValue } }
    }
}
