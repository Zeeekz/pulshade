import Testing
import Foundation
@testable import Pulshade

/// Posts in a group that shares one mailbox that must not get lost: posted again if the mailbox never gives them back,
/// asked for again by a member who was away longer than the relay keeps mail, and kept no longer than their message.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct GroupDeliveryTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-delivery")
        model.sharedGroupsEnabled = true
        try await model.create(identity: .generate(), profile: Profile(name: name), passcode: "test-passcode")
        return model
    }

    private func settle(_ models: AppModel..., rounds: Int = 6) async {
        for _ in 0..<rounds { for m in models { await m.syncOnce() } }
    }

    private func until(_ models: [AppModel], seconds: Double = 20, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end {
            for m in models { await m.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Alice, Bob and Cara in one shared group.
    private func group() async throws -> (AppModel, AppModel, AppModel, UUID) {
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        _ = try #require(bob.addContact(code: alice.makeInviteCode(), nickname: ""))
        _ = try #require(cara.addContact(code: alice.makeInviteCode(), nickname: ""))
        await settle(alice, bob, cara)
        let bobFP = try #require(alice.visibleContacts.first { $0.name == "Bob" }).fingerprint
        let caraFP = try #require(alice.visibleContacts.first { $0.name == "Cara" }).fingerprint
        for fp in [bobFP, caraFP] {
            let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
            alice.send("hi", in: chat.id)
        }
        await settle(alice, bob, cara)
        for m in [bob, cara] {
            if let chat = m.data.conversations.first(where: { $0.kind == .direct }) { m.send("hey", in: chat.id) }
        }
        await settle(alice, bob, cara)
        let made = alice.startConversation(kind: .group, title: "Night owls", members: [bobFP, caraFP])
        await until([alice, bob, cara]) {
            bob.conversation(made.id)?.shared?.joining == false && cara.conversation(made.id)?.shared?.joining == false
                && alice.conversation(made.id)?.members.count == 2
        }
        return (alice, bob, cara, made.id)
    }

    @Test func newEpochsKeepMailForThreeDays() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        #expect(alice.conversation(id)?.shared?.current?.days == 3)
        #expect(bob.conversation(id)?.shared?.current?.days == 3)
    }

    @Test func aPostTheMailboxNeverGaveBackIsPostedAgainAndNobodySeesItTwice() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.send("is anyone there", in: id)
        await until([alice, bob, cara]) {
            cara.conversation(id)?.messages.contains { $0.text == "is anyone there" } == true
                && bob.conversation(id)?.shared?.kept?.contains { $0.seen } == true
        }
        let before = try #require(bob.conversation(id)?.shared?.kept?.first { $0.chat })
        #expect(before.seen, "read back from the mailbox, so nothing to post again")
        #expect(before.tries == 0)

        // The relay lost it: as if it never came back, long enough ago, and the mailbox has been read since.
        var shared = try #require(bob.conversation(id)?.shared)
        let j = try #require(shared.kept?.firstIndex { $0.id == before.id })
        shared.kept?[j].seen = false
        shared.kept?[j].lastTry = Date().addingTimeInterval(-3600)
        bob.data.conversations[try #require(bob.data.conversations.firstIndex { $0.id == id })].shared = shared
        await until([alice, bob, cara]) { bob.conversation(id)?.shared?.kept?.first { $0.id == before.id }?.tries == 1 }
        let after = try #require(bob.conversation(id)?.shared?.kept?.first { $0.id == before.id })
        #expect(after.tries == 1, "posted again once")
        #expect(after.blob == before.blob, "the very same sealed bytes, so no key is used twice")
        await settle(alice, bob, cara)
        #expect(after.index == before.index)
        #expect(cara.conversation(id)?.messages.filter { $0.text == "is anyone there" }.count == 1, "a copy someone already has is ignored")
        #expect(alice.conversation(id)?.messages.filter { $0.text == "is anyone there" }.count == 1)
    }

    @Test func aMemberWhoWasAwayLongerThanTheRelayKeepsMailGetsWhatTheyMissed() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        // Cara is away. Bob says something, and by the time Cara is back the relay would have let it go: her place in the
        // mailbox is after it, and she last read it five days ago.
        bob.send("while you were gone", in: id)
        await until([bob]) { bob.conversation(id)?.shared?.kept?.contains { $0.chat && $0.seen } == true }
        let epoch = try #require(bob.conversation(id)?.shared?.current?.number)
        let at = try #require(bob.conversation(id)?.shared?.cursors[String(epoch)])
        let c = try #require(cara.data.conversations.firstIndex { $0.id == id })
        cara.data.conversations[c].shared?.cursors[String(epoch)] = at
        cara.data.conversations[c].shared?.lastFetch = Date().addingTimeInterval(-5 * 86_400)
        #expect(cara.conversation(id)?.messages.contains { $0.text == "while you were gone" } != true)

        await until([alice, bob, cara]) { cara.conversation(id)?.messages.contains { $0.text == "while you were gone" } == true }
        #expect(cara.conversation(id)?.messages.filter { $0.text == "while you were gone" }.count == 1,
                "she asked, Bob's phone posted it again, and she has it")
        #expect(cara.conversation(id)?.shared?.catchUpSince == nil)
    }

    /// A relay of the test's own that can be killed and brought back with nothing on its disk (a lost disk or mailbox).
    private final class ThrowawayRelay {
        let port: Int
        let directory: URL
        private var process: Process?

        init(port: Int) throws {
            self.port = port
            directory = FileManager.default.temporaryDirectory.appending(path: "pulshade-relayloss-\(UUID().uuidString)")
            try start()
        }

        var url: String { "http://127.0.0.1:\(port)" }

        func start() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Tests/PulshadeTests/GroupDeliveryTests.swift -> the package root.
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let run = Process()
            run.executableURL = root.appending(path: "relay/target/release/pulshade-relay")
            run.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["PULSHADE_ONION"] = "0"
            env["PULSHADE_STORAGE_KEY"] = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            env["PULSHADE_BIND"] = "127.0.0.1:\(port)"
            env["PULSHADE_DIRECTORY"] = directory.appending(path: "directory.json").path
            run.environment = env
            run.standardOutput = FileHandle.nullDevice
            run.standardError = FileHandle.nullDevice
            try run.run()
            process = run
            let end = Date().addingTimeInterval(10)
            while Date() < end {
                if (try? Data(contentsOf: URL(string: "\(url)/v1/health")!)) != nil { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        /// Kills it and throws away everything it held.
        func loseEverything() {
            if let process { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            process = nil
            try? FileManager.default.removeItem(at: directory)
        }

        func stop() { loseEverything() }
    }

    /// Points the whole process at a relay of its own for a while, so it must not run beside other suites: scripts/test.sh
    /// runs it on its own at the end (PULSHADE_RELAY_LOSS=1).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_LOSS"] == "1"))
    func aPostTheRelayLostBeforeItCameBackGoesUpAgainOnARealRelay() async throws {
        let relay = try ThrowawayRelay(port: 7894)
        let previous = ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"]
        setenv("PULSHADE_TEST_RELAY", relay.url, 1)
        defer {
            relay.stop()
            if let previous { setenv("PULSHADE_TEST_RELAY", previous, 1) } else { unsetenv("PULSHADE_TEST_RELAY") }
        }
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let b = try #require(bob.data.conversations.firstIndex { $0.id == id })

        // Bob's post reaches the relay (his outbox empties) but he hasn't read it back when the relay loses everything.
        bob.send("this one gets lost", in: id)
        let end = Date().addingTimeInterval(10)
        while Date() < end, bob.data.conversations[b].shared?.kept?.contains(where: { $0.chat }) != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        let kept = try #require(bob.data.conversations[b].shared?.kept?.first { $0.chat })
        #expect(!kept.seen, "not read back yet")
        relay.loseEverything()
        try relay.start()
        // Long enough ago that it's due, as it would be a couple of minutes on.
        bob.data.conversations[b].shared?.kept?[0].lastTry = Date().addingTimeInterval(-3600)

        await until([alice, bob, cara], seconds: 30) {
            cara.conversation(id)?.messages.contains { $0.text == "this one gets lost" } == true
        }
        #expect(cara.conversation(id)?.messages.filter { $0.text == "this one gets lost" }.count == 1,
                "the relay lost it, Bob's phone posted the same bytes again, and Cara has it once")
        await settle(alice, bob, cara)
        #expect(alice.conversation(id)?.messages.contains { $0.text == "this one gets lost" } == true)
        #expect((bob.data.conversations[b].shared?.kept?.first { $0.id == kept.id }?.tries ?? 0) >= 1)
    }

    @Test func detachingWipesWhatWasKeptToPostAgain() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.send("keep me", in: id)
        await until([alice, bob, cara]) { bob.conversation(id)?.shared?.kept?.isEmpty == false }
        #expect(bob.conversation(id)?.shared?.kept?.isEmpty == false)
        let wiped = AppModel.withoutChats(bob.data, keepingDevices: true)
        let shared = try #require(wiped.conversations.first { $0.id == id }?.shared)
        #expect(shared.kept == nil && shared.lastFetch == nil && shared.catchUpSince == nil && shared.catchUpAsked == nil,
                "nothing sealed is left to be posted again after a Detach")
    }

    @Test func aCatchUpRequestDoesNotGiveAwayWhenThePhoneLastRead() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        // Cara last read five days ago and a catch-up is due: what she posts names the start of a day, a day or more before.
        let c = try #require(cara.data.conversations.firstIndex { $0.id == id })
        let last = Date().addingTimeInterval(-5 * 86_400 - 3 * 3_600 - 17 * 60)
        cara.data.conversations[c].shared?.catchUpSince = last
        await settle(cara, rounds: 2)
        let asked = try #require(cara.data.conversations[c].shared?.catchUpAsked)
        #expect(asked.timeIntervalSinceNow > -60)
        #expect(cara.data.conversations[c].shared?.catchUpSince == nil)
    }

    @Test func aKeptPostGoesWithItsMessage() async throws {
        let (alice, bob, cara, id) = try await group()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.send("oops", in: id)
        await until([alice, bob, cara]) { cara.conversation(id)?.messages.contains { $0.text == "oops" } == true }
        let mine = try #require(bob.conversation(id)?.messages.last { $0.text == "oops" })
        #expect(bob.conversation(id)?.shared?.kept?.contains { $0.about == mine.id } == true)
        bob.unsend(mine.id, in: id)
        await settle(alice, bob, cara)
        #expect(bob.conversation(id)?.shared?.kept?.contains { $0.about == mine.id } != true, "an unsent message isn't kept to be posted again")
    }
}
