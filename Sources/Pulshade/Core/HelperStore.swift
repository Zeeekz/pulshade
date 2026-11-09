import Foundation
import Security

/// Where the app leaves `HelperBundle` for the notification helper, and where the helper remembers which envelopes
/// it has already confirmed. Keychain items in a group only the app and its helper share, readable after the
/// phone's first unlock since it was switched on (the helper runs while it's locked), kept on this device and never
/// synced or backed up. Nothing on the Mac, which has no helper.
enum HelperStore {
    private static let service = "app.pulshade.helper"
    private static let bundleAccount = "bundle"
    private static let confirmedAccount = "confirmed"
    /// How long a confirmed envelope is remembered: the relay keeps mail a week.
    static let memory: TimeInterval = 8 * 24 * 3600

    /// "<team>.app.pulshade.shared", filled in at build time in both Info.plists.
    private static var group: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PulshadeKeychainGroup") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    @discardableResult
    static func save(_ bundle: HelperBundle) -> Bool {
        guard let data = try? JSONEncoder().encode(bundle) else { return false }
        return write(data, account: bundleAccount)
    }

    static func load() -> HelperBundle? {
        read(account: bundleAccount).flatMap { try? JSONDecoder().decode(HelperBundle.self, from: $0) }
    }

    /// The envelopes already confirmed, by digest, with when.
    static func confirmed() -> [Data: Date] {
        guard let data = read(account: confirmedAccount),
              let list = try? JSONDecoder().decode([Data: Date].self, from: data) else { return [:] }
        return list
    }

    static func remember(_ digests: [Data], now: Date = Date()) {
        var list = confirmed().filter { now.timeIntervalSince($0.value) < memory }
        for d in digests { list[d] = now }
        // A long week of busy chats is still small; past this the oldest go.
        if list.count > 2_000 { list = Dictionary(uniqueKeysWithValues: list.sorted { $0.value > $1.value }.prefix(2_000).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(list) { write(data, account: confirmedAccount) }
    }

    /// Burn, Detach, or the feature turned off: nothing is left for the helper.
    static func clear() {
        delete(account: bundleAccount)
        delete(account: confirmedAccount)
    }

    // MARK: Keychain

    private static func base(_ account: String) -> [String: Any]? {
        #if os(iOS)
        guard let group else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
        #else
        return nil
        #endif
    }

    @discardableResult
    private static func write(_ data: Data, account: String) -> Bool {
        guard var query = base(account) else { return false }
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func read(account: String) -> Data? {
        guard var query = base(account) else { return nil }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func delete(account: String) {
        guard let query = base(account) else { return }
        SecItemDelete(query as CFDictionary)
    }
}
