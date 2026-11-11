import Foundation
import Security

/// Where the app leaves `HelperBundle` for the notification helper, where the helper remembers which envelopes it
/// has already confirmed, and the inbox it keeps short mail in until Pulshade reads it. Keychain items in a group only
/// the app and its helper share, readable after the phone's first unlock since it was switched on (the helper runs
/// while it's locked), kept on this device and never synced or backed up: iOS keeps them encrypted, and Burn and
/// Detach remove every one. Nothing on the Mac, which has no helper (tests there use memory instead).
enum HelperStore {
    private static let service = "app.pulshade.helper"
    private static let inboxService = "app.pulshade.inbox"
    private static let bundleAccount = "bundle"
    private static let confirmedAccount = "confirmed"
    /// How long a confirmed envelope is remembered: the relay keeps mail a week.
    static let memory: TimeInterval = 8 * 24 * 3600
    /// The most the inbox holds before the helper leaves new mail on the relay instead: a few days of busy chats
    /// while Pulshade isn't opened, a few MB at most.
    static let inboxLimit = 1_000

    /// "<team>.app.pulshade.shared", filled in at build time in both Info.plists.
    private static var group: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PulshadeKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: The bundle and what's been confirmed

    @discardableResult
    static func save(_ bundle: HelperBundle) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle) else { return false }
        return write(data, service: service, account: bundleAccount)
    }

    static func load() -> HelperBundle? {
        read(service: service, account: bundleAccount).flatMap { try? JSONDecoder().decode(HelperBundle.self, from: $0) }
    }

    /// The envelopes already confirmed, by digest, with when.
    static func confirmed() -> [Data: Date] {
        guard let data = read(service: service, account: confirmedAccount),
              let list = try? JSONDecoder().decode([Data: Date].self, from: data) else { return [:] }
        return list
    }

    static func remember(_ digests: [Data], now: Date = Date()) {
        var list = confirmed().filter { now.timeIntervalSince($0.value) < memory }
        for d in digests { list[d] = now }
        // A long week of busy chats is still small; past this the oldest go.
        if list.count > 2_000 { list = Dictionary(uniqueKeysWithValues: list.sorted { $0.value > $1.value }.prefix(2_000).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(list) { write(data, service: service, account: confirmedAccount) }
    }

    // MARK: The inbox

    /// An envelope the helper took off the relay, exactly as it came, with the mailbox it was in.
    struct InboxItem: Codable, Equatable {
        var receiveKey: Data
        var blob: Data
        /// When the relay took it in, if it said.
        var deposited: Date?
        /// When the helper collected it.
        var collected: Date
    }

    /// Keeps one envelope until Pulshade reads it. Only once this is true may it come off the relay.
    static func keep(_ item: InboxItem) -> Bool {
        guard let data = try? JSONEncoder().encode(item) else { return false }
        return write(data, service: inboxService, account: LockedDelivery.digest(of: item.blob).hexString)
    }

    /// Everything waiting, oldest first, each with the name to remove it by.
    static func inbox() -> [(name: String, item: InboxItem)] {
        readAll(service: inboxService)
            .compactMap { name, data in (try? JSONDecoder().decode(InboxItem.self, from: data)).map { (name, $0) } }
            .sorted { ($0.item.deposited ?? $0.item.collected) < ($1.item.deposited ?? $1.item.collected) }
    }

    static var inboxCount: Int { readAll(service: inboxService).count }

    static func remove(_ names: [String]) {
        for name in names { delete(service: inboxService, account: name) }
    }

    /// Burn, Detach, or a decoy: nothing is left for the helper, and nothing it kept. Pulshade reads what's in the
    /// inbox before turning the feature off, so nothing unread goes with it.
    static func clear() {
        delete(service: service, account: bundleAccount)
        delete(service: service, account: confirmedAccount)
        deleteAll(service: inboxService)
    }

    /// Stops the helper without losing mail it already took off the relay: the bundle and the confirmed digests
    /// go, but the inbox stays for Pulshade to read (housekeeping drains it whatever the setting). The relay has
    /// already been told those envelopes were collected, so deleting them here would lose them for good.
    static func clearDelivery() {
        delete(service: service, account: bundleAccount)
        delete(service: service, account: confirmedAccount)
    }

    // MARK: Keychain

    #if DEBUG && os(macOS)
    /// The Mac has no helper; its tests keep these in memory, by service and name.
    nonisolated(unsafe) private static var memoryItems: [String: [String: Data]] = [:]
    private static let memoryLock = NSLock()
    #endif

    private static func base(_ service: String, _ account: String?) -> [String: Any]? {
        #if os(iOS)
        guard let group else { return nil }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccessGroup as String: group]
        if let account { query[kSecAttrAccount as String] = account }
        return query
        #else
        return nil
        #endif
    }

    @discardableResult
    private static func write(_ data: Data, service: String, account: String) -> Bool {
        #if DEBUG && os(macOS)
        memoryLock.withLock { memoryItems[service, default: [:]][account] = data }
        return true
        #else
        guard var query = base(service, account) else { return false }
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        #endif
    }

    private static func read(service: String, account: String) -> Data? {
        #if DEBUG && os(macOS)
        return memoryLock.withLock { memoryItems[service]?[account] }
        #else
        guard var query = base(service, account) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
        #endif
    }

    private static func readAll(service: String) -> [(String, Data)] {
        #if DEBUG && os(macOS)
        return memoryLock.withLock { (memoryItems[service] ?? [:]).map { ($0.key, $0.value) } }
        #else
        guard var query = base(service, nil) else { return [] }
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row[kSecAttrAccount as String] as? String, let data = row[kSecValueData as String] as? Data else { return nil }
            return (name, data)
        }
        #endif
    }

    private static func delete(service: String, account: String) {
        #if DEBUG && os(macOS)
        _ = memoryLock.withLock { memoryItems[service]?.removeValue(forKey: account) }
        #else
        guard let query = base(service, account) else { return }
        SecItemDelete(query as CFDictionary)
        #endif
    }

    private static func deleteAll(service: String) {
        #if DEBUG && os(macOS)
        _ = memoryLock.withLock { memoryItems.removeValue(forKey: service) }
        #else
        guard let query = base(service, nil) else { return }
        SecItemDelete(query as CFDictionary)
        #endif
    }
}

extension Data {
    /// Lower-case hex, without needing the app's own helpers (the notification helper builds without them).
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
