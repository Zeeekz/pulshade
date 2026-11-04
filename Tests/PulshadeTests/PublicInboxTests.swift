import Testing
import Foundation
@testable import Pulshade

/// A public @handle's request mailbox is worked out from the account, so a copy recovered on another device can't
/// list a mailbox the first one never reads (which once left requests to @zeekz waiting where nobody looked).
@MainActor
struct PublicInboxTests {
    private func copy(of identity: Identity) async throws -> AppModel {
        let model = testModel("pulshade-inbox")
        try await model.create(identity: try Identity(seed: identity.seed), profile: Profile(name: "Zeekz"), passcode: "test-passcode")
        return model
    }

    private func listedMailbox(_ model: AppModel, _ handle: String) throws -> Data {
        let entry = try model.signedEntry(handle: handle, persona: nil)
        let blob = try #require(Data(base64Encoded: entry.blob))
        return try JSONDecoder.pulshade.decode(DirectoryProfile.self, from: blob).sendID
    }

    @Test func everyCopyOfAnAccountListsTheSameMailbox() async throws {
        let account = Identity.generate()
        let phone = try await copy(of: account)
        let recovered = try await copy(of: account)
        defer { phone.lock(); recovered.lock() }
        #expect(try listedMailbox(phone, "zeekz") == listedMailbox(recovered, "zeekz"))
        #expect(try listedMailbox(phone, "zeekz") != listedMailbox(phone, "zeekz2"), "Each handle has its own")
        #expect(try listedMailbox(phone, "zeekz") == Mailbox.sendID(for: account.publicInboxKey(handle: "ZEEKZ")))
    }

    @Test func aReplacedMailboxIsStillReadForAWeek() async throws {
        let model = try await copy(of: .generate())
        defer { model.lock() }
        // A random public mailbox, as every device made before.
        let old = Mailbox.make().receiveKey
        model.data.invites.append(OpenInvite(receiveKey: old, isPublic: true))
        _ = try model.signedEntry(handle: "zeekz", persona: nil)

        let publicOnes = model.data.invites.filter(\.isPublic)
        #expect(publicOnes.count == 2)
        let retiring = try #require(publicOnes.first { $0.receiveKey == old })
        let retiresAt = try #require(retiring.retiresAt)
        #expect(abs(retiresAt.timeIntervalSinceNow - 7 * 24 * 3600) < 60)
        #expect(publicOnes.first { $0.receiveKey != old }?.retiresAt == nil)

        // Listing again doesn't push the week back.
        _ = try model.signedEntry(handle: "zeekz", persona: nil)
        #expect(model.data.invites.first { $0.receiveKey == old }?.retiresAt == retiresAt)
    }
}
