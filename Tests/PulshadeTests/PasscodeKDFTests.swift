import Testing
import Foundation
import CryptoKit
import CArgon2
@testable import Pulshade

/// The passcode is stretched with Argon2id (format 4 of the lock file), and every slot's key also needs this device's
/// Secure Enclave to answer for that passcode. Older lock files are brought up to date on the real account's next unlock,
/// without ever locking out a decoy or panic passcode.
@Suite(.serialized) struct PasscodeKDFTests {
    private static func hex(_ bytes: some Sequence<UInt8>) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// The vendored reference code gives RFC 9106's Argon2id test vector (with secret and associated data, four lanes)...
    @Test func theVendoredArgon2MatchesRFC9106() throws {
        var out = [UInt8](repeating: 0, count: 32)
        var password = [UInt8](repeating: 1, count: 32), salt = [UInt8](repeating: 2, count: 16)
        var secret = [UInt8](repeating: 3, count: 8), ad = [UInt8](repeating: 4, count: 12)
        let status = out.withUnsafeMutableBufferPointer { o in
            password.withUnsafeMutableBufferPointer { p in
                salt.withUnsafeMutableBufferPointer { s in
                    secret.withUnsafeMutableBufferPointer { k in
                        ad.withUnsafeMutableBufferPointer { a in
                            var context = argon2_context(out: o.baseAddress, outlen: 32, pwd: p.baseAddress, pwdlen: 32,
                                                         salt: s.baseAddress, saltlen: 16, secret: k.baseAddress, secretlen: 8,
                                                         ad: a.baseAddress, adlen: 12, t_cost: 3, m_cost: 32, lanes: 4, threads: 1,
                                                         version: UInt32(ARGON2_VERSION_13.rawValue), allocate_cbk: nil, free_cbk: nil,
                                                         flags: 0)
                            return argon2_ctx(&context, Argon2_id)
                        }
                    }
                }
            }
        }
        #expect(status == ARGON2_OK.rawValue)
        #expect(Self.hex(out) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    /// ...and the vault's own call gives the reference suite's vector for its settings (one lane, version 1.3).
    @Test func theVaultsArgon2idMatchesTheReferenceVector() throws {
        let key = try Vault.argon2id("password", Vault.Stretch(salt: Data("somesalt".utf8), memory: 65_536, passes: 2))
        #expect(Self.hex(key.bytes) == "09316115d5cf24ed5a15a31a3ba326e5cf32edc24702987c02b6566f61913cf7")
        // A salt too short to mean anything is refused, never stretched.
        #expect(throws: VaultError.self) { try Vault.argon2id("password", Vault.Stretch(salt: Data([1]), memory: 64, passes: 1)) }
    }

    /// Shipped settings: 64 MiB and 3 passes, and an editable lock file can't ask for less or for unbounded work.
    @Test func theCostCanNeitherBeLoweredNorMadeEndless() {
        Vault.fullStretchForTests = true
        defer { Vault.fullStretchForTests = false }
        #expect(Vault.standardMemory == 65_536 && Vault.standardPasses == 3)
        let low = Vault.safeStretch(Vault.Stretch(salt: Data(count: 16), memory: 8, passes: 1))
        #expect(low.memory == 65_536 && low.passes == 3)
        let high = Vault.safeStretch(Vault.Stretch(salt: Data(count: 16), memory: .max, passes: .max))
        #expect(high.memory <= 1_048_576 && high.passes <= 16)
    }

    /// The point the chip is asked about is on the curve, depends on the passcode and the slot, and is the same each time.
    @Test func thePasscodePointDependsOnThePasscodeAndTheSlot() throws {
        let a = SymmetricKey(data: Data(repeating: 1, count: 32)), b = SymmetricKey(data: Data(repeating: 2, count: 32))
        let salt = Data(repeating: 9, count: 16), other = Data(repeating: 8, count: 16)
        let p = try Vault.passcodePoint(a, salt: salt)
        #expect(try Vault.passcodePoint(a, salt: salt).x963Representation == p.x963Representation)
        #expect(try Vault.passcodePoint(b, salt: salt).x963Representation != p.x963Representation)
        #expect(try Vault.passcodePoint(a, salt: other).x963Representation != p.x963Representation)
    }

    /// A new lock file is format 4 from the start and opens only with its passcode.
    @Test func aNewVaultUsesArgon2() throws {
        let vault = Vault(directory: testDirectory("pulshade-kdf-new"))
        let me = Identity.generate()
        try vault.create(me, passcode: "correct-horse")
        #expect(vault.isCurrentFormat)
        guard case let .identity(opened, 0) = try vault.unlock(passcode: "correct-horse") else { Issue.record("no open"); return }
        #expect(opened.fingerprint == me.fingerprint)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "correct-hors") }
    }

    private func oldVault(_ prefix: String) throws -> (Vault, real: Identity, decoy: Identity, landing: Identity) {
        Vault.oldFormatForTests = true
        defer { Vault.oldFormatForTests = false }
        let vault = Vault(directory: testDirectory(prefix))
        let real = Identity.generate(), decoy = Identity.generate(), landing = Identity.generate()
        try vault.create(real, passcode: "real-pass")
        try vault.setSlot(1, identity: decoy, passcode: "decoy-pass")
        try vault.setSlot(2, identity: landing, passcode: "panic-pass", panic: true)
        var data = AppData()
        data.profile.name = "Real"
        try vault.save(data, with: real)
        #expect(!vault.isCurrentFormat && vault.needsUpgrade)
        return (vault, real, decoy, landing)
    }

    /// A lock file from before format 4 (PBKDF2) is upgraded with the real passcode; its decoy and panic passcodes, which
    /// this device can't re-seal without knowing them, keep opening, and are upgraded too once they're set again.
    @Test func anOlderLockFileIsUpgradedAndNothingStopsOpening() throws {
        let (vault, real, decoy, landing) = try oldVault("pulshade-kdf-upgrade")
        try vault.create(real, passcode: "real-pass", replacing: true)
        // Still wanting the Secure Enclave only where it's there but won't make a key now (a locked machine).
        #expect(vault.isCurrentFormat && (!vault.needsUpgrade || !Vault.enclaveMakesKeysNow))
        guard case let .identity(r, 0) = try vault.unlock(passcode: "real-pass") else { Issue.record("real lost"); return }
        #expect(r.fingerprint == real.fingerprint)
        #expect(try vault.load(with: real)?.profile.name == "Real", "the account's data still opens")
        guard case let .identity(d, 1) = try vault.unlock(passcode: "decoy-pass") else { Issue.record("decoy lost"); return }
        #expect(d.fingerprint == decoy.fingerprint)
        guard case let .panic(l, 2) = try vault.unlock(passcode: "panic-pass") else { Issue.record("panic lost"); return }
        #expect(l.fingerprint == landing.fingerprint)
        // Set again, the decoy is sealed in the new form, and its old passcode is gone.
        try vault.setSlot(1, identity: decoy, passcode: "decoy-pass-2")
        guard case .identity(_, 1) = try vault.unlock(passcode: "decoy-pass-2") else { Issue.record("new decoy lost"); return }
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "decoy-pass") }
        vault.rotate()
        guard case .panic = try vault.unlock(passcode: "panic-pass") else { Issue.record("panic lost after rotate"); return }
    }

    /// The real account's unlock does the upgrade by itself, and the panic passcode still works afterwards, landing in a
    /// format 4 file.
    @MainActor @Test func unlockingTheRealAccountUpgradesTheFile() async throws {
        let (vault, _, _, landing) = try oldVault("pulshade-kdf-model")
        let model = AppModel(vault: vault, watchSystem: false)
        model.unlockSettle = .zero
        #expect(await model.unlock(passcode: "real-pass"))
        #expect(model.isPrimary && model.data.profile.name == "Real")
        #expect(vault.isCurrentFormat && (!vault.needsUpgrade || !Vault.enclaveMakesKeysNow))
        model.lock()
        #expect(await model.unlock(passcode: "decoy-pass") && !model.isPrimary)
        model.lock()
        #expect(await model.unlock(passcode: "panic-pass"))
        #expect(model.isPrimary && model.identity?.fingerprint == landing.fingerprint)
        model.lock()
        #expect(vault.isCurrentFormat)
        #expect(await model.unlock(passcode: "panic-pass"), "the landing account opens with the panic passcode afterwards")
        #expect(model.identity?.fingerprint == landing.fingerprint)
        model.lock()
        #expect(await model.unlock(passcode: "real-pass") == false, "the real account is gone")
        #expect(await model.unlock(passcode: "decoy-pass") == false, "and so is the decoy")
    }

    /// With this machine's real Secure Enclave: a file made without it (no enclave then) is bound later, and its other slots
    /// keep opening. Skipped where there's none, or it won't make a key now (the machine is locked, or no login session).
    @Test func bindingAFileMadeWithoutTheEnclaveKeepsItsOtherSlots() throws {
        Vault.bindingOffForTests = false
        guard Vault.canBindToDevice, Vault.enclaveMakesKeysNow else { return }
        Vault.bindingOffForTests = true
        let vault = Vault(directory: testDirectory("pulshade-kdf-enclave"))
        let real = Identity.generate(), decoy = Identity.generate()
        try vault.create(real, passcode: "real-pass")
        try vault.setSlot(1, identity: decoy, passcode: "decoy-pass")
        Vault.bindingOffForTests = false
        #expect(!vault.isDeviceBound && vault.needsUpgrade)
        try vault.create(real, passcode: "real-pass", replacing: true)
        #expect(vault.isDeviceBound && !vault.needsUpgrade)
        guard case .identity(_, 0) = try vault.unlock(passcode: "real-pass") else { Issue.record("real lost"); return }
        guard case .identity(_, 1) = try vault.unlock(passcode: "decoy-pass") else { Issue.record("decoy lost"); return }
    }

    /// The panic passcode answers no later than a normal unlock: both answer at the same settled moment after the check,
    /// and the panic seals the landing account with the stretch the check already did.
    @MainActor @Test func aPanicUnlockTakesNoLongerThanARealOne() async throws {
        let model = testModel("pulshade-kdf-timing")
        defer { model.lock() }
        model.unlockSettle = .milliseconds(300)
        try await model.create(identity: .generate(), profile: Profile(name: "T"), passcode: "real-pass")
        try await model.setDecoy(passcode: "decoy-pass")
        try await model.setPanic(passcode: "panic-pass")
        model.lock()
        let clock = ContinuousClock()
        var real: Duration = .zero
        for _ in 0..<2 {
            let started = clock.now
            #expect(await model.unlock(passcode: "real-pass"))
            real = clock.now - started
            model.lock()
        }
        var started = clock.now
        #expect(await model.unlock(passcode: "decoy-pass"))
        let decoy = clock.now - started
        model.lock()
        started = clock.now
        #expect(await model.unlock(passcode: "panic-pass"))
        let panic = clock.now - started
        #expect(real >= .milliseconds(300) && decoy >= .milliseconds(300) && panic >= .milliseconds(300))
        #expect(panic - real < .milliseconds(250), "panic \(panic) against real \(real)")
    }

    /// An account from before PINs had to be 6 digits, with 4-digit decoy and panic PINs in a PBKDF2 lock file. The real
    /// account's forced change takes new decoy and panic passcodes too: both then open what they opened before (the decoy's
    /// data kept), sealed the current way, and the 4-digit ones open nothing.
    @MainActor @Test func theForcedPINChangeMovesTheDecoyAndPanicPINsToo() async throws {
        Vault.oldFormatForTests = true
        let vault = Vault(directory: testDirectory("pulshade-kdf-short"))
        let real = Identity.generate(), decoy = Identity.generate(), landing = Identity.generate()
        try vault.create(real, passcode: "1234")
        try vault.setSlot(1, identity: decoy, passcode: "5678")
        try vault.setSlot(2, identity: landing, passcode: "9012", panic: true)
        Vault.oldFormatForTests = false
        var data = AppData()
        data.profile.name = "Real"
        data.decoySeed = decoy.seed
        data.panicSeed = landing.seed
        try vault.save(data, with: real)
        var inDecoy = AppData()
        inDecoy.profile.name = "Decoy"
        try vault.save(inDecoy, with: decoy)
        // The keypad was set by the decoy's own forced change first: the real account must still be made to change.
        try vault.updateLockSettings { $0.style = LockStyle.pin6.rawValue; $0.wipeAfter = 10 }

        let model = AppModel(vault: vault, watchSystem: false)
        model.unlockSettle = .zero
        defer { model.lock() }
        #expect(await model.unlock(passcode: "1234"))
        #expect(model.isPrimary && model.hasShortPIN, "opened with 4 digits: changed first, whatever the keypad says")
        #expect(model.hasDecoy && model.hasPanic)
        try await model.changePasscode(current: "1234", to: "482916")
        // A new decoy or panic passcode may not be one another slot opens with, nor the same for both.
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.renewDisguises(decoy: "482916", panic: "615284") }
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.renewDisguises(decoy: "615284", panic: "615284") }
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.renewDisguises(decoy: "7305", panic: nil) }
        try await model.renewDisguises(decoy: "730519", panic: "615284")
        // Tried again after it worked (the sheet retrying): each opens only its own slot, so that's fine.
        try await model.renewDisguises(decoy: "730519", panic: "615284")
        model.openedWithShortSecret = false
        #expect(!model.hasShortPIN)

        for old in ["1234", "5678", "9012"] { #expect(throws: VaultError.self) { try vault.unlock(passcode: old) } }
        guard case let .identity(d, 1) = try vault.unlock(passcode: "730519") else { Issue.record("decoy lost"); return }
        #expect(d.fingerprint == decoy.fingerprint)
        #expect(try vault.load(with: decoy)?.profile.name == "Decoy", "the decoy keeps what was in it")
        guard case let .panic(l, 2) = try vault.unlock(passcode: "615284") else { Issue.record("panic lost"); return }
        #expect(l.fingerprint == landing.fingerprint)
        #expect(vault.slotIsCurrentForm(0, passcode: "482916") && vault.slotIsCurrentForm(1, passcode: "730519")
            && vault.slotIsCurrentForm(2, passcode: "615284"), "every slot sealed the current way")

        // In the decoy it changes nothing, and says nothing different.
        model.lock()
        #expect(await model.unlock(passcode: "730519") && !model.isPrimary && !model.hasShortPIN)
        try await model.renewDisguises(decoy: "111222", panic: nil)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "111222") }
    }
}

/// The lock screen's settings are sealed inside the lock file, whose size doesn't change with them.
@Suite(.serialized) struct LockSettingsTests {
    @Test func theLockFilesSizeDoesNotGiveTheSettingsAway() throws {
        let dir = testDirectory("pulshade-lock-size")
        let vault = Vault(directory: dir)
        try vault.create(.generate(), passcode: "real-pass")
        let lock = dir.appendingPathComponent("identity.lock")
        var sizes = Set<Int>()
        for (style, wipe) in [("pin6", 10), ("passcode", 0), ("pin4", 20), ("pin6", 5)] {
            try vault.updateLockSettings { $0.style = style; $0.wipeAfter = wipe }
            #expect(vault.lockSettings == Vault.LockSettings(style: style, wipeAfter: wipe))
            sizes.insert(try Data(contentsOf: lock).count)
        }
        #expect(sizes.count == 1)
        // Not in the clear anywhere in the file.
        #expect(try Data(contentsOf: lock).range(of: Data("pin6".utf8)) == nil)
    }
}
