import Testing
import Foundation
@testable import Pulshade

/// Saved data must never be opened by a build that doesn't know all of it: it would drop what it can't read and
/// save the rest back, and the missing parts would be gone for good. (Once, an older build did exactly that to
/// profile links.)
struct AppDataFormatTests {
    /// Every saved field, empty ones too.
    private func keys(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label).map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }.sorted()
    }

    @Test func aBuildRefusesDataSavedByANewerOne() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder.pulshade.encode(AppData())) as? [String: Any])
        json["format"] = AppData.currentFormat + 1
        let newer = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder.pulshade.decode(AppData.self, from: newer) }
        // The same data at this build's own format, and data from before there was a format, both open.
        json["format"] = AppData.currentFormat
        _ = try JSONDecoder.pulshade.decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        json["format"] = nil
        let old = try JSONDecoder.pulshade.decode(AppData.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.format == AppData.currentFormat, "and is saved at the current one from then on")
    }

    /// Fails when a field is added to what's saved without raising `AppData.currentFormat`. Change the lists below
    /// together with it.
    @Test func changingWhatIsSavedMeansRaisingTheFormat() throws {
        #expect(AppData.currentFormat == 10)
        let app = keys(AppData())
        let profile = keys(Profile())
        #expect(app == Self.appKeys, "AppData's saved fields changed: raise AppData.currentFormat, then update this list")
        #expect(profile == Self.profileKeys, "Profile's saved fields changed: raise AppData.currentFormat, then update this list")
        let contact = keys(Contact(fingerprint: "f", signingKey: Data(), agreementKey: Data(), sendID: Data()))
        #expect(contact == Self.contactKeys, "Contact's saved fields changed: raise AppData.currentFormat, then update this list")
    }

    static let appKeys = ["activePersona", "announcementsSeen", "backupDigest", "backupSavedAt", "blobWipes", "blocked", "blockedNames", "chatCodes", "clipParts", "contacts", "conversations", "decoySeed", "deviceID",
                          "facade", "format", "handlesTidied", "inviteRelay", "invites", "linkOffers", "outbox", "panicSeed", "pendingBackupForget", "personas", "profile",
                          "profileShared", "relay", "requests", "security", "seenEnvelopes", "stories", "storyChoices", "theme"]
    static let profileKeys = ["avatar", "badge", "banner", "bio", "collectibleCodes", "collectibles", "collectionCode", "color", "format", "handle", "links",
                              "moreHandles", "name", "notes", "updatedAt"]
    static let contactKeys = ["addedAt", "agreementKey", "avatar", "awaitingAcceptance", "badge", "banner", "bio", "collectibles", "color", "devices",
                              "fingerprint", "handle", "hidden", "isSelf", "links", "name", "nickname", "notes", "persona", "receiveKey", "relay",
                              "signingKey", "toldPresence", "verified", "walletChangedAt", "wantsMyPresence"]
}
