import Testing
import Foundation
@testable import Pulshade

/// Wake-up pushes, against a throwaway relay. That relay has no Apple key beside it, so
/// it says it can't send pushes, and refuses to take a registration instead of pretending.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct PushTests {
    /// A relay's health check carries a mark that changes each time it starts. A changed mark is noticed once, so the
    /// phone registers for wake-ups again straight away; the same mark, or a relay that sends none, never counts.
    @Test func aRelayRestartIsNoticedOnce() throws {
        let base = try #require(URL(string: "http://restart-\(Int.random(in: 1000...9999)).example"))
        RelayClient.note(boot: "first", of: base)
        #expect(!RelayClient.restartedSinceLastAsked(base), "the first mark is only learnt")
        RelayClient.note(boot: "first", of: base)
        #expect(!RelayClient.restartedSinceLastAsked(base))
        RelayClient.note(boot: "second", of: base)
        #expect(RelayClient.restartedSinceLastAsked(base), "a new mark means it restarted")
        #expect(!RelayClient.restartedSinceLastAsked(base), "and it's said once")
    }

    private var client: RelayClient { RelayClient(base: URL(string: AppData.defaultRelay)!, lane: "push-test") }

    @Test func aRelayWithoutAnAppleKeySaysSoAndTakesNoRegistrations() async throws {
        #expect(await client.pushEnabled() == false)
        let token = String(repeating: "ab", count: 32)
        await #expect(throws: (any Error).self) {
            try await client.registerPush(keys: [Data(repeating: 1, count: 32)], token: token, sandbox: true, sound: true)
        }
    }

    /// Other suites run beside this one and drop every connection in the process when their accounts lock or
    /// reconnect, which cuts a request here off as "cancelled". That says nothing about the relay, so it is tried again.
    private func notCutOff(_ work: () async throws -> Void) async throws {
        for attempt in 0..<4 {
            do { return try await work() } catch let error as URLError where error.code == .cancelled && attempt < 3 { continue }
        }
    }

    @Test func takingARegistrationBackIsHarmlessWhenThereIsNone() async throws {
        try await notCutOff { try await client.unregisterPush(keys: [Data(repeating: 2, count: 32)]) }
    }

    @Test func aDeviceTokenCanBeTakenOffTheRelayWithoutAnyMailboxKeys() async throws {
        try await notCutOff { try await client.forgetPush(token: String(repeating: "cd", count: 32)) }
        await #expect(throws: (any Error).self) { try await client.forgetPush(token: "not a token") }
    }

    /// Reading is split by persona; sending has to be too, or the relay sees one connection write to every
    /// persona's contacts and can tie them together by timing.
    @Test func eachPersonaSendsOnItsOwnConnection() {
        let a = UUID(), b = UUID()
        #expect(Outgoing.lane(for: nil) == "send")
        #expect(Outgoing.lane(for: a) != Outgoing.lane(for: b))
        #expect(Outgoing.lane(for: a) != Outgoing.lane(for: nil))
        #expect(Outgoing.lane(for: a) == Outgoing.lane(for: a))
    }

    @Test func mailQueuedBeforeSendingLanesExistedStillSendsOnTheMainLane() throws {
        let old = #"{"id":"0F1D8F7E-2B6A-4C57-9E3A-1A2B3C4D5E6F","sendID":"AAAA","blob":"AAAA"}"#
        let item = try JSONDecoder.pulshade.decode(Outgoing.self, from: Data(old.utf8))
        #expect(item.lane == nil)
    }

    @Test func pushIsAlwaysOnWithNotifications() {
        let s = SecuritySettings()
        #expect(s.notifications && s.pushWake && s.pushRequests && s.keepReceivingLocked)
    }

    /// Waking, friend request wake-ups and receiving while locked are no longer choices: an "off" saved by an older
    /// build is ignored, and none of them is saved any more.
    @Test func anOffSavedBeforeIsIgnored() throws {
        let old = try JSONSerialization.data(withJSONObject: ["autoLockMinutes": 5, "notifications": true, "pushWake": false,
                                                              "pushWakeChosen": true, "pushRequests": false, "keepReceivingLocked": false])
        let settings = try JSONDecoder.pulshade.decode(SecuritySettings.self, from: old)
        #expect(settings.pushWake && settings.pushRequests && settings.keepReceivingLocked)
        let saved = String(decoding: try JSONEncoder.pulshade.encode(settings), as: UTF8.self)
        #expect(!saved.contains("pushWake") && !saved.contains("pushRequests") && !saved.contains("keepReceivingLocked"))
    }

    /// Even the strictest choices on the sign-up screen keep them; turning notifications off is what stops wake-ups.
    @Test func theStrictestChoicesKeepThemOn() {
        let s = SecuritySettings.strictest
        #expect(!s.notifications && s.pushWake && s.pushRequests && s.keepReceivingLocked)
    }

    /// An automatic lock only hides the app behind the passcode: the keys stay loaded so mail still comes in and receipts
    /// go out. A lock pressed by hand closes it.
    @MainActor @Test func autoLockCanKeepReceivingBehindThePasscode() async throws {
        let model = testModel("pulshade-cover")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "C"), passcode: "test-passcode")

        model.lock(keepingKeys: true)
        #expect(model.phase == .unlocked && model.covered && model.identity != nil)
        #expect(!model.isOpen)
        #expect(await model.unlock(passcode: "wrong") == false)
        #expect(model.covered)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.isOpen)

        model.lock()
        #expect(model.phase == .locked && model.identity == nil, "a lock pressed by hand always closes it")
    }

    /// With a decoy passcode set, an automatic lock behaves exactly as without one (it covers), so locking gives no decoy
    /// away; the decoy passcode typed at the covered screen closes the real account and opens the decoy.
    @MainActor @Test func aDecoyChangesNothingAboutAutoLock() async throws {
        let model = testModel("pulshade-cover-decoy")
        defer { model.lock() }
        let real = Identity.generate()
        try await model.create(identity: real, profile: Profile(name: "D"), passcode: "test-passcode")
        try await model.setDecoy(passcode: "decoy-passcode")
        model.lock(keepingKeys: true)
        #expect(model.phase == .unlocked && model.covered && model.identity?.fingerprint == real.fingerprint)
        #expect(await model.unlock(passcode: "decoy-passcode"))
        #expect(model.isOpen && !model.isPrimary && model.identity?.fingerprint != real.fingerprint)
        #expect(model.data.decoySeed == nil, "nothing of the real account is left open")
        // The decoy covers too, and the real passcode at its covered screen opens the real account.
        model.lock(keepingKeys: true)
        #expect(model.covered && !model.isPrimary)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.isOpen && model.isPrimary && model.identity?.fingerprint == real.fingerprint && model.hasDecoy)
    }

    /// "Close everything" makes an automatic lock a full one: keys and chats leave memory, decoy or not.
    @MainActor @Test func closeEverythingMakesAutoLockAFullLock() async throws {
        let model = testModel("pulshade-cover-full")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "F"), passcode: "test-passcode")
        model.updateSecurity { $0.fullLock = true }
        model.lock(keepingKeys: true)
        #expect(model.phase == .locked && !model.covered && model.identity == nil)
        #expect(await model.unlock(passcode: "test-passcode"))
        #expect(model.isOpen && model.data.security.fullLock)
    }

    /// "Immediately" locks the moment the app is left, and the iPhone locking locks it unless auto-lock is never.
    @MainActor @Test func immediatelyAndTheDeviceLockingLockTheApp() async throws {
        let model = testModel("pulshade-lock-now")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "I"), passcode: "test-passcode")
        model.leftApp()
        #expect(model.isOpen, "not without Immediately")
        model.updateSecurity { $0.lockImmediately = true; $0.autoLockMinutes = 1 }
        model.didEnterBackground()
        #expect(model.covered)
        #expect(await model.unlock(passcode: "test-passcode"))
        model.updateSecurity { $0.lockImmediately = false; $0.autoLockMinutes = 5 }
        model.deviceLocked()
        #expect(model.covered, "the device locking locks it")
        #expect(await model.unlock(passcode: "test-passcode"))
        model.updateSecurity { $0.autoLockMinutes = 0 }
        model.deviceLocked()
        #expect(model.isOpen, "auto-lock set to never leaves it open")
    }

    /// What was chosen on the sign-up screen goes to the account made next, and nowhere else.
    @MainActor @Test func privacyChosenBeforeSignUpGoesToTheNewAccount() async throws {
        defer { PendingPrivacy.chosen = nil }
        PendingPrivacy.chosen = .strictest
        let model = testModel("pulshade-pending")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "N"), passcode: "test-passcode")
        let s = model.data.security
        #expect(!s.readReceipts && !s.typingIndicators && !s.onlineStatus && !s.linkPreviews)
        #expect(s.autoLockMinutes == 1 && s.notificationContent == .hidden)
        #expect(s.tor == Tor.enabled, "the connection choice is its own screen and is left alone")
    }
}
