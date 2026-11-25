import Testing
import Foundation
@testable import Pulshade

@Suite(.serialized) struct LockStyleTests {
    @Test func pinsNeedExactlyTheirDigits() {
        #expect(LockStyle.pin4.accepts("1234"))
        #expect(!LockStyle.pin4.accepts("123"))
        #expect(!LockStyle.pin4.accepts("12345"))
        #expect(LockStyle.pin6.accepts("123456"))
        #expect(!LockStyle.pin6.accepts("1234"))
        #expect(!LockStyle.pin6.accepts("12345a"))
        #expect(!LockStyle.pin6.accepts("١٢٣٤٥٦"), "only ASCII digits")
    }

    @Test func passcodeKeepsItsSixCharacterMinimum() {
        #expect(LockStyle.passcode.accepts("abcdef"))
        #expect(!LockStyle.passcode.accepts("abcde"))
        #expect(LockStyle.passcode.accepts("123456"))
    }

    @Test func typingIsFilteredForPINs() {
        #expect(LockStyle.pin4.filtered("12a34567") == "1234")
        #expect(LockStyle.pin6.filtered("1 2-3") == "123")
        #expect(LockStyle.passcode.filtered("Ab 1!") == "Ab 1!")
    }

    @Test func disguiseSecretsAreNeverShorterThanSix() {
        #expect(!LockStyle.forDisguise.contains(.pin4))
    }

    @Test func aPINOpensTheVaultLikeAnyPasscode() throws {
        let vault = Vault(directory: testDirectory("pulshade-lockstyle"))
        let identity = Identity.generate()
        try vault.create(identity, passcode: "4821")
        guard case let .identity(opened, _) = try vault.unlock(passcode: "4821") else {
            Issue.record("wrong role"); return
        }
        #expect(opened.seed == identity.seed)
        #expect(throws: VaultError.self) { try vault.unlock(passcode: "4822") }
    }

    // MARK: SEC-103

    @Test func aNewSecretIsNeverAFourDigitPIN() {
        #expect(!LockStyle.forNewSecret.contains(.pin4))
        #expect(LockStyle.pin4.forChoosing == .pin6 && LockStyle.pin6.forChoosing == .pin6 && LockStyle.passcode.forChoosing == .passcode)
        #expect(LockStyle.isPattern("111111") && LockStyle.isPattern("123456") && LockStyle.isPattern("987654"))
        #expect(!LockStyle.isPattern("481726") && !LockStyle.isPattern("hunter2"))
        #expect(LockStyle.guidance(for: "123456", style: .pin6) != nil)
        #expect(LockStyle.guidance(for: "correct horse battery", style: .passcode) == nil)
    }

    @MainActor @Test func theAccountRefusesAPasscodeShorterThanSix() async throws {
        let model = testModel("pulshade-short-pin")
        defer { model.lock() }
        await #expect(throws: AppModel.PasscodeSetupError.self) {
            try await model.create(identity: .generate(), profile: Profile(name: "S"), passcode: "4821")
        }
        #expect(model.identity == nil)
    }

    @MainActor @Test func changingThePasscodeKeepsTheDecoyAndPanicSlots() async throws {
        let model = testModel("pulshade-change-pass")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "C"), passcode: "old-passcode")
        try await model.setDecoy(passcode: "decoy-passcode")
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.changePasscode(current: "wrong-one", to: "new-passcode") }
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.changePasscode(current: "old-passcode", to: "1234") }
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.changePasscode(current: "old-passcode", to: "decoy-passcode") }
        model.failedAttempts = 0
        try await model.changePasscode(current: "old-passcode", to: "new-passcode")
        model.lock()
        #expect(await model.unlock(passcode: "old-passcode") == false)
        #expect(await model.unlock(passcode: "new-passcode"))
        #expect(model.isPrimary && model.hasDecoy)
        model.lock()
        #expect(await model.unlock(passcode: "decoy-passcode"))
        #expect(!model.isPrimary, "the decoy still opens")
    }

    @MainActor @Test func wipeAfterWrongGuessesIsOnForNewAccountsThenWipesLikeDetach() async throws {
        let model = testModel("pulshade-wipe-after")
        defer { model.failedAttempts = 0; model.unlockHook = nil; model.lock() }
        model.failedAttempts = 0
        let me = Identity.generate()
        try await model.create(identity: me, profile: Profile(name: "W"), passcode: "test-passcode")
        // Other suites burn accounts, which clears every test's in-memory Keychain keys; a real unlock here could then fail for
        // a reason that is not a wrong guess (and is, rightly, not counted). The vault is answered for, the counting is real.
        model.unlockHook = Self.honestVault(me)
        #expect(model.wipeAfterAttempts == 10, "a new account wipes after 10 wrong guesses")
        model.setWipeAfterAttempts(7)
        #expect(model.wipeAfterAttempts == 10, "only the listed choices")
        model.setWipeAfterAttempts(5)
        #expect(model.wipeAfterAttempts == 5)
        #expect(model.vault.lockSettings?.wipeAfter == 5, "kept in the lock file")
        #expect(WipeAfterFailures.reached(5, limit: 5) && !WipeAfterFailures.reached(4, limit: 5) && !WipeAfterFailures.reached(50, limit: 0))

        // Wrong guesses are counted whatever slots exist, and a right one starts again.
        model.lock()
        for _ in 0..<2 { #expect(await model.unlock(passcode: "nope-nope") == false) }
        #expect(model.failedAttempts == 2 && model.phase == .locked)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.failedAttempts == 0)
        model.lock()
        model.failedAttempts = 4
        #expect(await model.unlock(passcode: "nope-nope") == false)
        #expect(model.phase == .welcome, "the fifth wrong guess wipes the device")
        #expect(!model.vault.exists)
        #expect(model.failedAttempts == 0 && model.vault.lockSettings == nil)
    }

    /// The setting is sealed in the lock file: a plain preference saying "off" (what `defaults write` could put there on the
    /// test machine) changes nothing, and one left by an older build is moved in once and removed.
    @MainActor @Test func wipeAfterAndTheKeypadAreSealedInTheLockFileNotPreferences() async throws {
        let defaults = UserDefaults.standard
        let model = testModel("pulshade-wipe-sealed")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "S"), passcode: "test-passcode")
        model.lockStyle = .pin6
        defaults.set(0, forKey: WipeAfterFailures.key)
        defaults.set(LockStyle.passcode.rawValue, forKey: LockStyle.key)
        model.moveLockSettingsIntoVault()
        #expect(model.wipeAfterAttempts == 10 && model.lockStyle == .pin6, "preferences are ignored once the lock file has them")
        defaults.removeObject(forKey: WipeAfterFailures.key)
        defaults.removeObject(forKey: LockStyle.key)

        // An account from an older build: nothing in its lock file yet, the choices in preferences.
        let older = testModel("pulshade-wipe-move")
        defer { older.lock() }
        try older.vault.create(.generate(), passcode: "test-passcode", settings: Vault.LockSettings())
        try older.vault.updateLockSettings { $0 = Vault.LockSettings() }
        #expect(older.vault.lockSettings == Vault.LockSettings())
        defaults.set(20, forKey: WipeAfterFailures.key)
        defaults.set(LockStyle.pin4.rawValue, forKey: LockStyle.legacyKey)
        older.moveLockSettingsIntoVault()
        #expect(older.vault.lockSettings == Vault.LockSettings(style: "pin4", wipeAfter: 20))
        #expect(older.wipeAfterAttempts == 20 && older.lockStyle == .pin4 && older.hasShortPIN)
        #expect(defaults.object(forKey: WipeAfterFailures.key) == nil && defaults.string(forKey: LockStyle.legacyKey) == nil)
        // And one that had chosen nothing keeps the wipe off, as it was.
        let none = testModel("pulshade-wipe-none")
        try none.vault.create(.generate(), passcode: "test-passcode", settings: Vault.LockSettings())
        try none.vault.updateLockSettings { $0 = Vault.LockSettings() }
        for key in [WipeAfterFailures.key, LockStyle.key, LockStyle.legacyKey] { defaults.removeObject(forKey: key) }
        none.moveLockSettingsIntoVault()
        #expect(none.wipeAfterAttempts == 0 && none.lockStyle == .passcode, "\(String(describing: none.vault.lockSettings))")
    }

    /// An updated account whose settings haven't moved into the lock file yet (the Keychain didn't answer at launch): its
    /// wipe isn't off meanwhile, nor its keypad the wrong one, and the move is tried again before a guess is judged.
    @MainActor @Test func wipeAfterHoldsBeforeTheSettingsHaveMoved() async throws {
        let defaults = UserDefaults.standard
        let keys = [WipeAfterFailures.key, LockStyle.key, LockStyle.legacyKey]
        defer { for key in keys { defaults.removeObject(forKey: key) } }
        let me = Identity.generate()
        let model = testModel("pulshade-wipe-unmoved")
        defer { model.failedAttempts = 0; model.unlockHook = nil; model.lock() }
        try model.vault.create(me, passcode: "test-passcode", settings: Vault.LockSettings())
        try model.vault.updateLockSettings { $0 = Vault.LockSettings() }
        model.unlockHook = Self.honestVault(me)
        defaults.set(5, forKey: WipeAfterFailures.key)
        defaults.set(LockStyle.pin6.rawValue, forKey: LockStyle.legacyKey)
        #expect(model.vault.lockSettings == Vault.LockSettings(), "not moved yet")
        #expect(model.wipeAfterAttempts == 5 && model.lockStyle == .pin6, "the older build's choices hold meanwhile")

        model.failedAttempts = 3
        #expect(await model.unlock(passcode: "nope-nope") == false)
        #expect(model.vault.lockSettings == Vault.LockSettings(style: "pin6", wipeAfter: 5), "moved before the guess was judged")
        #expect(keys.allSatisfy { defaults.object(forKey: $0) == nil })
        // A preference written now changes nothing: the lock file has the settings.
        defaults.set(0, forKey: WipeAfterFailures.key)
        #expect(model.wipeAfterAttempts == 5)
        #expect(await model.unlock(passcode: "nope-nope") == false)
        #expect(!model.vault.exists, "the fifth wrong guess wipes")
    }

    /// What a vault holding `identity` behind "test-passcode" answers: it opens for that passcode and says wrong for any other.
    static func honestVault(_ identity: Identity) -> @Sendable (String) throws -> Vault.Opened {
        { passcode in
            guard passcode == "test-passcode" else { throw VaultError.wrongPasscode }
            return .identity(identity, slot: 0)
        }
    }

    /// SEC-201: only a passcode that opened nothing is a wrong guess. Keychain trouble, a damaged or missing lock file
    /// say nothing about the guess, so they must neither move the counter nor trigger the wipe.
    @MainActor @Test func onlyAGenuineWrongPasscodeCountsTowardsTheWipe() async throws {
        let model = testModel("pulshade-wipe-transient")
        defer { model.failedAttempts = 0; model.unlockHook = nil; model.lock() }
        model.failedAttempts = 0
        let me = Identity.generate()
        try await model.create(identity: me, profile: Profile(name: "T"), passcode: "test-passcode")
        model.setWipeAfterAttempts(3)
        let transient: [VaultError] = [.keychain(-25308), .corrupt, .missing]

        // Fully locked.
        model.lock()
        for error in transient + transient {
            model.unlockHook = { _ in throw error }
            #expect(await model.unlock(passcode: "test-passcode") == false)
            #expect(model.failedAttempts == 0 && model.phase == .locked && model.vault.exists)
        }
        model.unlockHook = { _ in throw CocoaError(.fileReadUnknown) }
        #expect(await model.unlock(passcode: "test-passcode") == false)
        #expect(model.failedAttempts == 0 && model.vault.exists)
        // A real wrong passcode, reported by the vault itself, still counts.
        model.unlockHook = { _ in throw VaultError.wrongPasscode }
        #expect(await model.unlock(passcode: "nope-nope") == false)
        #expect(model.failedAttempts == 1)
        model.unlockHook = Self.honestVault(me)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.failedAttempts == 0)

        // Covered (keys kept): same rule.
        model.lock(keepingKeys: true)
        #expect(model.covered)
        for error in transient {
            model.unlockHook = { _ in throw error }
            #expect(await model.unlock(passcode: "test-passcode") == false)
            #expect(model.failedAttempts == 0 && model.covered)
        }
        model.unlockHook = Self.honestVault(me)
        #expect(await model.unlock(passcode: "nope-nope") == false)
        #expect(model.failedAttempts == 1)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(!model.covered && model.failedAttempts == 0)

        // Changing the passcode.
        for error in transient {
            model.unlockHook = { _ in throw error }
            await #expect(throws: VaultError.self) { try await model.changePasscode(current: "test-passcode", to: "another-passcode") }
            #expect(model.failedAttempts == 0)
        }
        model.unlockHook = Self.honestVault(me)
        await #expect(throws: AppModel.PasscodeSetupError.self) { try await model.changePasscode(current: "nope-nope", to: "another-passcode") }
        #expect(model.failedAttempts == 1)
        #expect(model.phase == .unlocked && model.vault.exists)
    }

    /// SEC-203: a write the debounce had already started is still being waited for before an envelope leaves.
    @MainActor @Test func sendingWaitsForAWriteThatIsAlreadyUnderWay() async throws {
        let model = testModel("pulshade-save-wait")
        defer { model.saveDelayForTesting = 0; model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "S"), passcode: "test-passcode")
        model.settleSaves()
        model.saveDelayForTesting = 2.0
        model.data.outbox.append(Outgoing(sendID: Data(count: 32), blob: Data(count: 8)))
        model.save()
        // Past the debounce: the write has started (and is held), nothing is left waiting in memory.
        for _ in 0..<100 where model.saveWritesInFlight == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(model.saveWritesInFlight == 1, "the write is under way")
        // Something is waiting to be sent (a background pass may have taken the first one by now).
        if model.data.outbox.isEmpty { model.data.outbox.append(Outgoing(sendID: Data(count: 32), blob: Data(count: 8))) }
        let ok = await model.stateIsOnDiskBeforeSending()
        #expect(ok)
        #expect(model.saveWritesInFlight == 0, "it did not return before the write ended")
    }
}
