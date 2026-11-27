import Foundation
import CryptoKit
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// Collectibles: the signed list, the copies each identity holds, and the pictures, kept in the sealed media pool.
///
/// Every picture comes from the relay (none are built into the app), checked against its hash in the list the
/// Pulshade Admin key signed, then sealed in the media pool like a received photo and wiped with it by Burn and Detach.
/// All of them are fetched, at random moments, when a new list arrives, so what's fetched says nothing about whose
/// collectibles you looked at.
///
/// Copies are held by each identity's collector key (`Identity.collectorKey`), never its signing key, and each identity
/// asks for them on its own connection and its own random schedule, so the relay can't tie copies to anyone it knows or
/// two identities to each other. Friends learn the collector key from a certificate in the encrypted profile.
extension AppModel {
    /// Collectibles shown at the top of a profile.
    static var showcaseLimit: Int { Showcase.limit }
    /// Copies kept for one identity, whatever the relay says.
    static let maxHeld = 1_000

    /// The list, if the one saved is Pulshade's. Opened (signature, then shape) once per version and kept.
    var collectibleList: CollectibleList? {
        guard let signed = data.collectibleList else { return nil }
        if let hit = Self.openedList, hit.manifest == signed.manifest { return hit.list }
        let list = signed.open(adminKey: Self.adminKey)
        Self.openedList = list.map { (signed.manifest, $0) }
        return list
    }

    nonisolated(unsafe) private static var openedList: (manifest: String, list: CollectibleList)?

    private var identities: [UUID?] { [nil] + data.personas.map(\.id) }

    private static func slot(_ persona: UUID?) -> String { persona?.uuidString ?? "main" }

    /// The copies `persona` holds that the relay really signed for it, rarest first, then by name and number.
    func collection(for persona: UUID?) -> [Collectible] {
        guard let me = me(persona), let list = collectibleList else { return [] }
        let key = me.collectorKey.publicKey.rawRepresentation
        return (data.collectibles ?? []).filter { $0.isGenuine(for: key, issuer: list.issuerKey) && list.item($0.item) != nil }
            .sorted { a, b in
                let (ia, ib) = (list.item(a.item)!, list.item(b.item)!)
                if ia.tier != ib.tier { return ia.tier > ib.tier }
                if ia.name != ib.name { return ia.name < ib.name }
                return a.serial < b.serial
            }
    }

    /// What `persona` shows on its profile, in the order chosen, from what it still holds.
    func showcase(for persona: UUID?) -> [Collectible] {
        let held = collection(for: persona)
        let chosen = profile(for: persona).showcase ?? []
        return chosen.compactMap { id in held.first { $0.id == id } }.prefix(Self.showcaseLimit).map { $0 }
    }

    /// The copy `persona` shows beside its name, if it still holds it.
    func nameBadge(for persona: UUID?) -> Collectible? {
        guard let id = profile(for: persona).nameBadge else { return nil }
        return collection(for: persona).first { $0.id == id }
    }

    /// What friends are sent with your profile: your showcase and name badge with the certificate, unless you hide your
    /// collection.
    func sharedShowcase(_ persona: UUID?) -> Showcase? {
        guard data.hideCollection != true, let me = me(persona) else { return nil }
        let shown = showcase(for: persona)
        let badge = nameBadge(for: persona)
        guard !shown.isEmpty || badge != nil else { return nil }
        return try? Showcase.make(signing: me.signingKey, collector: me.collectorKey, copies: shown, nameBadge: badge)
    }

    /// A contact's showcase as it can be shown: only copies the relay signed for the collector key their own key vouches for.
    func showcase(of contact: Contact) -> [Collectible] {
        guard let list = collectibleList, let showcase = contact.showcase else { return [] }
        return showcase.shown(for: contact.signingKey, issuer: list.issuerKey).filter { list.item($0.item) != nil }
    }

    /// The collectible a contact shows beside their name, checked the same way.
    func nameBadge(of contact: Contact) -> Collectible? {
        guard let list = collectibleList, let badge = contact.showcase?.badge(for: contact.signingKey, issuer: list.issuerKey),
              list.item(badge.item) != nil else { return nil }
        return badge
    }

    /// Picks the copy shown beside your name, or none.
    func setNameBadge(_ id: String?) {
        let held = Set(collection(for: activePersona).map(\.id))
        let kept = id.flatMap { held.contains($0) ? $0 : nil }
        guard profile(for: activePersona).nameBadge != kept else { return }
        updateProfile { $0.nameBadge = kept }
    }

    /// The code Pulshade Admin needs to give this identity a collectible: its collector key. Not the key contacts know.
    func collectorCode(for persona: UUID?) -> String? {
        me(persona)?.collectorKey.publicKey.rawRepresentation.base64EncodedString()
    }

    func setShowcase(_ ids: [String]) {
        let held = Set(collection(for: activePersona).map(\.id))
        let kept = Array(ids.filter(held.contains).prefix(Self.showcaseLimit))
        updateProfile { $0.showcase = kept.isEmpty ? nil : kept }
    }

    func setHideCollection(_ hide: Bool) {
        guard (data.hideCollection == true) != hide else { return }
        data.hideCollection = hide ? true : nil
        save()
        // Friends get the profile again, with the showcase or without it.
        for persona in identities { resendProfile(persona) }
    }

    // MARK: Asking the relay

    /// The oldest list version this build takes, so a relay can't hand a phone with no list yet an old signed one (an
    /// issuer key since retired, items since removed). Raise it when a newer list is published before a build.
    nonisolated static let minimumListVersion: UInt64 = 2

    /// Whether a signed list may replace the one kept: never older than `minimumListVersion` or the kept one, and a
    /// different list must have a higher version, so two lists signed with the same number can't be swapped back and forth.
    nonisolated static func acceptsList(version: UInt64, signed: CollectibleList.Signed, current: CollectibleList.Signed?,
                            currentVersion: UInt64?) -> Bool {
        guard version >= minimumListVersion else { return false }
        guard let current, let currentVersion else { return true }
        return version > currentVersion || (version == currentVersion && signed == current)
    }

    /// Asks for the list, if it changed. The same question from every app, with no account attached.
    func refreshCollectibleList() async {
        guard !checkingCollectibles, phase == .unlocked, let client = client(nil, lane: "collectibles-list") else { return }
        checkingCollectibles = true
        defer { checkingCollectibles = false }
        do {
            guard let (signed, tag) = try await client.collectibleList(etag: data.collectibleListTag), phase == .unlocked else { return }
            // A list that isn't Pulshade's, or would roll back the one kept (or the oldest this build trusts), is ignored.
            guard let list = signed.open(adminKey: Self.adminKey),
                  Self.acceptsList(version: list.version, signed: signed, current: data.collectibleList,
                                   currentVersion: collectibleList?.version) else { return }
            let changed = data.collectibleList != signed
            data.collectibleList = signed
            data.collectibleListTag = tag
            dropUnlistedPictures(list)
            save()
            if changed { prefetchPictures(list) }
        } catch {
            nextCollectibleCheck = min(nextCollectibleCheck, Date().addingTimeInterval(.random(in: 60...180)))
        }
    }

    /// Called every tick: each identity asks for its copies when its own random time comes.
    func collectiblesTick() {
        guard phase == .unlocked, collectibleList != nil else { return }
        let now = Date()
        for persona in identities {
            let slot = Self.slot(persona)
            guard let due = nextCopiesCheck[slot] else {
                // First time since unlocking: somewhere in the next few minutes, not all at once.
                nextCopiesCheck[slot] = now.addingTimeInterval(.random(in: 5...240))
                continue
            }
            guard now >= due, !askingCopies.contains(slot) else { continue }
            nextCopiesCheck[slot] = now.addingTimeInterval(.random(in: 10 * 60...25 * 60))
            Task { await refreshCopies(of: persona) }
        }
    }

    /// For the collection screen: the list if there's none yet, and the current identity's copies.
    func refreshCollectibles() async {
        if collectibleList == nil { await refreshCollectibleList() }
        await refreshCopies(of: activePersona)
    }

    private func collectorProof(_ label: String, about: Data? = nil, by me: Identity) -> (key: String, sig: String, ts: UInt64)? {
        let collector = me.collectorKey
        let ts = UInt64(RelayClock.now.timeIntervalSince1970)
        let message = Data(label.utf8) + (about ?? collector.publicKey.rawRepresentation) + withUnsafeBytes(of: ts.bigEndian) { Data($0) }
        guard let sig = try? collector.signature(for: message) else { return nil }
        return (collector.publicKey.rawRepresentation.base64EncodedString(), sig.base64EncodedString(), ts)
    }

    /// Asks for one identity's copies (which also collects anything an open drop has for it), on that identity's own
    /// collector connection (`collectorLane`), apart from its @handle's.
    func refreshCopies(of persona: UUID?) async {
        let slot = Self.slot(persona)
        guard phase == .unlocked, !askingCopies.contains(slot), let me = me(persona),
              let client = client(nil, lane: Self.collectorLane(persona)),
              let (k, sig, ts) = collectorProof("pulshade.collect.mine.v2", by: me) else { return }
        askingCopies.insert(slot)
        defer { askingCopies.remove(slot) }
        guard var answer = try? await client.collectibles(key: k, sig: sig, ts: ts) else { return }
        // A drop is waiting for this key: it gives only once the work tied to the key is done, so made-up keys can't
        // empty it cheaply. Done here, off the main thread, and only when a drop asks for it.
        if let bits = answer.dropBits {
            let work = await Task.detached(priority: .utility) { Work.proof(for: Work.dropBound(k), bits: bits) }.value
            if let again = try? await client.collectibles(key: k, sig: sig, ts: ts, dropWork: work) { answer = again }
        }
        guard phase == .unlocked,
              self.me(persona)?.collectorKey.publicKey.rawRepresentation == me.collectorKey.publicKey.rawRepresentation else { return }
        let key = me.collectorKey.publicKey.rawRepresentation
        // Kept only in shape; whether the relay signed each is checked when shown.
        let copies = answer.copies.prefix(Self.maxHeld * 2)
            .filter { $0.owner == key && CollectibleList.validID($0.item) && $0.serial > 0 && $0.sig.count == 64 }
            .map { Collectible(item: $0.item, serial: $0.serial, owner: $0.owner, sig: $0.sig) }
        let mine = Collectible.unique(Array(copies), limit: Self.maxHeld)
        let before = (data.collectibles ?? []).filter { $0.owner == key }
        guard Set(mine.map(\.id)) != Set(before.map(\.id)) || mine != before else { return }
        let others = (data.collectibles ?? []).filter { $0.owner != key }
        data.collectibles = others + mine
        if data.collectibles?.isEmpty == true { data.collectibles = nil }
        newCollectibles += mine.filter { c in !before.contains { $0.id == c.id } }.count
        // A copy that's gone (let go, burned, taken back) leaves the showcase too.
        let held = Set(mine.map(\.id))
        if let shown = profile(for: persona).showcase, shown.contains(where: { !held.contains($0) }) {
            updateProfile(of: persona) { $0.showcase = shown.filter(held.contains).nilIfEmpty }
        }
        if let badge = profile(for: persona).nameBadge, !held.contains(badge) {
            updateProfile(of: persona) { $0.nameBadge = nil }
        }
        save()
    }

    /// Lets one of your copies go for good: its number goes back into the draw after a while.
    func letGo(_ copy: Collectible) async -> Bool {
        guard let persona = identities.first(where: { me($0)?.collectorKey.publicKey.rawRepresentation == copy.owner }),
              let me = me(persona), let client = client(nil, lane: Self.collectorLane(persona)) else { return false }
        let about = Data(copy.item.utf8) + Data([0]) + withUnsafeBytes(of: copy.serial.bigEndian) { Data($0) }
        guard let (k, sig, ts) = collectorProof("pulshade.collect.release.v2", about: about, by: me),
              (try? await client.releaseCollectible(key: k, sig: sig, ts: ts, item: copy.item, serial: copy.serial)) != nil else { return false }
        data.collectibles?.removeAll { $0 == copy }
        if let shown = profile(for: persona).showcase, shown.contains(copy.id) {
            updateProfile(of: persona) { $0.showcase = shown.filter { $0 != copy.id }.nilIfEmpty }
        }
        if profile(for: persona).nameBadge == copy.id {
            updateProfile(of: persona) { $0.nameBadge = nil }
        }
        save()
        return true
    }

    // MARK: Pictures

    /// A picture of the list: from the media pool if fetched before, otherwise from the relay, checked against its
    /// hash and sealed in the pool. Nil when it can't be had now.
    func collectiblePicture(_ file: CollectibleList.File) async -> Data? {
        if let ref = data.collectiblePictures?[file.sha256], let plain = loadMedia(ref), CollectibleList.matches(plain, file) {
            return plain
        }
        if let running = fetchingPictures[file.sha256] { return await running.value }
        guard let client = client(nil, lane: "collectibles-list") else { return nil }
        let task = Task<Data?, Never> { try? await client.collectiblePicture(file) }
        fetchingPictures[file.sha256] = task
        let fetched = await task.value
        fetchingPictures[file.sha256] = nil
        // Locked, another account opened, or the list moved on meanwhile: not kept.
        guard let fetched, phase == .unlocked, CollectibleList.matches(fetched, file),
              collectibleList?.items.contains(where: { $0.video == file || $0.still == file }) == true else { return fetched }
        if data.collectiblePictures?[file.sha256] == nil, let ref = storeReceivedMedia(fetched) {
            data.collectiblePictures = (data.collectiblePictures ?? [:]).merging([file.sha256: ref]) { $1 }
            save()
        }
        return fetched
    }

    /// Fetches every picture of a new list, in a random order, a few seconds apart, so that fetching one says nothing
    /// about which collectible you were looking at.
    private func prefetchPictures(_ list: CollectibleList) {
        let files = list.items.flatMap { [$0.still, $0.video] }.filter { data.collectiblePictures?[$0.sha256] == nil }.shuffled()
        guard !files.isEmpty else { return }
        Task { [weak self] in
            for file in files {
                try? await Task.sleep(for: .seconds(.random(in: 2...12)))
                guard let self, self.phase == .unlocked else { return }
                _ = await self.collectiblePicture(file)
            }
        }
    }

    /// Pictures the list no longer names leave the pool at the next save (`releaseDroppedMedia`).
    private func dropUnlistedPictures(_ list: CollectibleList) {
        guard var pictures = data.collectiblePictures else { return }
        let named = Set(list.items.flatMap { [$0.video.sha256, $0.still.sha256] })
        pictures = pictures.filter { named.contains($0.key) }
        data.collectiblePictures = pictures.isEmpty ? nil : pictures
    }
}

private extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
