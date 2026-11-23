import Testing
import Foundation
import Observation
@testable import Pulshade

/// An open chat must not be told to redraw on a sync that brings nothing new. Any write to `AppModel.data`, even one
/// that changes nothing, redraws every screen showing it; housekeeping runs on every sync, so one such write there kept
/// the open chat, the chat list and the rest redrawing all the time, behind every scroll and animation.
@MainActor struct IdleRedrawTests {
    @Test func aSyncThatBringsNothingRedrawsNothing() async throws {
        let alice = testModel("idle-redraw"); let bob = testModel("idle-redraw")
        defer { alice.lock(); bob.lock() }
        try await alice.create(identity: .generate(), profile: Profile(name: "A"), passcode: "test-passcode")
        try await bob.create(identity: .generate(), profile: Profile(name: "B"), passcode: "test-passcode")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        for _ in 0..<8 { await alice.syncOnce(); await bob.syncOnce() }
        let fp = try #require(bob.identity?.fingerprint)
        let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
        alice.send("hi", in: chat.id)
        for _ in 0..<6 { await alice.syncOnce(); await bob.syncOnce() }
        final class Count: @unchecked Sendable { var n = 0 }
        let count = Count()
        func watch() {
            withObservationTracking { _ = alice.conversation(chat.id)?.messages.count } onChange: { count.n += 1 }
        }
        var invalidations = 0
        for _ in 0..<20 {
            count.n = 0
            watch()
            await alice.syncOnce()
            invalidations += count.n
        }
        #expect(invalidations == 0, "the open chat was told to redraw on \(invalidations) of 20 syncs that brought nothing")
    }
}
