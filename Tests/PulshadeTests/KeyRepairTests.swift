import Testing
import Foundation
@testable import Pulshade

/// Two phones whose keys fall out of step mend on their own, and nothing written meanwhile is lost: the phone that
/// can't open a message asks for new keys, and the sender sends again, on the new keys, everything not yet confirmed.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct KeyRepairTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        // No sealed backups: the relay takes only so many an hour from one address, and the backup tests need them.
        model.data.security.keepBackup = false
        return model
    }

    private func until(_ models: [AppModel], seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func received(_ m: AppModel) -> [String] {
        // Not the announcements chat: another suite's test announcements reach every account on the shared test relay.
        m.data.conversations.filter { $0.id != Conversation.announcementsID }.flatMap(\.messages)
            .filter { !$0.isMine && $0.sender != "system" }.map(\.text)
    }

    @Test func keysOutOfStepMendAndNothingIsLost() async throws {
        // The timed resend is pushed far off, so only the mending can bring the lost messages back.
        let savedGaps = AppModel.resendGaps
        AppModel.resendGaps = [3600]
        defer { AppModel.resendGaps = savedGaps }
        // A first ask for new keys lost under a busy test relay is asked again in seconds, not the app's two minutes,
        // which is longer than this test waits.
        AppModel.mendWait = 3
        defer { AppModel.mendWait = 120 }
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await until([alice, bob]) { alice.contact(bob.fingerprint)?.devices.first?.session != nil }
        let a = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        let b = bob.startConversation(kind: .direct, title: "", members: [alice.fingerprint])
        alice.send("hello", in: a.id)
        await until([alice, bob]) { received(bob).contains("hello") }
        bob.send("hi", in: b.id)
        await until([alice, bob]) { received(alice).contains("hi") }

        // Bob's phone keeps a copy of its keys, then both talk on (the keys move on), then the old copy comes back.
        let ci = try #require(bob.data.contacts.firstIndex { $0.fingerprint == alice.fingerprint })
        let behind = try #require(bob.data.contacts[ci].devices.first?.session)
        alice.send("one", in: a.id)
        await until([alice, bob]) { received(bob).contains("one") }
        bob.send("two", in: b.id)
        await until([alice, bob]) { received(alice).contains("two") }
        alice.send("three", in: a.id)
        await until([alice, bob]) { received(bob).contains("three") }
        bob.data.contacts[ci].devices[0].session = behind

        // What Alice writes now can't be opened on Bob's side at first.
        alice.send("after 1", in: a.id)
        alice.send("after 2", in: a.id)
        await until([alice, bob], seconds: 60) {
            received(bob).contains("after 1") && received(bob).contains("after 2")
        }
        #expect(received(bob).filter { $0 == "after 1" }.count == 1)
        #expect(received(bob).filter { $0 == "after 2" }.count == 1)
        bob.send("back to normal", in: b.id)
        await until([alice, bob]) { received(alice).contains("back to normal") }
        #expect(received(alice).contains("back to normal"))
        await until([alice, bob]) {
            alice.conversation(a.id)?.messages.filter { $0.isMine }.allSatisfy { $0.status == .delivered || $0.status == .read } == true
        }
        #expect(alice.conversation(a.id)?.messages.filter { $0.isMine }.allSatisfy { $0.status == .delivered || $0.status == .read } == true,
                "every message ticked")
    }

    /// Delivery receipts can't be turned off any more: a phone whose saved settings say "off" (from an older build)
    /// still sends the tick, so the sender stops sending the message again.
    @Test func anOldDeliveryReceiptsOffIsIgnored() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        var saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(bob.data.security)) as! [String: Any]
        saved["deliveryReceipts"] = false
        saved["readReceipts"] = false
        bob.data.security = try JSONDecoder().decode(SecuritySettings.self, from: JSONSerialization.data(withJSONObject: saved))
        #expect(bob.data.security.readReceipts == false, "read receipts are still a choice")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        await until([alice, bob]) { alice.contact(bob.fingerprint)?.devices.first?.session != nil }
        let a = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        alice.send("tick please", in: a.id)
        await until([alice, bob]) { alice.conversation(a.id)?.messages.first { $0.isMine }?.status == .delivered }
        #expect(alice.conversation(a.id)?.messages.first { $0.isMine }?.status == .delivered)
        #expect(received(bob) == ["tick please"])
    }
}
