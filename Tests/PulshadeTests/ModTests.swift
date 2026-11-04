import Testing
import Foundation
@testable import Pulshade

/// The mod role in groups: who it may remove, and that it survives saving.
struct ModTests {
    private func group() -> Conversation {
        var c = Conversation(kind: .group, title: "Crew", members: ["admin", "mod", "mod2", "plain"])
        c.owner = "owner"
        c.admins = ["admin"]
        c.mods = ["mod", "mod2"]
        return c
    }

    @Test func modsOnlyRemoveOrdinaryMembers() {
        let c = group()
        #expect(c.canRemove("plain", by: "mod"))
        #expect(!c.canRemove("admin", by: "mod"))
        #expect(!c.canRemove("owner", by: "mod"))
        #expect(!c.canRemove("mod2", by: "mod"), "A mod can't remove another mod")
        #expect(!c.canRemove("mod", by: "mod"))
        #expect(!c.canRemove("plain", by: "plain"), "An ordinary member removes no one")
    }

    @Test func adminsAndOwnerKeepTheirPowerOverMods() {
        let c = group()
        #expect(c.canRemove("mod", by: "admin"))
        #expect(!c.canRemove("owner", by: "admin"))
        #expect(!c.canRemove("owner", by: "owner"))
        #expect(c.canRemove("admin", by: "owner") && c.canRemove("mod", by: "owner"))
    }

    @Test func modsPostWhenOnlyAdminsCanButNotWhenOwnerOnly() {
        var c = group()
        c.postPolicy = .admins
        #expect(c.canPost("mod") && c.canPost("admin") && !c.canPost("plain"))
        c.postPolicy = .owner
        #expect(!c.canPost("mod"))
    }

    @Test func modsAreOnlyForGroups() {
        var channel = Conversation(kind: .channel, title: "Drops", members: ["mod", "plain"])
        channel.owner = "owner"
        channel.mods = ["mod"]
        #expect(!channel.canRemove("plain", by: "mod"))
    }

    @Test func modsSurviveSavingAndOldSavesHaveNone() throws {
        let c = group()
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
        #expect(back.mods == ["mod", "mod2"])
        var plain = group()
        plain.mods = []
        let json = try JSONEncoder().encode(plain)
        #expect(!String(decoding: json, as: UTF8.self).contains("\"mods\""))
        #expect(try JSONDecoder().decode(Conversation.self, from: json).mods.isEmpty)
    }
}
