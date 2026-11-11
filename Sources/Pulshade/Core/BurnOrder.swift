import Foundation
import CryptoKit
import Security

// How a Burn finishes on the server after the phone has been wiped. See docs/burn-order.md.

extension Identity {
    /// A secret only this identity's devices hold. Every deposit this identity makes carries a stamp made from it, which the
    /// relay can't link to anything until a Burn reveals the secret and the relay erases what is still waiting.
    var recallKey: Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("pulshade.recall.v1".utf8), using: SymmetricKey(data: signingKey.rawRepresentation)))
    }
}

enum Recall {
    /// A fresh stamp for one deposit: a random number and the hash of the token only `recallKey` can make from it.
    static func stamp(_ recallKey: Data) -> (n: UInt64, hash: Data) {
        let n = UInt64.random(in: 0...UInt64.max)
        return (n, hash(recallKey: recallKey, n: n))
    }

    static func hash(recallKey: Data, n: UInt64) -> Data {
        var big = n.bigEndian
        let token = HMAC<SHA256>.authenticationCode(for: withUnsafeBytes(of: &big) { Data($0) }, using: SymmetricKey(data: recallKey))
        return Data(SHA256.hash(data: Data(token)))
    }
}

/// What a finished Burn still has to do on the relay. It can erase things but not read anything: signatures that only allow
/// deleting, secrets that only allow erasing, and "forget me" envelopes that are already sealed.
struct BurnOrder: Codable, Equatable {
    struct Signed: Codable, Equatable {
        var key: Data
        var sig: Data
    }

    /// A sealed envelope for a contact, saying the account is gone, still to be dropped at their mailbox.
    struct Farewell: Codable, Equatable {
        var sendID: Data
        var blob: Data
        /// The address to drop it at, as it was reached when the order was made.
        var relay: String
    }

    var made = Date()
    /// When the signatures were made. The relay accepts them for 30 days.
    var ts: UInt64
    /// The relay address that was in use (an onion address, or the direct one).
    var relay: String
    var backup: Signed?
    var handles: [Signed] = []
    var recall: [Data] = []
    var blobs: [BlobWipe] = []
    /// Receive keys of every mailbox of the account: what waits there is erased and the mailbox is closed.
    var mailboxes: [Data] = []
    var farewells: [Farewell] = []
    var serverDone = false

    var isFinished: Bool { serverDone && farewells.isEmpty }

    /// The relay stops accepting the signatures after 30 days: after 29 there is no point in trying again.
    var isTooOld: Bool { RelayClock.now.timeIntervalSince1970 - TimeInterval(ts) > 29 * 86_400 }

    /// What goes to `POST /v1/burn`.
    func requestBody() throws -> Data {
        struct Part: Encodable { var key: Data; var sig: Data }
        struct Blob: Encodable { var id: String; var secret: String }
        struct Request: Encodable {
            var ts: UInt64
            var backup: Part?
            var handles: [Part]
            var recall: [Data]
            var blobs: [Blob]
            var mailboxes: [String]
        }
        return try JSONEncoder().encode(Request(
            ts: ts, backup: backup.map { Part(key: $0.key, sig: $0.sig) }, handles: handles.map { Part(key: $0.key, sig: $0.sig) },
            recall: recall, blobs: blobs.map { Blob(id: $0.id, secret: $0.secret.hex) }, mailboxes: mailboxes.map(\.hex)))
    }
}

/// Keeps a burn order on the phone, sealed, until the relay has confirmed everything. It is the one thing that outlives a
/// wipe, so it holds nothing that can read: its file is sealed with a fresh random key kept in the Keychain (readable after
/// the first unlock, this device only), and both go the moment the order is finished.
struct BurnOrderStore {
    var file: URL
    var service: String

    private func key(create: Bool) -> SymmetricKey? {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "key"]
        var query = match
        query[kSecReturnData as String] = true
        var found: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create else { return nil }
        let fresh = Data.random(32)
        var add = match
        add[kSecValueData as String] = fresh
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? SymmetricKey(data: fresh) : nil
    }

    func load() -> BurnOrder? {
        guard let sealed = try? Data(contentsOf: file), let key = key(create: false),
              let box = try? ChaChaPoly.SealedBox(combined: sealed), let plain = try? ChaChaPoly.open(box, using: key) else { return nil }
        return try? JSONDecoder().decode(BurnOrder.self, from: plain)
    }

    /// Whether there is an order waiting (even one that can't be opened any more).
    var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    @discardableResult
    func save(_ order: BurnOrder) -> Bool {
        guard let key = key(create: true), let plain = try? JSONEncoder().encode(order),
              let sealed = try? ChaChaPoly.seal(plain, using: key).combined else { return false }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? sealed.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        // The wipe that makes this order is often followed by a restore from backup: this file holds signatures and
        // erase-only secrets, and has no business riding along into a backup of the device it was made to wipe.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = file
        try? url.setResourceValues(values)
        return true
    }

    /// Overwrites the file, removes it, and removes its key.
    func delete() {
        if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 { try? Data.random(size).write(to: file) }
        try? FileManager.default.removeItem(at: file)
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// How Burn ended on this phone.
enum BurnResult: Equatable {
    /// Everything is erased, on the server and the phone.
    case complete
    /// The phone is wiped; the rest on the server is being finished (the app keeps trying).
    case pending
    /// Only this device was wiped.
    case deviceOnly
}
