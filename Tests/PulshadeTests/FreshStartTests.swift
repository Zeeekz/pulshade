import Testing
import Foundation
import CryptoKit
@testable import Pulshade
import PulshadeShared

/// A fresh-start order, signed by the admin key, wipes every account older than it and no account made after it.
@MainActor
struct FreshStartTests {
    private func makeUser() async throws -> AppModel {
        let model = testModel("pulshade-test")
        try await model.create(identity: .generate(), profile: Profile(name: "Alice"), passcode: "test-passcode")
        return model
    }

    private func withAdminKey(_ admin: Curve25519.Signing.PrivateKey, _ body: () async throws -> Void) async rethrows {
        await AdminKeyGate.shared.acquire()
        let previous = AppModel.adminKey
        AppModel.adminKey = admin.publicKey.rawRepresentation
        defer { AppModel.adminKey = previous; Task { await AdminKeyGate.shared.release() } }
        try await body()
    }

    @Test func anOrderWipesOlderAccountsAndOnlyGenuineOnes() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        try await withAdminKey(admin) {
            let old = try await makeUser()
            defer { old.lock() }
            // Made before the order: a forged order does nothing, a signed one wipes it.
            let later = Date().addingTimeInterval(60)
            let forged = try Announcement.make("\(Announcement.freshStartTag) Pulshade is starting over.", signedBy: Curve25519.Signing.PrivateKey(), at: later)
            old.applyAnnouncements([forged])
            #expect(old.identity != nil, "a forged order is ignored")
            let order = try Announcement.make("\(Announcement.freshStartTag) Pulshade is starting over.", signedBy: admin, at: later)
            old.applyAnnouncements([order])
            #expect(old.identity == nil, "the account is gone")
        }
    }

    @Test func anAccountMadeAfterTheOrderKeepsItself() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        try await withAdminKey(admin) {
            let order = try Announcement.make("\(Announcement.freshStartTag) Pulshade is starting over.", signedBy: admin, at: Date().addingTimeInterval(-3600))
            let fresh = try await makeUser()
            defer { fresh.lock() }
            fresh.applyAnnouncements([order])
            #expect(fresh.identity != nil, "an account newer than the order isn't wiped by it")
        }
    }

    @Test func ordinaryAnnouncementsDontWipe() async throws {
        let admin = Curve25519.Signing.PrivateKey()
        try await withAdminKey(admin) {
            let model = try await makeUser()
            defer { model.lock() }
            let news = try Announcement.make("Voice notes now show a waveform.", signedBy: admin, at: Date().addingTimeInterval(60))
            model.applyAnnouncements([news])
            #expect(model.identity != nil)
            #expect(Announcement(id: "", text: Announcement.freshStartTag, date: 5, sig: "").orders(freshStartFor: nil), "no date counts as old")
        }
    }
}
