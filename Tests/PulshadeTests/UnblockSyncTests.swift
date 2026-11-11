import Testing
import Foundation
@testable import Pulshade

/// Unblocking someone on one of your devices lets them through on the others too.
@MainActor
@Suite struct UnblockSyncTests {
    @Test func unblockedEventRoundTrips() throws {
        let event = SyncEvent.unblocked("abc123")
        let back = try JSONDecoder.pulshade.decode(SyncEvent.self, from: try JSONEncoder.pulshade.encode(event))
        #expect(back == event)
    }

    @Test func receivingItClearsTheBlockAndTheName() async throws {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        defer { model.lock() }
        model.data.blocked = ["someone", "other"]
        model.data.blockedNames = ["someone": "Someone", "other": "Other"]

        model.applySync(.unblocked("someone"))

        #expect(model.data.blocked == ["other"])
        #expect(model.data.blockedNames["someone"] == nil)
        #expect(model.data.blockedNames["other"] == "Other")
    }
}
