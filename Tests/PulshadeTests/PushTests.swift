import Testing
import Foundation
@testable import Pulshade

/// Wake-up pushes, against the throwaway relay `scripts/test.sh` starts. That relay has no Apple key beside it, so
/// it says it can't send pushes, and refuses to take a registration instead of pretending.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct PushTests {
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

    @Test func pushIsOffUntilTheUserTurnsItOn() {
        #expect(SecuritySettings().pushWake == false)
    }

    @Test func settingsFromBeforePushExistedStillOpen() throws {
        let json = try JSONSerialization.data(withJSONObject: ["autoLockMinutes": 5, "notifications": true])
        let settings = try JSONDecoder.pulshade.decode(SecuritySettings.self, from: json)
        #expect(settings.pushWake == false)
    }
}
