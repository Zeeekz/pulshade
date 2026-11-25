import Testing
import Foundation
@testable import Pulshade

/// An account lives on one iPhone. Builds before 22 could link more; what they left behind is ended once, and nothing
/// another device of the account says is taken any more.
@MainActor
@Suite struct OneDevicePerAccountTests {
    private func signedInModel() async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        return model
    }

    private func friend(_ name: String) -> Contact {
        let identity = Identity.generate()
        var c = Contact(fingerprint: identity.fingerprint, name: name, signingKey: identity.card.signing,
                        agreementKey: identity.card.agreement, sendID: Data(), hidden: false)
        var device = DeviceLink(id: Data.random(16), sendID: Data.random(16))
        device.awaitingHello = true
        c.devices = [device]
        return c
    }

    /// Another device of this account, as an older build linked it, that nothing can be sent to yet, so what is queued
    /// for it stays visible. `heard` is when it was last heard from (nil: never).
    private func addSiblingDevice(_ model: AppModel, id: Data, heard: Date? = Date()) throws -> Int {
        let me = try #require(model.me(nil))
        var own = Contact(fingerprint: me.fingerprint, name: "My devices", signingKey: me.card.signing,
                          agreementKey: me.card.agreement, sendID: Data(), receiveKey: Mailbox.make().receiveKey, hidden: true)
        var device = DeviceLink(id: id, sendID: Data.random(16))
        device.awaitingHello = true
        device.lastHeard = heard
        own.devices = [device]
        own.isSelf = true
        model.data.contacts.append(own)
        return model.data.contacts.count - 1
    }

    private func queued(_ model: AppModel, _ i: Int) -> [Payload] {
        model.data.contacts[i].devices.flatMap(\.pending).map(\.payload)
    }

    private static let low = Data(repeating: 0x01, count: 16), high = Data(repeating: 0xFF, count: 16)
    private static let longAgo = Date().addingTimeInterval(-60 * 24 * 3600)

    @Test func onlyWordThatEndsTheAccountIsTakenFromAnotherDevice() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        let own = try addSiblingDevice(model, id: Self.high)
        let blocked = Identity.generate().fingerprint
        model.data.blocked = [blocked]
        model.receiveForTests(.sync(.unblocked(blocked)), from: model.data.contacts[own])
        #expect(model.data.blocked == [blocked], "synced data isn't taken")
        let bob = friend("Bob")
        model.data.contacts.append(bob)
        model.receiveForTests(.sync(.accountErased), from: bob)
        #expect(model.identity != nil, "a friend can't end the account")
        model.receiveForTests(.sync(.accountErased), from: model.data.contacts[own])
        #expect(model.identity == nil, "a Burn on another device of the account still wipes this one")
    }

    @Test func nothingIsSentToOtherDevices() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        let own = try addSiblingDevice(model, id: Self.high)
        model.data.blocked = ["someone"]
        model.unblock("someone")
        model.updateProfile { $0.bio = "new" }
        #expect(model.data.blocked.isEmpty)
        #expect(!queued(model, own).contains { if case .sync = $0 { true } else { false } })
    }

    @Test func theKeeperWaitsUntilTheOtherDeviceHasBeenTold() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        model.data.deviceID = Self.low
        let own = try addSiblingDevice(model, id: Self.high)
        await model.endLinkedDevices()
        #expect(model.identity != nil)
        #expect(model.data.contacts.contains { $0.isSelf }, "the other device hasn't been told yet, so it stays listed")
        #expect(queued(model, own).contains { if case .sync(.accountDetached) = $0 { true } else { false } })
        await model.endLinkedDevices()
        #expect(queued(model, own).filter { if case .sync(.accountDetached) = $0 { true } else { false } }.count == 1, "asked once")
    }

    @Test func aStaleDeviceIsUnlinkedAndNeverMakesThisOneGiveWay() async throws {
        for heard in [Self.longAgo, nil] as [Date?] {
            let model = try await signedInModel()
            model.data.deviceID = Self.high
            _ = try addSiblingDevice(model, id: Self.low, heard: heard)
            model.data.contacts.append(friend("Bob"))
            let secret = model.data.groupSecret

            await model.endLinkedDevices()

            #expect(model.identity != nil, "the only phone in use keeps the account")
            #expect(!model.data.contacts.contains { $0.isSelf })
            #expect(model.data.groupSecret != secret, "groups move to keys the old device can't work out")
            let bob = try #require(model.data.contacts.firstIndex { $0.name == "Bob" })
            #expect(queued(model, bob).contains {
                if case let .devicesUnlinked(ids, kept) = $0 { ids == [Self.low] && kept == [Self.high] } else { false }
            }, "friends are told it's unlinked")
            model.lock()
        }
    }

    @Test func aDeviceThatDoesntKeepTheAccountWaitsForTheKeeper() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        model.data.deviceID = Self.high
        let own = try addSiblingDevice(model, id: Self.low)
        await model.endLinkedDevices()
        #expect(model.identity != nil, "no wipe on this device's own say")
        #expect(model.data.contacts.contains { $0.isSelf })

        model.receiveForTests(.sync(.accountDetached), from: model.data.contacts[own])
        for _ in 0..<100 where model.identity != nil { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.identity == nil, "the keeper's word wipes it")
        #expect(model.burnNotice?.contains("one iPhone") == true)
    }

    @Test func anEmptyListOfOtherDevicesIsJustDropped() async throws {
        let model = try await signedInModel()
        defer { model.lock() }
        let own = try addSiblingDevice(model, id: Self.high)
        model.data.contacts[own].devices = []
        await model.endLinkedDevices()
        #expect(model.identity != nil)
        #expect(!model.data.contacts.contains { $0.isSelf })
    }
}
