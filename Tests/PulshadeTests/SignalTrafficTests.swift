import Testing
import Foundation
@testable import Pulshade

/// What keeps a mailbox nobody reads from filling up: signals that the relay lets go of or replaces, key requests that
/// replace each other, and devices that have gone quiet left out of sending.
@MainActor
@Suite(.serialized) struct SignalTrafficTests {
    private func makeModel() async throws -> AppModel {
        let model = testModel("pulshade-signals")
        try await model.create(identity: .generate(), profile: Profile(name: "Me"), passcode: "test-passcode")
        return model
    }

    /// A contact with two devices, neither with keys yet, and a chat with them.
    private func seed(_ model: AppModel) -> (contact: Contact, chat: Conversation) {
        let them = Identity.generate()
        var contact = Contact(fingerprint: them.fingerprint, name: "Them", signingKey: them.card.signing,
                              agreementKey: them.card.agreement, sendID: Mailbox.make().sendID, device: Data([1]))
        contact.devices.append(DeviceLink(id: Data([2]), sendID: Mailbox.make().sendID))
        contact.pq = them.pq.pin
        let chat = Conversation(kind: .direct, title: "Them", members: [them.fingerprint])
        model.data.contacts = [contact]
        model.data.conversations = [chat]
        model.data.security.typingIndicators = true
        return (contact, chat)
    }

    @Test func aDeviceSilentForAMonthIsLeftOutWhileAnotherStillTalks() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        _ = seed(model)
        let old = Date().addingTimeInterval(-AppModel.dormantAfter - 3600)
        model.data.contacts[0].devices[0].lastHeard = Date()
        model.data.contacts[0].devices[1].lastHeard = old
        #expect(!model.isDormant(contact: 0, device: 0))
        #expect(model.isDormant(contact: 0, device: 1))

        model.noteTyping(in: model.data.conversations[0].id)
        #expect(!model.data.contacts[0].devices[0].pending.isEmpty)
        #expect(model.data.contacts[0].devices[1].pending.isEmpty, "nothing is queued for a device that's gone quiet")
        #expect(model.data.contacts[0].devices[1].handshake == nil, "and it isn't asked for keys")

        // A contact's only device is never left out, however long it has been away.
        model.data.contacts[0].devices[0].lastHeard = old.addingTimeInterval(-60)
        #expect(!model.isDormant(contact: 0, device: 1))
        model.data.contacts[0].devices.removeFirst()
        #expect(!model.isDormant(contact: 0, device: 0))
    }

    @Test func onlyTheNewestSignalWaitsForADeviceWithoutKeys() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        let (contact, _) = seed(model)
        // Typing in two chats with the same person gets past the per-chat throttle.
        let other = Conversation(kind: .direct, title: "Other chat", members: [contact.fingerprint])
        model.data.conversations.append(other)
        model.noteTyping(in: model.data.conversations[0].id)
        model.noteTyping(in: other.id)
        let signals = model.data.contacts[0].devices[0].pending.filter { $0.payload.isEphemeral }
        #expect(signals.count == 1)
    }

    @Test func aKeyRequestReplacesTheLastOneOnTheRelay() async throws {
        let model = try await makeModel()
        defer { model.lock() }
        _ = seed(model)
        model.noteTyping(in: model.data.conversations[0].id)
        let asks = model.data.outbox.filter { $0.collapse != nil }
        #expect(asks.count == 2, "one key request per device, each tagged")
        #expect(asks.allSatisfy { $0.collapse?.count == 16 && $0.life == nil }, "a key request isn't short-lived")
        #expect(Set(asks.compactMap(\.collapse)).count == 2, "each mailbox has its own tag")
    }

    @Test func tagsAreStablePerKindAndMailboxWithinAWindowAndMoveOnAfterIt() {
        let box = Data.random(32), other = Data.random(32), device = Data([7])
        let start = Date(timeIntervalSince1970: 1_800_000_000 - 1_800_000_000.truncatingRemainder(dividingBy: AppModel.collapseWindow))
        let soon = start.addingTimeInterval(AppModel.collapseWindow - 1), later = start.addingTimeInterval(AppModel.collapseWindow)
        func tag(_ kind: String = "hello", _ mailbox: Data? = nil, _ from: Data? = nil, at: Date? = nil) -> Data {
            AppModel.collapseTag(kind, sendID: mailbox ?? box, from: from ?? device, at: at ?? start)
        }
        #expect(tag() == tag(at: soon), "the same sender replaces its older copy within a window")
        #expect(tag() != tag(at: later), "the relay can't follow one sender device across windows")
        #expect(tag() != tag("presence"))
        #expect(tag() != tag("hello", other))
        #expect(tag() != tag("hello", nil, Data([8])))
        #expect(Payload.typing(conversation: UUID()).collapseKind == "typing")
        #expect(Payload.presence(online: true).collapseKind == "presence")
    }
}

/// The relay's half: a tagged deposit replaces the last one, and a short-lived one lapses. Needs a throwaway relay
/// (scripts/test.sh starts one).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct SignalRelayTests {
    @Test func theRelayKeepsOneTaggedCopyAndLetsSignalsLapse() async throws {
        let relay = RelayClient(base: try #require(URL(string: ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"] ?? "http://127.0.0.1:7890")),
                                lane: "signal-test")
        // Another test locking an app at the same moment drops every connection in the process, which cancels a
        // request under way. Then the whole thing goes again on a new mailbox (a cancelled deposit may or may not have
        // landed); anything the relay itself answers counts as it is.
        func run() async throws -> (first: [String], later: [String]) {
            let mailbox = Mailbox.make()
            let tag = AppModel.collapseTag("hello", sendID: mailbox.sendID, from: Data([1]))
            for n in 1...3 { try await relay.deposit(Data("ask \(n)".utf8), to: mailbox.sendID, collapse: tag) }
            try await relay.deposit(Data("typing".utf8), to: mailbox.sendID, life: 1)
            try await relay.deposit(Data("message".utf8), to: mailbox.sendID, wake: true)
            let first = try await relay.fetch([mailbox.receiveKey]).map { String(decoding: $0.blob, as: UTF8.self) }
            try await Task.sleep(for: .milliseconds(1200))
            let later = try await relay.fetch([mailbox.receiveKey]).map { String(decoding: $0.blob, as: UTF8.self) }
            return (first, later)
        }
        var result: (first: [String], later: [String])?
        for _ in 0..<3 where result == nil {
            do { result = try await run() } catch let error as URLError where error.code == .cancelled { continue }
        }
        let seen = try #require(result, "every try was cut off")
        #expect(seen.first == ["ask 3", "typing", "message"])
        #expect(seen.later == ["ask 3", "message"])
    }
}
