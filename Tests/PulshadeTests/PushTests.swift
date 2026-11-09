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

    @Test func takingARegistrationBackIsHarmlessWhenThereIsNone() async throws {
        try await client.unregisterPush(keys: [Data(repeating: 2, count: 32)])
    }

    @Test func aDeviceTokenCanBeTakenOffTheRelayWithoutAnyMailboxKeys() async throws {
        try await client.forgetPush(token: String(repeating: "cd", count: 32))
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

    @Test func pushIsOnWithNotificationsUnlessTurnedOff() {
        #expect(SecuritySettings().pushWake == true)
    }

    @Test func settingsFromBeforePushExistedStillOpen() throws {
        let json = try JSONSerialization.data(withJSONObject: ["autoLockMinutes": 5, "notifications": true])
        let settings = try JSONDecoder.pulshade.decode(SecuritySettings.self, from: json)
        #expect(settings.pushWake == true)
    }

    /// Off was everyone's default once, so an "off" saved then is not a choice; one made by hand is kept.
    @MainActor @Test func onlyAnOffChosenByHandStaysOff() async throws {
        let unchosen = try JSONSerialization.data(withJSONObject: ["pushWake": false])
        #expect(try JSONDecoder.pulshade.decode(SecuritySettings.self, from: unchosen).pushWake == true)

        let model = testModel("pulshade-push")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "P"), passcode: "test-passcode")
        model.updateSecurity { $0.pushWake = false }
        let saved = try JSONEncoder.pulshade.encode(model.data.security)
        #expect(try JSONDecoder.pulshade.decode(SecuritySettings.self, from: saved).pushWake == false)
    }

    /// With "keep receiving while locked" on, an automatic lock only hides the app behind the passcode: the keys stay
    /// loaded so mail still comes in and receipts go out. A lock pressed by hand, or with the setting off, closes it.
    @MainActor @Test func autoLockCanKeepReceivingBehindThePasscode() async throws {
        let model = testModel("pulshade-cover")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "C"), passcode: "test-passcode")

        model.lock(keepingKeys: true)
        #expect(model.phase == .locked, "off by default: an automatic lock closes everything")
        #expect(await model.unlock(passcode: "test-passcode"))

        model.updateSecurity { $0.keepReceivingLocked = true }
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

    /// What was chosen on the sign-up screen goes to the account made next, and nowhere else.
    @MainActor @Test func privacyChosenBeforeSignUpGoesToTheNewAccount() async throws {
        defer { PendingPrivacy.chosen = nil }
        PendingPrivacy.chosen = .strictest
        let model = testModel("pulshade-pending")
        defer { model.lock() }
        try await model.create(identity: .generate(), profile: Profile(name: "N"), passcode: "test-passcode")
        let s = model.data.security
        #expect(!s.deliveryReceipts && !s.readReceipts && !s.typingIndicators && !s.onlineStatus && !s.linkPreviews)
        #expect(s.autoLockMinutes == 1 && s.notificationContent == .hidden)
        #expect(s.tor == Tor.enabled, "the connection choice is its own screen and is left alone")
    }
}
