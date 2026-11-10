import Testing
import Foundation
@testable import Pulshade

/// What's on screen is always the identity that sends: a chat of one persona is never shown while another is in use,
/// and opening one from outside (a notification, the menu bar) switches to its persona first.
@MainActor
struct PersonaChatTests {
    private func makeUser() async throws -> AppModel {
        let model = testModel("pulshade-persona-chat")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        return model
    }

    @Test func aChatOnlyShowsUnderItsOwnPersona() async throws {
        let model = try await makeUser()
        defer { model.lock() }
        let mainChat = model.startConversation(kind: .broadcast, title: "Main list", members: [])
        let other = try #require(model.createPersona(name: "Other"))
        #expect(model.belongsHere(mainChat))

        // The bug: a main-account chat open, then a switch to another persona.
        model.switchPersona(other.id)
        #expect(!model.belongsHere(try #require(model.conversation(mainChat.id))), "hidden while the other persona is in use")

        // Opening it from outside switches back to the persona it belongs to.
        model.becomeOwner(of: mainChat.id)
        #expect(model.activePersona == nil)
        #expect(model.belongsHere(try #require(model.conversation(mainChat.id))))
    }

    @Test func burnerChatsAndAnnouncementsShowUnderEveryPersona() async throws {
        let model = try await makeUser()
        defer { model.lock() }
        let burner = model.createBurner(lasting: 3600)
        let burnerChat = model.startConversation(kind: .broadcast, title: "Burner list", members: [], persona: .some(burner))
        #expect(model.activePersona == nil)
        #expect(model.belongsHere(burnerChat), "burners' chats are listed everywhere, with their own name and timer")
        model.becomeOwner(of: burnerChat.id)
        #expect(model.activePersona == nil, "opening one doesn't switch away")
    }
}
