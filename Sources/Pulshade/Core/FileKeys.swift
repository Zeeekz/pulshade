import Foundation
import CryptoKit
import Security

/// The outer key for one sealed file (`identity.lock`, `identity.bio`), kept in the Keychain and replaced
/// every time the file is rewritten. The file itself carries everything else it needs, the Secure Enclave
/// key included (wrapped so only this device can use it, and a wrapped key can't be revoked). So an old copy
/// left behind in the SSD's spare blocks would open again with the old passcode. Once its key is gone
/// from the Keychain, it can't.
///
/// The Keychain holds the current key, plus for a moment the next one: it's added before the file is
/// written and the old one dropped after, so a crash in between never leaves a file nothing opens.
struct FileKeys {
    private static let service = "app.pulshade.filekey"
    let account: String

    /// Named by the file's path inside the app's home, not the full path: iOS moves an app's whole folder
    /// to a new place when it's reinstalled or updated, and the name has to survive that.
    init(directory: URL, file: String) {
        var path = directory.standardizedFileURL.path + "/" + file
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        if path.hasPrefix(home) { path.removeFirst(home.count) }
        account = Data(SHA256.hash(data: Data(path.utf8)).prefix(16)).hex
    }

    private init(account: String) {
        self.account = account
    }

    /// Every other file's keys in the Keychain. Builds before the name above used the full path, so after
    /// an iOS update a file's key sits under an old name; the sealed file finds it among these.
    func others() -> [FileKeys] {
        Self.accounts().filter { $0 != account }.map(FileKeys.init(account:))
    }

    /// Tests keep keys in memory, so they don't leave hundreds of items in the login Keychain.
    nonisolated(unsafe) static var inMemory = false
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let lock = NSLock()

    /// The keys that may open the file, newest last. Empty if this file has never been sealed here.
    func load() -> [SymmetricKey] {
        guard let raw = Self.read(account), raw.count % 32 == 0 else { return [] }
        return stride(from: 0, to: raw.count, by: 32).map {
            SymmetricKey(data: raw[raw.startIndex + $0 ..< raw.startIndex + $0 + 32])
        }
    }

    /// Whether this file has ever been sealed with a Keychain key here. Once it has, an unsealed copy
    /// can only be an old one.
    var inUse: Bool { Self.read(account) != nil }

    func store(_ keys: [SymmetricKey]) throws {
        try Self.write(account, keys.reduce(Data()) { $0 + $1.bytes })
    }

    /// Replaces every key with a fresh one nothing was sealed with, so every copy of the file, old or
    /// current, stops opening. The item stays, so an unsealed copy from before is refused too.
    func revoke() {
        try? store([SymmetricKey(size: .bits256)])
    }

    /// Deletes the item outright, for Burn: nothing in the Keychain says Pulshade held an account here.
    /// Sealed copies stay closed, since their keys go with it.
    func forget() {
        if Self.inMemory { _ = Self.lock.withLock { Self.memory.removeValue(forKey: account) }; return }
        SecItemDelete(Self.query(account) as CFDictionary)
    }

    // MARK: Wrong-passcode count

    /// How many wrong passcodes in a row, kept in the Keychain so quitting and reopening doesn't start the
    /// waiting over. A number and nothing else; Burn and Detach delete it.
    private static let attemptsAccount = "failed-attempts"

    static func savedAttempts() -> Int {
        guard let raw = read(attemptsAccount), raw.count == 4 else { return 0 }
        return Int(raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
    }

    static func saveAttempts(_ count: Int) {
        if count <= 0 { forgetAttempts(); return }
        var value = UInt32(clamping: count).littleEndian
        try? write(attemptsAccount, Data(bytes: &value, count: 4))
    }

    static func forgetAttempts() {
        if inMemory { _ = lock.withLock { memory.removeValue(forKey: attemptsAccount) }; return }
        SecItemDelete(query(attemptsAccount) as CFDictionary)
    }

    // MARK: Keychain

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    private static func accounts() -> [String] {
        if inMemory { return lock.withLock { Array(memory.keys) } }
        // Attributes only: the Mac's Keychain won't return every item's data in one call.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private static func read(_ account: String) -> Data? {
        if inMemory { return lock.withLock { memory[account] } }
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ account: String, _ value: Data) throws {
        if inMemory { lock.withLock { memory[account] = value }; return }
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = value
        // After first unlock, so locking Pulshade from the background (phone already locked) can still
        // rotate the key. Never synced or restored to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
}
