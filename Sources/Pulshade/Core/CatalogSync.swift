import Foundation
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// The collectibles list and its pictures as they are kept between unlocks: what the relay handed out, so it is checked
/// again on the way in, exactly as when it was fetched.
struct StoredCatalog: Codable {
    var signed: CollectibleCatalog.Signed
    /// Pictures by SHA-256 hex.
    var art: [String: Data]
}

extension AppModel {
    /// Puts the list kept from last time into the library, checked again as if it had just been fetched. A copy that
    /// fails the check is dropped, and the next fetch brings a good one.
    func loadCatalog() {
        guard CollectibleLibrary.shared.catalog == nil, let raw = vault.loadCatalog(),
              let stored = try? JSONDecoder().decode(StoredCatalog.self, from: raw),
              let catalog = try? CollectibleCatalog.open(stored.signed, adminKey: Self.adminKey) else { return }
        CollectibleLibrary.shared.install(catalog, art: stored.art, by: self)
    }

    /// Asks the relay for the collectibles list. A newer one, signed by the admin key, is taken with every picture it
    /// names, all fetched at once whatever this account owns: fetching only the ones someone is seen wearing would tell
    /// the relay who was seen. An older one than this app already has is refused, so the relay can't take items back
    /// by replaying an old list. Nothing is changed until every picture has arrived and matches.
    /// `waiting`: one asked for now waits for a check already under way and then asks itself; the regular check skips.
    func refreshCatalog(waiting: Bool = true) async {
        while waiting, checkingCatalog, phase == .unlocked { try? await Task.sleep(for: .milliseconds(50)) }
        guard !checkingCatalog, phase == .unlocked, let client = client(nil, lane: "catalog") else { return }
        checkingCatalog = true
        defer { checkingCatalog = false }
        let library = CollectibleLibrary.shared
        let have = library.catalog
        do {
            // Missing a picture, it asks for the whole list again rather than hear "nothing new" and never get it.
            guard let signed = try await client.catalog(since: library.hasAllArt ? have?.version : nil) else { return }
            let catalog = try CollectibleCatalog.open(signed, adminKey: Self.adminKey)
            if let have {
                if catalog.version < have.version { return }
                // The same number is only taken as the same list: a second list under one number isn't swapped in.
                if catalog.version == have.version && (library.hasAllArt || catalog != have) { return }
            }
            var art: [String: Data] = [:]
            for item in catalog.items where art[item.art.sha256] == nil {
                if let held = library.artData(item) {
                    art[item.art.sha256] = held
                    continue
                }
                let data = try await client.catalogArt(item.art.sha256, bytes: item.art.bytes)
                try CollectibleCatalog.checkArt(data, against: item.art)
                art[item.art.sha256] = data
            }
            // Locked, or a newer list taken, while the pictures came.
            guard phase == .unlocked, (library.catalog?.version ?? 0) <= catalog.version else { return }
            library.install(catalog, art: art, by: self)
            // Saved here and now, not later in the background: a save that landed after a Burn would bring the file back.
            try? vault.saveCatalog(JSONEncoder().encode(StoredCatalog(signed: signed, art: art)))
            // Collectibles signed by the relay's key (hatched or gifted) of an item this app only now knows were left out
            // until it knew whether they can be passed on: ask again.
            nextCollectibleCheck = Date()
        } catch {
            nextCatalogCheck = min(nextCatalogCheck, Date().addingTimeInterval(5 * 60))
        }
    }
}
