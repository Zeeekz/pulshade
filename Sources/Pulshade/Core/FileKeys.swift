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
    /// On a Mac, kept in the data protection Keychain, the one that honours "this device only": the file-based login
    /// Keychain ignores it, and goes along in a Migration Assistant move or a Time Machine restore. For the key that seals
    /// this device's own keys (`device.key`), which must never turn up on another Mac.
    private var dataProtection = false

    /// Named by the file's path inside the app's home, not the full path: iOS moves an app's whole folder
    /// to a new place when it's reinstalled or updated, and the name has to survive that.
    init(directory: URL, file: String) {
        var path = directory.standardizedFileURL.path + "/" + file
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path + "/"
        if path.hasPrefix(home) { path.removeFirst(home.count) }
        account = Data(SHA256.hash(data: Data(path.utf8)).prefix(16)).hex
        dataProtection = file == "device.key"
    }

    private init(account: String) {
        self.account = account
    }

    /// Every other file's keys in the Keychain. Builds before the name above used the full path, so after
    /// an iOS update a file's key sits under an old name; the sealed file finds it among these.
    func others() -> [FileKeys] {
        Self.accounts().filter { $0 != account }.map(FileKeys.init(account:))
    }

    /// Tests keep keys in memory, so they don't leave hundreds of items in the login Keychain. Read from parallel
    /// tests and written once by the test harness, so it is guarded; in a shipped build it is only ever read false.
    nonisolated(unsafe) private static var _inMemory = false
    private static let flagLock = NSLock()
    static var inMemory: Bool {
        get { flagLock.withLock { _inMemory } }
        set { flagLock.withLock { _inMemory = newValue } }
    }
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let lock = NSLock()

    /// The keys that may open the file, newest last. Empty if this file has never been sealed here.
    func load() -> [SymmetricKey] {
        guard let raw = Self.read(account, dataProtection: dataProtection), raw.count % 32 == 0 else { return [] }
        return stride(from: 0, to: raw.count, by: 32).map {
            SymmetricKey(data: raw[raw.startIndex + $0 ..< raw.startIndex + $0 + 32])
        }
    }

    /// Whether this file has ever been sealed with a Keychain key here. Once it has, an unsealed copy
    /// can only be an old one.
    var inUse: Bool { Self.read(account, dataProtection: dataProtection) != nil }

    func store(_ keys: [SymmetricKey]) throws {
        try Self.write(account, keys.reduce(Data()) { $0 + $1.bytes }, dataProtection: dataProtection)
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
        if dataProtection { SecItemDelete(Self.query(account, dataProtection: true) as CFDictionary) }
    }

    /// Every file key and the wrong-passcode count, for a fresh install that finds keys an earlier, deleted install left.
    static func forgetAll() {
        if inMemory { lock.withLock { memory.removeAll() }; return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrSynchronizable as String: false]
        SecItemDelete(query as CFDictionary)
        #if os(macOS)
        var protected = query
        protected[kSecUseDataProtectionKeychain as String] = true
        SecItemDelete(protected as CFDictionary)
        #endif
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

    private static func query(_ account: String, dataProtection: Bool = false) -> [String: Any] {
        var out: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service,
                                  kSecAttrAccount as String: account,
                                  kSecAttrSynchronizable as String: false]
        #if os(macOS)
        if dataProtection { out[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return out
    }

    /// iOS has only the data protection Keychain, so this is about the Mac.
    private static var macProtected: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
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

    /// `dataProtection`: looked for in the data protection Keychain first. One still in the login Keychain (made before, or
    /// on a Mac build that can't use the other) is moved over when it can be.
    private static func read(_ account: String, dataProtection: Bool) -> Data? {
        if inMemory { return lock.withLock { memory[account] } }
        guard dataProtection, macProtected else { return read(account, query: query(account)) }
        if let found = read(account, query: query(account, dataProtection: true)) { return found }
        guard let legacy = read(account, query: query(account)) else { return nil }
        if (try? add(account, legacy, query: query(account, dataProtection: true))) != nil {
            SecItemDelete(query(account) as CFDictionary)
        }
        return legacy
    }

    private static func read(_ account: String) -> Data? { read(account, dataProtection: false) }

    private static func read(_ account: String, query: [String: Any]) -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// `dataProtection`: into the data protection Keychain, and out of the login one. A Mac build without the entitlement
    /// it takes (errSecMissingEntitlement) keeps using the login Keychain, as before, rather than lose the key.
    private static func write(_ account: String, _ value: Data, dataProtection: Bool = false) throws {
        if inMemory { lock.withLock { memory[account] = value }; return }
        guard dataProtection, macProtected else { return try write(account, value, query: query(account)) }
        do {
            try write(account, value, query: query(account, dataProtection: true))
            SecItemDelete(query(account) as CFDictionary)
        } catch VaultError.keychain(errSecMissingEntitlement) {
            try write(account, value, query: query(account))
        }
    }

    private static func write(_ account: String, _ value: Data, query: [String: Any]) throws {
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        try add(account, value, query: query)
    }

    private static func add(_ account: String, _ value: Data, query: [String: Any]) throws {
        var add = query
        add[kSecValueData as String] = value
        // After first unlock, so locking Pulshade from the background (phone already locked) can still
        // rotate the key. Never synced or restored to another device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
}
