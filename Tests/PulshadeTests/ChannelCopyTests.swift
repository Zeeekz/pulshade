import Foundation
import Testing
@testable import Pulshade

/// A channel's posts can be copied and forwarded unless the channel protects them, whatever your own chats are set to.
@MainActor
struct ChannelCopyTests {
    @Test func channelPostsFollowTheChannelsSwitchNotTheAccounts() {
        let model = AppModel.demo()
        model.data.security.allowForwarding = false
        var channel = Conversation(kind: .channel, title: "Drops", members: [])
        let group = Conversation(kind: .group, title: "Night Owls", members: [])
        #expect(model.noForwardFlag(for: channel) == nil, "a channel's posts can be copied by default")
        #expect(model.noForwardFlag(for: group) == true, "a group follows the account's setting")
        channel.protectPosts = true
        #expect(model.noForwardFlag(for: channel) == true)
        model.data.security.allowForwarding = true
        #expect(model.noForwardFlag(for: group) == nil)
    }

    @Test func theSwitchIsKeptAndOnlyWrittenWhenOn() throws {
        var channel = Conversation(kind: .channel, title: "Drops", members: [])
        #expect(!String(decoding: try JSONEncoder().encode(channel), as: UTF8.self).contains("protectPosts"))
        channel.protectPosts = true
        let back = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(channel))
        #expect(back.protectPosts == true)
    }
}
