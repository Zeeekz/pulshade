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

    @MainActor @Test func wipeAfterWrongGuessesIsOffUntilChosenThenWipesLikeDetach() async throws {
        let model = testModel("pulshade-wipe-after")
        defer { WipeAfterFailures.limit = 0; model.failedAttempts = 0; model.unlockHook = nil; model.lock() }
        WipeAfterFailures.limit = 0
        model.failedAttempts = 0
        let me = Identity.generate()
        try await model.create(identity: me, profile: Profile(name: "W"), passcode: "test-passcode")
        // Other suites burn accounts, which clears every test's in-memory Keychain keys; a real unlock here could then fail for
        // a reason that is not a wrong guess (and is, rightly, not counted). The vault is answered for, the counting is real.
        model.unlockHook = Self.honestVault(me)
        #expect(model.wipeAfterAttempts == 0)
        model.setWipeAfterAttempts(7)
        #expect(model.wipeAfterAttempts == 0, "only the listed choices")
        model.setWipeAfterAttempts(5)
        #expect(model.wipeAfterAttempts == 5)
        #expect(WipeAfterFailures.reached(5) && !WipeAfterFailures.reached(4))

        // Wrong guesses are counted whatever slots exist, and a right one starts again.
        model.lock()
        for _ in 0..<2 { #expect(await model.unlock(passcode: "nope-nope") == false) }
        #expect(model.failedAttempts == 2 && model.phase == .locked)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.failedAttempts == 0)
        model.lock()
        model.failedAttempts = 4
        // The setting lives in the process's shared defaults, which another suite's Burn clears while this one waits out the
        // delay a wrong guess earns; keep it as chosen until the wipe has happened.
        let keeper = Task { @MainActor in
            while model.phase != .welcome, !Task.isCancelled { WipeAfterFailures.limit = 5; try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(await model.unlock(passcode: "nope-nope") == false)
        keeper.cancel()
        #expect(model.phase == .welcome, "the fifth wrong guess wipes the device")
        #expect(!model.vault.exists)
        #expect(model.failedAttempts == 0 && WipeAfterFailures.limit == 0)
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
        defer { WipeAfterFailures.limit = 0; model.failedAttempts = 0; model.unlockHook = nil; model.lock() }
        WipeAfterFailures.limit = 0
        model.failedAttempts = 0
        let me = Identity.generate()
        try await model.create(identity: me, profile: Profile(name: "T"), passcode: "test-passcode")
        model.setWipeAfterAttempts(3)
        model.updateSecurity { $0.keepReceivingLocked = true }
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
