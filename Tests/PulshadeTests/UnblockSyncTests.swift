import Testing
import Foundation
@testable import Pulshade

/// Unblocking someone on one of your devices lets them through on the others too.
@MainActor
@Suite struct UnblockSyncTests {
    @Test func unblockedEventRoundTrips() throws {
        let event = SyncEvent.unblocked("abc123")
        let back = try JSONDecoder.pulshade.decode(SyncEvent.self, from: try JSONEncoder.pulshade.encode(event))
        #expect(back == event)
    }

    @Test func receivingItClearsTheBlockAndTheName() async throws {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        defer { model.lock() }
        model.data.blocked = ["someone", "other"]
        model.data.blockedNames = ["someone": "Someone", "other": "Other"]

        model.applySync(.unblocked("someone"))

        #expect(model.data.blocked == ["other"])
        #expect(model.data.blockedNames["someone"] == nil)
        #expect(model.data.blockedNames["other"] == "Other")
    }

    private func signedInModel() async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        return model
    }

    private func stranger(_ name: String, hidden: Bool) -> Contact {
        let identity = Identity.generate()
        return Contact(fingerprint: identity.fingerprint, name: name, signingKey: identity.card.signing,
                       agreementKey: identity.card.agreement, sendID: Data(), hidden: hidden)
    }

    /// A second device of this account that nothing can be sent to yet, so what is queued for it stays visible.
    private func addSiblingDevice(_ model: AppModel) throws -> Int {
        let me = try #require(model.me(nil))
        var own = Contact(fingerprint: me.fingerprint, name: "My devices", signingKey: me.card.signing,
                          agreementKey: me.card.agreement, sendID: Data(), receiveKey: Mailbox.make().receiveKey, hidden: true)
        var device = DeviceLink(id: Data.random(8), sendID: Data.random(16))
        device.awaitingHello = true
        own.devices = [device]
        own.isSelf = true
        model.data.contacts.append(own)
        return model.data.contacts.count - 1
    }

    private func queuedSync(_ model: AppModel, _ own: Int) -> [SyncEvent] {
        model.data.contacts[own].devices.flatMap(\.pending).compactMap { if case let .sync(event) = $0.payload { event } else { nil } }
    }

    @Test func anUnblockSyncFromAContactOrAGroupMemberChangesNothing() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        let friend = stranger("Friend", hidden: false), member = stranger("Member", hidden: true)
        model.data.contacts += [friend, member]
        let blocked = Identity.generate().fingerprint
        model.data.blocked = [blocked, friend.fingerprint, member.fingerprint]
        model.data.blockedNames = [blocked: "Blocked"]

        for sender in [friend, member] {
            for target in [blocked, friend.fingerprint, member.fingerprint] {
                model.receiveForTests(.sync(.unblocked(target)), from: sender)
            }
        }

        #expect(model.data.blocked == [blocked, friend.fingerprint, member.fingerprint], "only your own devices can unblock")
        #expect(model.data.blockedNames[blocked] == "Blocked")
    }

    @Test func unblockingTellsYourOtherDevicesButHearingItDoesNotEchoBack() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        let own = try addSiblingDevice(model)
        model.data.blocked = ["someone"]

        model.unblock("someone")
        #expect(model.data.blocked.isEmpty)
        #expect(queuedSync(model, own) == [.unblocked("someone")], "the other devices are told once")

        // The same news arriving from another device is applied without being sent on.
        model.data.contacts[own].devices[0].pending = []
        model.data.blocked = ["other"]
        model.applySync(.unblocked("other"))
        #expect(model.data.blocked.isEmpty)
        #expect(queuedSync(model, own).isEmpty, "applying a sync event never echoes it back")
        #expect(model.applyingSync == false)
    }

    @Test func unblockingSomeoneWhoIsNotBlockedChangesNothing() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        model.data.blocked = ["kept"]
        model.data.blockedNames = ["kept": "Kept"]

        model.applySync(.unblocked("never-blocked"))
        #expect(model.data.blocked == ["kept"])
        #expect(model.data.blockedNames == ["kept": "Kept"])

        model.unblock("never-blocked")
        #expect(model.data.blocked == ["kept"])
        #expect(model.data.blockedNames == ["kept": "Kept"])
    }
}
