import Testing
import Foundation
@testable import Pulshade

/// A follower leaving a channel from inside it, and a follower who missed a new key asking for it again, end to end
/// through a real relay (see scripts/test.sh). Both go over the follower's own chat with the staff member who invited
/// them: that phone is the only one that knows which roster entry the account is.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_RELAY_TEST"] == "1"), .serialized)
struct ChannelLeaveAndKeyTests {
    private func makeUser(_ name: String) async throws -> AppModel {
        let model = testModel("pulshade-channel")
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

    /// Alice knows each of the others and has a chat with them that works both ways; the others don't know each other.
    private func people(_ names: [String]) async throws -> (AppModel, [AppModel], [String]) {
        let alice = try await makeUser("Alice")
        var others: [AppModel] = []
        for name in names {
            let user = try await makeUser(name)
            _ = try #require(user.addContact(code: alice.makeInviteCode(), nickname: ""))
            others.append(user)
        }
        for _ in 0..<6 { for m in [alice] + others { await m.syncOnce() } }
        var fingerprints: [String] = []
        for name in names {
            let fp = try #require(alice.visibleContacts.first { $0.name == name }).fingerprint
            fingerprints.append(fp)
            let chat = alice.startConversation(kind: .direct, title: "", members: [fp])
            alice.send("hi", in: chat.id)
        }
        for _ in 0..<6 { for m in [alice] + others { await m.syncOnce() } }
        for m in others {
            if let chat = m.data.conversations.first(where: { $0.kind == .direct }) { m.send("hey", in: chat.id) }
        }
        for _ in 0..<6 { for m in [alice] + others { await m.syncOnce() } }
        return (alice, others, fingerprints)
    }

    private func shared(_ model: AppModel, _ id: UUID) -> SharedGroup? { model.conversation(id)?.shared }

    private func aliceContact(on model: AppModel) throws -> Contact {
        try #require(model.data.contacts.first { $0.name == "Alice" && !$0.hidden })
    }

    /// Alice's channel with Bob and Cara following, everyone caught up.
    private func channelWithTwoFollowers(allThree: Bool = false) async throws -> (alice: AppModel, bob: AppModel, cara: AppModel, dave: AppModel, bobFP: String, channel: UUID) {
        AppModel.leaveRekeyWindow = 0
        AppModel.rekeyRetry = 30
        AppModel.channelAdmitsPerHour = 60
        let (alice, others, fps) = try await people(["Bob", "Cara", "Dave"])
        let (bob, cara, dave) = (others[0], others[1], others[2])
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: allThree ? fps : [fps[0], fps[1]])
        let followers = allThree ? 3 : 2
        await until([alice, bob, cara, dave]) {
            bob.conversation(channel.id)?.shared != nil && cara.conversation(channel.id)?.shared != nil
                && (!allThree || dave.conversation(channel.id)?.shared != nil)
                && alice.conversation(channel.id)?.shared?.roster?.live.count == followers
        }
        alice.send("first", in: channel.id)
        await until([alice, bob, cara, dave]) {
            bob.conversation(channel.id)?.messages.last?.text == "first" && cara.conversation(channel.id)?.messages.last?.text == "first"
                && (!allThree || dave.conversation(channel.id)?.messages.last?.text == "first")
        }
        return (alice, bob, cara, dave, fps[0], channel.id)
    }

    // MARK: Leaving

    @Test func aFollowerLeavingIsTakenOutAndOnlyThey() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let stashed = try #require(bob.conversation(id))

        bob.delete(id)
        #expect(bob.conversation(id) == nil, "gone from his device at once")
        await until([alice, bob, cara]) { shared(alice, id)?.settings.epoch == epoch + 1 }
        #expect(shared(alice, id)?.settings.epoch == epoch + 1, "a new key he doesn't get")
        #expect(shared(alice, id)?.roster?.live.count == 1, "and only Cara is left in the roster")

        alice.send("after", in: id)
        await until([alice, bob, cara]) { cara.conversation(id)?.messages.last?.text == "after" }
        #expect(cara.conversation(id)?.messages.last?.text == "after", "the others keep reading")
        #expect(shared(cara, id)?.settings.epoch == epoch + 1)

        // A copy of the channel left on his phone could not read it: the new key was never sealed to him.
        bob.data.conversations.append(stashed)
        await settle(alice, bob, cara)
        #expect(bob.conversation(id)?.messages.map(\.text) == ["first"])
        #expect(shared(bob, id)?.epochs.map(\.number) == [epoch])
    }

    @Test func aLeaveNoticeSaidTwiceOrLateStartsNothingNew() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let toAlice = try aliceContact(on: bob)
        bob.delete(id)
        await until([alice, bob, cara]) { shared(alice, id)?.settings.epoch == epoch + 1 }
        #expect(shared(alice, id)?.settings.epoch == epoch + 1)

        for _ in 0..<3 { bob.sendForTests(.channelLeave(group: id), to: toAlice) }
        await settle(alice, bob, cara)
        #expect(shared(alice, id)?.settings.epoch == epoch + 1, "no entry any more, so nothing to do and no extra rekey")
        #expect(shared(alice, id)?.roster?.live.count == 1)
    }

    @Test func theNoticeWaitsWhenTheInvitersPhoneIsAwayAndTheFollowerStillLeaves() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        bob.delete(id)
        #expect(bob.conversation(id) == nil, "he is out on his own phone without waiting for anyone")
        await settle(bob, rounds: 3)
        #expect(shared(alice, id)?.roster?.live.count == 2, "Alice's phone has heard nothing yet")
        await until([alice, bob, cara]) { shared(alice, id)?.settings.epoch == epoch + 1 }
        #expect(shared(alice, id)?.roster?.live.count == 1, "the notice is delivered when the chat can")
    }

    @Test func aLeaveFromSomeoneWhoDoesNotFollowThatChannelChangesNothing() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        // A second channel with only Cara in it.
        let other = alice.startConversation(kind: .channel, title: "Other", members: [alice.visibleContacts.first { $0.name == "Cara" }!.fingerprint])
        await until([alice, cara]) { shared(cara, other.id) != nil && shared(alice, other.id)?.roster?.live.count == 1 }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let otherEpoch = try #require(shared(alice, other.id)?.settings.epoch)

        // Dave is Alice's contact but follows nothing; Bob follows the first channel but not the second.
        dave.sendForTests(.channelLeave(group: id), to: try aliceContact(on: dave))
        dave.sendForTests(.channelLeave(group: other.id), to: try aliceContact(on: dave))
        bob.sendForTests(.channelLeave(group: other.id), to: try aliceContact(on: bob))
        await settle(alice, bob, cara, dave)
        #expect(shared(alice, id)?.settings.epoch == epoch)
        #expect(shared(alice, id)?.roster?.live.count == 2)
        #expect(shared(alice, other.id)?.settings.epoch == otherEpoch)
        #expect(shared(alice, other.id)?.roster?.live.count == 1)
        #expect(bob.conversation(id) != nil, "and Bob's own channel is untouched")
    }

    @Test func aPhoneThatIsNotStaffIgnoresALeaveNotice() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        // Cara's phone is sent a notice, as if from Alice's account; she is no admin and holds no roster.
        cara.receiveForTests(.channelLeave(group: id), from: try aliceContact(on: cara))
        cara.receiveForTests(.channelKeyWanted(group: id, epoch: 0), from: try aliceContact(on: cara))
        await settle(alice, bob, cara)
        #expect(shared(alice, id)?.settings.epoch == epoch)
        #expect(shared(cara, id)?.settings.epoch == epoch)
        #expect(shared(cara, id)?.roster == nil)
        #expect(cara.channelKeyAnswered.isEmpty)
    }

    // MARK: A key that was missed

    /// The channel moves to a new epoch whose key never reaches Bob (as if he had been away): Alice's roster is held back
    /// from Bob's entry while the key is made, then put back.
    private func rekeyWithoutBob(_ alice: AppModel, _ id: UUID, bobKey: Data) throws {
        let a = try #require(alice.data.conversations.firstIndex { $0.id == id })
        let full = try #require(alice.data.conversations[a].shared?.roster)
        var without = full
        without.entries.removeAll { $0.card.signingKey == bobKey }
        alice.data.conversations[a].shared?.roster = without
        alice.startNewEpoch(id)
        alice.data.conversations[a].shared?.roster = full
    }

    private func bobsKey(_ alice: AppModel, _ id: UUID, _ bobFP: String) throws -> Data {
        let held = try #require(alice.conversation(id)?.shared)
        let known = try #require(held.knownAs[bobFP])
        return try #require(held.roster?.live.first { Identity.fingerprint(of: $0.signingKey) == known }).signingKey
    }

    private func aliceKnows(_ alice: AppModel, _ name: String) throws -> String {
        try #require(alice.visibleContacts.first { $0.name == name }).fingerprint
    }

    @Test func aFollowerWhoMissedTheKeyAsksAndReadsAgain() async throws {
        let (alice, bob, cara, dave, bobFP, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        alice.send("two", in: id)
        await until([alice, bob, cara]) { cara.conversation(id)?.messages.last?.text == "two" && shared(bob, id)?.missedKey == true }
        #expect(shared(bob, id)?.missedKey == true, "he saw the move and has no key for it")
        #expect(bob.conversation(id)?.messages.last?.text == "first")
        #expect(bob.canAskForKey(try #require(bob.conversation(id))))

        bob.askForKeyAgain(id)
        #expect(shared(bob, id)?.keyAskedAt != nil)
        #expect(bob.canAskForKey(try #require(bob.conversation(id))) == false, "not again straight away")
        await until([alice, bob, cara]) { bob.conversation(id)?.messages.last?.text == "two" }
        #expect(shared(bob, id)?.missedKey == false)
        #expect(shared(bob, id)?.settings.epoch == epoch + 1)
        #expect(bob.conversation(id)?.messages.last?.text == "two", "he reads what was posted in the new epoch")

        alice.send("three", in: id)
        await until([alice, bob, cara]) { bob.conversation(id)?.messages.last?.text == "three" }
        #expect(bob.conversation(id)?.messages.last?.text == "three")
        #expect(cara.conversation(id)?.messages.last?.text == "three")
    }

    @Test func aFloodOfAsksIsAnsweredOnce() async throws {
        let (alice, bob, cara, dave, bobFP, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        await until([alice, bob, cara]) { shared(bob, id)?.missedKey == true }
        let epoch = try #require(shared(bob, id)?.epochs.map(\.number).max())
        let toAlice = try aliceContact(on: bob)
        #expect(alice.channelKeyAnswered.isEmpty)

        bob.sendForTests(.channelKeyWanted(group: id, epoch: epoch), to: toAlice)
        await until([alice]) { !alice.channelKeyAnswered.isEmpty }
        let first = try #require(alice.channelKeyAnswered.values.first)
        for _ in 0..<5 { bob.sendForTests(.channelKeyWanted(group: id, epoch: epoch), to: toAlice) }
        await settle(alice, bob, cara)
        #expect(alice.channelKeyAnswered.count == 1)
        #expect(alice.channelKeyAnswered.values.first == first, "later asks inside ten minutes get no answer")
    }

    @Test func noAnswerLeavesTheFollowerWaitingAndSaysSo() async throws {
        let (alice, bob, cara, dave, bobFP, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        await until([alice, bob, cara]) { shared(bob, id)?.missedKey == true }
        // The staff phone never answers (it is off, or its app is too old to know the ask): nothing breaks.
        bob.askForKeyAgain(id)
        await settle(bob, cara, rounds: 4)
        #expect(shared(bob, id)?.missedKey == true)
        #expect(shared(bob, id)?.keyAskedAt != nil, "so the details sheet can say he asked, and what may be wrong")
        #expect(bob.conversation(id) != nil)
    }

    @Test func requestsFromThoseNotEntitledGetNothing() async throws {
        let (alice, bob, cara, dave, bobFP, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let other = alice.startConversation(kind: .channel, title: "Other", members: [try aliceKnows(alice, "Cara")])
        await until([alice, cara]) { shared(cara, other.id) != nil && shared(alice, other.id)?.roster?.live.count == 1 }
        // The channel moves on without Bob, so there is something to ask for.
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        await until([alice, bob, cara]) { shared(bob, id)?.missedKey == true }
        let epoch = try #require(shared(bob, id)?.epochs.map(\.number).max())

        // Dave follows nothing; Bob names a channel he is not in; Cara asks for an epoch that is not older than hers.
        dave.sendForTests(.channelKeyWanted(group: id, epoch: 0), to: try aliceContact(on: dave))
        bob.sendForTests(.channelKeyWanted(group: other.id, epoch: 0), to: try aliceContact(on: bob))
        cara.sendForTests(.channelKeyWanted(group: id, epoch: epoch + 1), to: try aliceContact(on: cara))
        await settle(alice, bob, cara, dave)
        #expect(alice.channelKeyAnswered.isEmpty, "none of them was answered")
        #expect(shared(bob, id)?.missedKey == true)
        #expect(shared(dave, id) == nil)

        // And a follower who was taken out gets nothing either.
        alice.removeMember(id, bobFP)
        await settle(alice, bob, cara)
        bob.sendForTests(.channelKeyWanted(group: id, epoch: epoch), to: try aliceContact(on: bob))
        await settle(alice, bob, cara)
        #expect(alice.channelKeyAnswered.isEmpty)
        #expect(shared(bob, id)?.epochs.map(\.number).max() == epoch)
    }

    // MARK: Followers who came through a channel's code (hidden contacts on both sides)

    /// Alice's channel, with Bob and Cara following through its code: nobody here is a visible contact of anyone.
    private func codeChannel() async throws -> (alice: AppModel, bob: AppModel, cara: AppModel, id: UUID) {
        AppModel.leaveRekeyWindow = 0
        AppModel.rekeyRetry = 30
        AppModel.channelAdmitsPerHour = 60
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        let code = alice.makeInviteCode(channel: channel.id)
        _ = try #require(bob.addContact(code: code, nickname: ""))
        _ = try #require(cara.addContact(code: code, nickname: ""))
        await until([alice, bob, cara]) {
            bob.conversation(channel.id)?.shared != nil && cara.conversation(channel.id)?.shared != nil
                && alice.conversation(channel.id)?.shared?.roster?.live.count == 2
        }
        #expect(bob.data.contacts.allSatisfy(\.hidden) && alice.data.contacts.allSatisfy { $0.hidden || $0.isSelf })
        return (alice, bob, cara, channel.id)
    }

    @Test func aFollowerWhoCameThroughTheCodeCanLeave() async throws {
        let (alice, bob, cara, id) = try await codeChannel()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        #expect(bob.canTellInviter(try #require(bob.conversation(id))))
        bob.delete(id)
        await until([alice, bob, cara]) { shared(alice, id)?.settings.epoch == epoch + 1 }
        #expect(shared(alice, id)?.roster?.live.count == 1, "only Cara is left")
        #expect(shared(alice, id)?.settings.epoch == epoch + 1)
        alice.send("after", in: id)
        await until([alice, bob, cara]) { cara.conversation(id)?.messages.last?.text == "after" }
        #expect(cara.conversation(id)?.messages.last?.text == "after")
    }

    @Test func aFollowerWhoCameThroughTheCodeCanAskForAMissedKey() async throws {
        let (alice, bob, cara, id) = try await codeChannel()
        defer { for m in [alice, bob, cara] { m.lock() } }
        let bobFP = try #require(bob.identity).fingerprint
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        alice.send("two", in: id)
        await until([alice, bob, cara]) { shared(bob, id)?.missedKey == true }
        bob.askForKeyAgain(id)
        #expect(shared(bob, id)?.keyAskedAt != nil)
        await until([alice, bob, cara]) { bob.conversation(id)?.messages.last?.text == "two" }
        #expect(bob.conversation(id)?.messages.last?.text == "two")
        #expect(shared(bob, id)?.missedKey == false)
    }

    @Test func aFollowerWhoseInviterIsGoneLeavesAnywayAndIsTold() async throws {
        let (alice, bob, cara, id) = try await codeChannel()
        defer { for m in [alice, bob, cara] { m.lock() } }
        bob.data.contacts.removeAll { $0.name == "Alice" }
        #expect(bob.canTellInviter(try #require(bob.conversation(id))) == false, "the sheet says so before he leaves")
        bob.delete(id)
        #expect(bob.conversation(id) == nil)
        await settle(alice, bob, cara)
        #expect(shared(alice, id)?.roster?.live.count == 2, "staff heard nothing, and nothing broke")
    }

    @Test func anInviteFromAnotherContactForAChannelIFollowChangesNothingAndGetsNoCard() async throws {
        let (alice, bob, cara, dave, bobFP, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        try rekeyWithoutBob(alice, id, bobKey: try bobsKey(alice, id, bobFP))
        await until([alice, bob, cara]) { shared(bob, id)?.missedKey == true }
        // Someone who holds the newest settings and key (another follower, say) sends them to Bob as an invite.
        let held = try #require(shared(alice, id))
        let invite = GroupInvite(settings: held.settings, epoch: try #require(held.current))
        let identity = Identity.generate()
        var stranger = Contact(fingerprint: identity.fingerprint, name: "Other", signingKey: identity.card.signing,
                               agreementKey: identity.card.agreement, sendID: Data())
        var device = DeviceLink(id: Data.random(8), sendID: Data.random(16))
        device.awaitingHello = true
        stranger.devices = [device]
        bob.data.contacts.append(stranger)
        let inviterAccount = shared(bob, id)?.ownerAccount
        bob.receiveForTests(.groupInvite(invite), from: stranger)
        #expect(shared(bob, id)?.ownerAccount == inviterAccount, "a forwarded copy never changes whom he answers to")
        let queued = try #require(bob.data.contacts.first { $0.fingerprint == stranger.fingerprint }).devices.flatMap(\.pending)
        #expect(queued.isEmpty, "and no card went back")
        #expect(shared(bob, id)?.missedKey == false, "the keys it holds are the real ones, so they are used")
        // The same invite from the one who invited him is taken.
        bob.receiveForTests(.groupInvite(invite), from: try aliceContact(on: bob))
        #expect(shared(bob, id)?.missedKey == false)
        #expect(shared(bob, id)?.settings.epoch == held.settings.epoch)
        #expect(shared(bob, id)?.ownerAccount == inviterAccount)
    }

    // MARK: Leaves are batched

    @Test func followersWhoLeaveTogetherShareOneNewEpoch() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers(allThree: true)
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        AppModel.leaveRekeyWindow = 4
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let stashedBob = try #require(bob.conversation(id)), stashedCara = try #require(cara.conversation(id))
        bob.delete(id)
        cara.delete(id)
        await settle(alice, bob, cara, dave)
        #expect(shared(alice, id)?.roster?.live.count == 1, "both are out of the roster at once")
        #expect(shared(alice, id)?.settings.epoch == epoch, "but the new key waits for the window")
        try? await Task.sleep(for: .seconds(4.5))
        await settle(alice, bob, cara, dave)
        #expect(shared(alice, id)?.settings.epoch == epoch + 1, "one new epoch for both")
        await settle(alice, dave, rounds: 8)
        #expect(shared(alice, id)?.settings.epoch == epoch + 1, "and no second one")
        // The mark of the leaves is cleared by the next maintenance pass. A manual `syncOnce` does nothing while the model's own
        // background sync is in the middle of a round (it holds `syncing`), so all eight above can be skipped: run the pass itself.
        alice.tendSharedGroups()
        #expect(shared(alice, id)?.rekeyAfter == nil)

        alice.send("after", in: id)
        await until([alice, dave]) { dave.conversation(id)?.messages.last?.text == "after" }
        #expect(dave.conversation(id)?.messages.last?.text == "after")
        bob.data.conversations.append(stashedBob)
        cara.data.conversations.append(stashedCara)
        await settle(alice, bob, cara, dave)
        #expect(bob.conversation(id)?.messages.map(\.text) == ["first"])
        #expect(cara.conversation(id)?.messages.map(\.text) == ["first"])
        #expect(shared(bob, id)?.epochs.map(\.number) == [epoch] && shared(cara, id)?.epochs.map(\.number) == [epoch])
    }

    @Test func aNewEpochThatCouldNotBeMadeIsTriedAgainUntilItIs() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let a = try #require(alice.data.conversations.firstIndex { $0.id == id })
        bob.delete(id)
        // The first attempt can't be made (no epoch to build on, as a stand-in for settings that don't fit).
        let kept = try #require(shared(alice, id)?.epochs)
        for _ in 0..<40 where alice.data.conversations[a].shared?.roster?.live.count == 2 {
            await bob.syncOnce()
            alice.data.conversations[a].shared?.epochs = []
            await alice.syncOnce()
        }
        alice.data.conversations[a].shared?.epochs = []
        await alice.syncOnce()
        #expect(alice.data.conversations[a].shared?.roster?.live.count == 1)
        #expect(alice.data.conversations[a].shared?.rekeyAfter == epoch, "still owed")
        alice.data.conversations[a].shared?.epochs = kept
        AppModel.rekeyRetry = 0.5
        try? await Task.sleep(for: .seconds(1))
        await alice.syncOnce()
        #expect(shared(alice, id)?.settings.epoch == epoch + 1, "made on a later pass")
        AppModel.rekeyRetry = 30
    }

    @Test func aStaleLeaveAfterBeingAddedAgainIsIgnored() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let toAlice = try aliceContact(on: bob)
        let bobOnAlice = try #require(alice.data.contacts.first { $0.name == "Bob" })
        _ = toAlice
        alice.handlingSentAt = Date().addingTimeInterval(-86_400)
        alice.receiveForTests(.channelLeave(group: id), from: bobOnAlice)
        alice.handlingSentAt = nil
        #expect(shared(alice, id)?.roster?.live.count == 2, "older than the entry: dropped")
        alice.receiveForTests(.channelLeave(group: id), from: bobOnAlice)
        #expect(shared(alice, id)?.roster?.live.count == 1)
    }

    @Test func codeJoinsPastTheHourlyLimitWaitAndAreLetInAsRoomComes() async throws {
        AppModel.channelAdmitsPerHour = 1
        defer { AppModel.channelAdmitsPerHour = 60 }
        let alice = try await makeUser("Alice"), bob = try await makeUser("Bob"), cara = try await makeUser("Cara")
        defer { for m in [alice, bob, cara] { m.lock() } }
        let channel = alice.startConversation(kind: .channel, title: "Drops", members: [])
        let code = alice.makeInviteCode(channel: channel.id)
        _ = try #require(bob.addContact(code: code, nickname: ""))
        await until([alice, bob]) { alice.conversation(channel.id)?.shared?.roster?.live.count == 1 }
        _ = try #require(cara.addContact(code: code, nickname: ""))
        await settle(alice, bob, cara)
        #expect(alice.conversation(channel.id)?.shared?.roster?.live.count == 1, "the second waits")
        #expect(alice.conversation(channel.id)?.shared?.joinWaiting?.count == 1)
        #expect(cara.conversation(channel.id) == nil)
        alice.channelAdmits = [:]
        await until([alice, bob, cara]) { cara.conversation(channel.id)?.shared != nil }
        #expect(cara.conversation(channel.id)?.shared != nil)
        #expect(alice.conversation(channel.id)?.shared?.joinWaiting?.isEmpty ?? true)
    }

    // MARK: Limits on code joins and leaves

    /// A joiner who is not in anyone's list yet: a hidden contact whose app takes part in channels, nothing sent to it.
    private func fakeJoiner(_ alice: AppModel, _ n: Int) -> String {
        let identity = Identity.generate()
        var contact = Contact(fingerprint: identity.fingerprint, name: "J\(n)", signingKey: identity.card.signing,
                              agreementKey: identity.card.agreement, sendID: Data(), hidden: true)
        var device = DeviceLink(id: Data.random(8), sendID: Data.random(16))
        device.awaitingHello = true
        device.readsChannels = true
        contact.devices = [device]
        alice.data.contacts.append(contact)
        return contact.fingerprint
    }

    @Test func oneIdentitySayingHelloOverAndOverUsesOneSlot() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let daveFP = try aliceKnows(alice, "Dave")
        for _ in 0..<100 { alice.admitFromCodeForTests([daveFP], in: id) }
        #expect(alice.channelAdmits[id]?.count == 1, "one identity, one slot")
        #expect(shared(alice, id)?.invited.keys.contains(daveFP) == true)
        // Someone already following uses none.
        let bobFP = try aliceKnows(alice, "Bob")
        alice.admitFromCodeForTests([bobFP, bobFP], in: id)
        #expect(alice.channelAdmits[id]?.count == 1)
    }

    @Test func joinersPastTheLimitWaitAndAreLetInAsTheHourAllows() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let fps = (0..<70).map { fakeJoiner(alice, $0) }
        alice.admitFromCodeForTests(fps, in: id)
        #expect(alice.channelAdmits[id]?.count == 60)
        #expect(Set(shared(alice, id)?.invited.keys.filter { fps.contains($0) } ?? []).count == 60)
        #expect(shared(alice, id)?.joinWaiting == Array(fps[60...]), "the ten extra wait, in order")
        alice.admitFromCodeForTests(fps, in: id)
        #expect(shared(alice, id)?.joinWaiting == Array(fps[60...]), "asking again changes nothing")
        alice.channelAdmits = [:]
        await alice.syncOnce()
        #expect(shared(alice, id)?.joinWaiting == nil)
        #expect(Set(shared(alice, id)?.invited.keys.filter { fps.contains($0) } ?? []).count == 70)
    }

    @Test func aFloodOfWaitingJoinersKeepsTheEarliest() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        AppModel.channelAdmitsPerHour = 0
        defer { AppModel.channelAdmitsPerHour = 60 }
        let fps = (0..<1_600).map { "flood-\($0)" }
        alice.admitFromCodeForTests(Array(fps[0..<100]), in: id)
        alice.admitFromCodeForTests(Array(fps[100...]), in: id)
        let waiting = try #require(shared(alice, id)?.joinWaiting)
        #expect(waiting.count == 1_500)
        #expect(waiting.first == fps.first && waiting.last == fps[1_499], "the newest arrivals are the ones dropped")
    }

    @Test func aLeaveAfterTheEpochMovedOnStillGetsItsOwnRekey() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers(allThree: true)
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        AppModel.leaveRekeyWindow = 3600
        let epoch = try #require(shared(alice, id)?.settings.epoch)
        let bobOnAlice = try #require(alice.data.contacts.first { $0.name == "Bob" })
        let caraOnAlice = try #require(alice.data.contacts.first { $0.name == "Cara" })
        alice.receiveForTests(.channelLeave(group: id), from: bobOnAlice)
        #expect(shared(alice, id)?.rekeyAfter == epoch)
        // The epoch moves on for another reason before the maintenance pass has cleared the mark.
        alice.startNewEpoch(id)
        #expect(shared(alice, id)?.settings.epoch == epoch + 1)
        alice.receiveForTests(.channelLeave(group: id), from: caraOnAlice)
        #expect(shared(alice, id)?.rekeyAfter == epoch + 1, "the second leaver is still owed a new epoch")
        #expect(shared(alice, id)?.rekeyDue != nil)
        AppModel.leaveRekeyWindow = 0
        alice.data.conversations[try #require(alice.data.conversations.firstIndex { $0.id == id })].shared?.rekeyDue = Date()
        await alice.syncOnce()
        #expect(shared(alice, id)?.settings.epoch == epoch + 2)
    }

    @Test func aLeaveSentAFewMinutesBeforeTheEntryStillCounts() async throws {
        let (alice, bob, cara, dave, _, id) = try await channelWithTwoFollowers()
        defer { for m in [alice, bob, cara, dave] { m.lock() } }
        let bobOnAlice = try #require(alice.data.contacts.first { $0.name == "Bob" })
        alice.handlingSentAt = Date().addingTimeInterval(-300)
        alice.receiveForTests(.channelLeave(group: id), from: bobOnAlice)
        alice.handlingSentAt = nil
        #expect(shared(alice, id)?.roster?.live.count == 1, "a follower clock a few minutes slow is not a stale copy")
    }

    // MARK: Staff on an older app

    @Test func anOlderStaffAppIgnoresTheNewPayloads() throws {
        // The new cases are unknown to an app from before: its decoder refuses them, and an envelope that holds one is
        // dropped like any other it can't read.
        let id = UUID()
        for payload in [Payload.channelLeave(group: id), .channelKeyWanted(group: id, epoch: 3)] {
            let wire = try payload.wire(framed: false)
            #expect(try Payload.fromWire(wire) == payload)
            var text = try #require(String(data: wire, encoding: .utf8))
            for name in ["channelLeave", "channelKeyWanted"] { text = text.replacingOccurrences(of: "\"\(name)\"", with: "\"\(name)Unknown\"") }
            #expect((try? Payload.fromWire(Data(text.utf8))) == nil)
        }
    }
}
