import Testing
import Foundation
@testable import Pulshade

/// Saved data with one piece this build can't read must still open: the rest is kept and that piece is set aside, sealed
/// in the vault as it was, instead of the whole account staying locked ("Right passcode, but this account's data
/// couldn't be read").
@MainActor struct DataRescueTests {
    private func json(_ data: AppData) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder.pulshade.encode(data)) as? [String: Any])
    }

    private func bytes(_ json: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: json) }

    private func sample() -> AppData {
        var data = AppData()
        data.contacts = [Contact(fingerprint: "a", name: "Ann", signingKey: Data([1]), agreementKey: Data([2]), sendID: Data([3])),
                         Contact(fingerprint: "b", name: "Bob", signingKey: Data([4]), agreementKey: Data([5]), sendID: Data([6]))]
        data.conversations = [Conversation(kind: .direct, title: "", members: ["a"],
                                           messages: [Message(sender: "a", text: "one"), Message(sender: "me", text: "two"),
                                                      Message(sender: "a", text: "three")]),
                              Conversation(kind: .direct, title: "", members: ["b"], messages: [Message(sender: "b", text: "hi")])]
        return data
    }

    @Test func oneUnreadableMessageKeepsTheChatAndEverythingElse() throws {
        var raw = try json(sample())
        var convos = try #require(raw["conversations"] as? [[String: Any]])
        var messages = try #require(convos[0]["messages"] as? [[String: Any]])
        messages[1]["id"] = 12345  // not a UUID: this message can't be read
        convos[0]["messages"] = messages
        raw["conversations"] = convos
        let broken = try bytes(raw)
        #expect(throws: DecodingError.self) { try JSONDecoder.pulshade.decode(AppData.self, from: broken) }

        let opened = try #require(AppData.rescue(broken))
        #expect(opened.conversations.count == 2)
        #expect(opened.conversations[0].messages.map(\.text) == ["one", "three"])
        #expect(opened.conversations[1].messages.map(\.text) == ["hi"])
        #expect(opened.contacts.map(\.name) == ["Ann", "Bob"])
        #expect(opened.setAside?["messages"]?.count == 1)
        #expect(opened.setAsideUnseen == 1)
    }

    @Test func oneUnreadableContactIsSetAsideAndTheOthersStay() throws {
        var raw = try json(sample())
        var contacts = try #require(raw["contacts"] as? [[String: Any]])
        contacts[0]["fingerprint"] = nil  // required: this contact can't be read
        raw["contacts"] = contacts
        let opened = try #require(AppData.rescue(try bytes(raw)))
        #expect(opened.contacts.map(\.name) == ["Bob"])
        #expect(opened.conversations.count == 2)
        #expect(opened.setAside?["contacts"]?.count == 1)
    }

    @Test func anUnreadableSettingFallsBackToItsDefault() throws {
        var data = sample()
        data.theme = "graphite"
        var raw = try json(data)
        raw["security"] = "not settings at all"
        let opened = try #require(AppData.rescue(try bytes(raw)))
        #expect(opened.security == SecuritySettings())
        #expect(opened.theme == "graphite")
        #expect(opened.contacts.count == 2)
        #expect(opened.setAside?["security"]?.count == 1)
    }

    @Test func dataFromANewerBuildIsStillRefused() throws {
        var raw = try json(sample())
        raw["format"] = AppData.currentFormat + 1
        #expect(AppData.rescue(try bytes(raw)) == nil)
    }

    @Test func whatWasSetAsideIsKeptAcrossSavesButNeverInTheBackup() throws {
        var raw = try json(sample())
        var contacts = try #require(raw["contacts"] as? [[String: Any]])
        contacts[1]["signingKey"] = 7
        raw["contacts"] = contacts
        var opened = try #require(AppData.rescue(try bytes(raw)))
        opened.setAsideUnseen = nil  // mentioned once at unlock
        // Saved again, it opens normally and still holds the piece it couldn't read, exactly as it was.
        let again = try JSONDecoder.pulshade.decode(AppData.self, from: JSONEncoder.pulshade.encode(opened))
        #expect(again.setAside == opened.setAside)
        #expect(again.setAsideUnseen == nil)
        let kept = try #require(again.setAside?["contacts"]?.first)
        let original = try #require(try JSONSerialization.jsonObject(with: kept) as? [String: Any])
        #expect(original["name"] as? String == "Bob")
        // A backup leaves it out: it stays on this device only.
        #expect(AppModel.backupContents(of: again).setAside == nil)
    }

    @Test func ordinaryDataNeverGoesThroughTheRescue() throws {
        let opened = try JSONDecoder.pulshade.decode(AppData.self, from: JSONEncoder.pulshade.encode(sample()))
        #expect(opened.setAside == nil && opened.setAsideUnseen == nil)
    }

    @Test func theLockScreenSaysWhyInAFewWords() {
        let newer = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Saved by a newer version of PULSHADE"))
        #expect(AppModel.unreadableReason(newer).contains("newer version"))
        let other = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        #expect(AppModel.unreadableReason(other).contains("shape"))
        #expect(AppModel.unreadableReason(CocoaError(.fileReadNoPermission)) == "The file couldn't be read.")
    }
}
