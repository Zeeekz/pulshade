import Testing
import Foundation
@testable import Pulshade

/// Two people who add each other at the same moment (each scans the other's code) must end up able to talk both ways.
/// Found by the delivery counter (CanaryTests): their first hellos cross and mail is lost for good.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct CrossedHelloTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        // No sealed backups: the relay takes only so many an hour from one address, and the backup tests need them.
        model.data.security.keepBackup = false
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 8) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    private func until(_ models: [AppModel], seconds: Double = 30, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func dump(_ m: AppModel, _ other: AppModel, _ label: String) {
        let c = m.contact(other.fingerprint)
        let devs = c?.devices.map { d in
            "id=\(d.id.hex.prefix(6)) send=\(d.sendID.hex.prefix(6)) session=\(d.session != nil) canSend=\(d.session?.canSend == true) hs=\(d.handshake != nil) pending=\(d.pending.count)"
        } ?? []
        let mine = c.flatMap { $0.receiveKey }.map { Mailbox.sendID(for: $0).hex.prefix(6) } ?? "-"
        print("DUMP \(label) reads=\(mine) invites=\(m.data.invites.map { Mailbox.sendID(for: $0.receiveKey).hex.prefix(6) }) devices=\(devs) outbox=\(m.data.outbox.count) unreadable=\(m.unreadable.count)")
    }

    private func texts(_ m: AppModel, from other: AppModel) -> [String] {
        m.data.conversations.filter { $0.id != Conversation.announcementsID }.flatMap { $0.messages }.filter { $0.sender != "me" && $0.text.hasPrefix("t ") }.map(\.text)
    }

    @Test(arguments: [false, true])
    func addingEachOtherAtOnceStillWorksBothWays(sendStraightAway: Bool) async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let codeA = alice.makeInviteCode(), codeB = bob.makeInviteCode()
        _ = try #require(alice.addContact(code: codeB, nickname: ""))
        _ = try #require(bob.addContact(code: codeA, nickname: ""))
        if !sendStraightAway { await settle(alice, bob) }

        let a = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        let b = bob.startConversation(kind: .direct, title: "", members: [alice.fingerprint])
        alice.send("t a1", in: a.id)
        bob.send("t b1", in: b.id)
        await until([alice, bob]) { texts(bob, from: alice).contains("t a1") && texts(alice, from: bob).contains("t b1") }
        alice.send("t a2", in: a.id)
        bob.send("t b2", in: b.id)
        await until([alice, bob]) { texts(bob, from: alice).count == 2 && texts(alice, from: bob).count == 2 }

        #expect(texts(bob, from: alice).sorted() == ["t a1", "t a2"])
        #expect(texts(alice, from: bob).sorted() == ["t b1", "t b2"])
    }

    /// The same, with one side reading everything (both hellos and the answer) before the other reads anything.
    @Test(arguments: [0, 1])
    func addingEachOtherAtOnceWhicheverSideReadsFirst(first: Int) async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        let codeA = alice.makeInviteCode(), codeB = bob.makeInviteCode()
        _ = try #require(alice.addContact(code: codeB, nickname: ""))
        _ = try #require(bob.addContact(code: codeA, nickname: ""))
        final class Trace: @unchecked Sendable { var lines: [String] = [] }
        let trace = Trace()
        for (name, m) in [("alice", alice), ("bob", bob)] {
            m.envelopeTap = { e in trace.lines.append("\(name) got box=\(Mailbox.sendID(for: e.receiveKey).hex.prefix(6)) v=\(e.blob.first ?? 0) len=\(e.blob.count)") }
            m.receiveResultTap = { r in trace.lines.append("\(name)   -> \(r)") }
        }
        let (early, late) = first == 0 ? (alice, bob) : (bob, alice)
        for _ in 0..<4 { await early.syncOnce() }
        await late.syncOnce()
        for _ in 0..<4 { await early.syncOnce() }
        await settle(alice, bob)
        let a = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        let b = bob.startConversation(kind: .direct, title: "", members: [alice.fingerprint])
        alice.send("t a1", in: a.id)
        bob.send("t b1", in: b.id)
        await until([alice, bob]) {
            alice.conversation(a.id)?.messages.last { $0.sender == "me" }?.status == .delivered
                && bob.conversation(b.id)?.messages.last { $0.sender == "me" }?.status == .delivered
        }
        if texts(bob, from: alice) != ["t a1"] || texts(alice, from: bob) != ["t b1"] {
            dump(alice, bob, "alice(first=\(first))"); dump(bob, alice, "bob(first=\(first))")
            print("DUMP wins: alice<bob \(alice.fingerprint < bob.fingerprint)")
            for line in trace.lines { print("DUMP trace \(line)") }
        }
        #expect(texts(bob, from: alice) == ["t a1"])
        #expect(texts(alice, from: bob) == ["t b1"])
        #expect(alice.conversation(a.id)?.messages.last { $0.sender == "me" }?.status == .delivered)
        #expect(bob.conversation(b.id)?.messages.last { $0.sender == "me" }?.status == .delivered)
    }

    @Test func oneSidedAddWithMessagesStraightAway() async throws {
        let alice = try await makeUser("Alice")
        let bob = try await makeUser("Bob")
        defer { for m in [alice, bob] { m.lock() } }
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        let b = bob.startConversation(kind: .direct, title: "", members: [alice.fingerprint])
        bob.send("t b1", in: b.id)
        await settle(alice, bob)
        let a = alice.startConversation(kind: .direct, title: "", members: [bob.fingerprint])
        alice.send("t a1", in: a.id)
        await settle(alice, bob)
        #expect(texts(alice, from: bob) == ["t b1"])
        #expect(texts(bob, from: alice) == ["t a1"])
    }
}
