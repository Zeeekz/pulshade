import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication
import os
import CArgon2
#if canImport(Darwin)
import Darwin
#endif

enum VaultError: Error {
    case wrongPasscode, corrupt, missing, alreadyExists
    case keychain(OSStatus)
}

/// Everything Pulshade keeps lives in encrypted files in Application Support:
///  - `identity.lock`: three passcode slots. Each holds either a sealed identity, a panic marker,
///    or random filler, and all three look the same, so nobody can tell how many are real. A passcode is stretched
///    with Argon2id (64 MiB, memory-hard), then each slot's key mixes that with an answer this device's Secure Enclave
///    gives for that passcode and no other, so every single guess needs this device's chip: a copied file can't be
///    guessed at anywhere else, and neither can answers taken from the chip once. The whole file is sealed again with a
///    key from the Keychain, replaced on every rewrite (and every lock), so an old copy recovered from the disk opens
///    nowhere, not even here. It also keeps the lock screen's own settings (`LockSettings`). `identity.bio` is sealed
///    the same way.
///  - `data-*.vault`: one per identity, sealed with a key derived from that identity, plus decoy
///    files of random bytes so the count doesn't give anything away. All are padded to the same
///    sizes, and the folder is kept out of backups.
///  - `work`: an always-present folder where files on their way out (a panic's) are overwritten in the background
///    (`setAside`); anything left there is finished at the next launch.
struct Vault {
    static let slotCount = 3

    let directory: URL

    init(directory: URL) {
        self.directory = directory
        prepareDirectory()
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // A folder left by an older build, or created with a looser umask, is tightened on every open.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Backups would carry the sealed files somewhere they could be guessed at for ever.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
        // Always there, empty or not, so its being there says nothing (see `setAside`).
        try? FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
    }

    /// Where files on their way out are overwritten in the background (`setAside`).
    var workURL: URL { Self.workURL(in: directory) }
    static func workURL(in directory: URL) -> URL { directory.appendingPathComponent("work", isDirectory: true) }

    /// Moves a file or folder that is to be destroyed (its keys already gone) into the work folder under a random name,
    /// so it's gone from where it was at once, then overwrites and deletes it in the background. One the app was closed
    /// before finishing is finished at the next launch (`finishSetAside`). The name says nothing about what it was.
    /// Falls back to overwriting it here and now if it can't be moved.
    @discardableResult
    static func setAside(_ item: URL, in directory: URL) -> Bool {
        let work = workURL(in: directory)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let aside = work.appendingPathComponent(Data.random(16).hex)
        guard (try? FileManager.default.moveItem(at: item, to: aside)) != nil else {
            scrub(item: item)
            return false
        }
        Task.detached(priority: .utility) { scrub(item: aside) }
        return true
    }

    private func setAside(_ item: URL) { Self.setAside(item, in: directory) }

    /// Finishes whatever `setAside` (or, in builds before this one, a panic's `.media-gone-` folder) left part-way. At
    /// every launch, in the background.
    func finishSetAside() { Self.finishSetAside(in: directory) }

    static func finishSetAside(in directory: URL) {
        let files = FileManager.default
        var left = ((try? files.contentsOfDirectory(at: workURL(in: directory), includingPropertiesForKeys: nil)) ?? [])
        left += ((try? files.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(".media-gone-") }.map { directory.appendingPathComponent($0, isDirectory: true) }
        guard !left.isEmpty else { return }
        Task.detached(priority: .utility) { for url in left { scrub(item: url) } }
    }

    static var standardDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulshade", isDirectory: true)
    }

    static var standard: Vault { Vault(directory: standardDirectory) }

    private var lockURL: URL { directory.appendingPathComponent("identity.lock") }
    private var legacyDataURL: URL { directory.appendingPathComponent("data.vault") }
    private var biometricURL: URL { directory.appendingPathComponent("identity.bio") }
    private var lockKeys: FileKeys { FileKeys(directory: directory, file: "identity.lock") }
    private var biometricKeys: FileKeys { FileKeys(directory: directory, file: "identity.bio") }
    /// Seals the seed of this device's own keys (`DeviceKey`) inside the data file.
    private var deviceKeyKeys: FileKeys { FileKeys(directory: directory, file: "device.key") }
    /// The sealed collectibles list builds before this kept. Nothing writes or reads it any more; it's only removed.
    private var catalogKeys: FileKeys { FileKeys(directory: directory, file: "catalog.cache") }
    private var catalogURL: URL { directory.appendingPathComponent("catalog.cache") }

    var exists: Bool { FileManager.default.fileExists(atPath: lockURL.path) }

    private var installMarkerURL: URL { directory.appendingPathComponent("install.marker") }

    /// True once, on the first run of an install that has no vault at all: the app was deleted without a Burn (or
    /// Burned), and Keychain items, which iOS keeps when an app is deleted, may be left from it. The marker lives in
    /// the app's own folder, which deletion takes with it and the Keychain doesn't, so it is missing exactly then.
    /// An install that has anything in its folder besides the marker (any vault, old or new) never counts, so an
    /// update can't clear a live account's keys: it only gets the marker.
    func claimFreshInstall() -> Bool {
        let files = FileManager.default
        guard !files.fileExists(atPath: installMarkerURL.path) else { return false }
        let others = ((try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != installMarkerURL.lastPathComponent && $0.lastPathComponent != workURL.lastPathComponent }
        let empty = others.isEmpty && !exists
        guard files.createFile(atPath: installMarkerURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            // Couldn't leave the marker: clearing again on every launch could do harm later, so not this time.
            return false
        }
        return empty
    }

    /// What a passcode opened.
    enum Opened {
        case identity(Identity, slot: Int)
        /// The panic passcode: wipe the real identity, then carry on as this harmless one.
        case panic(Identity, slot: Int)
    }

    private struct Slot: Codable {
        var salt: Data
        /// Only for slots sealed before format 4 (PBKDF2). Later slots carry the same number, so every slot looks alike.
        var iterations: UInt32
        var sealed: Data
    }

    /// The Secure Enclave key of a lock file written before format 4, and the public half of a key it was paired with.
    /// Together they gave a device secret that didn't depend on the passcode. Kept only for slots that may still be sealed
    /// that way (`LockFile.older`).
    private struct DeviceBinding: Codable, Equatable {
        var enclaveKey: Data
        var ephemeral: Data
    }

    /// How a passcode is stretched (format 4): Argon2id over a salt shared by the whole file, once per try, whichever slot
    /// it opens. One run per try costs a guesser exactly what it costs the owner, and the time it takes is the same for
    /// every passcode.
    struct Stretch: Codable, Equatable {
        var salt: Data
        /// In KiB.
        var memory: UInt32
        var passes: UInt32
    }

    /// The settings the lock screen needs before any passcode is typed: which keypad to show, and after how many wrong
    /// guesses in a row the device is wiped. Kept in the lock file, so they're sealed under its Keychain key like the rest
    /// of it: not a preference anything else on the device can read or change, and gone with the file.
    struct LockSettings: Codable, Equatable {
        var style: String?
        /// 0 is off.
        var wipeAfter: Int?
    }

    private struct LockFile: Codable {
        /// 4 from the first format 4 slot on; 3 or less for a file not yet upgraded.
        var version = 3
        var slots: [Slot]
        /// Before format 4 only (see `DeviceBinding`).
        var device: DeviceBinding?
        /// Before format 4 only: slots that may have been sealed before `device`, tried without its secret too.
        var unbound: [Int]?
        /// Format 4: how the passcode is stretched. Nil in a file not yet upgraded.
        var stretch: Stretch?
        /// Format 4: this device's Secure Enclave key (a handle only its chip can use). Every slot's key needs the chip to
        /// work out an answer that depends on the passcode (`enclaveSecret`), so each guess needs this device. Nil where
        /// there's no Secure Enclave.
        var enclave: Data?
        /// Slots that may still be sealed the way an earlier form of this file sealed them: before format 4 (when
        /// `beforeFormat4`), or before `enclave` was added. They are tried that way too. Every slot but the first is listed,
        /// real or filler alike, and the list never shrinks when one is rewritten (that would say which held a passcode):
        /// the older way opens nothing in a slot sealed since.
        var older: [Int]?
        var beforeFormat4: Bool?
        /// Random, and new whenever the whole file is replaced (a new account, a panic), so a change made for the file
        /// before can never land in the new one.
        var generation: Data?
        var settings: LockSettings?
    }

    /// Version 1 held a single slot.
    private struct LegacyLockFile: Codable {
        var salt: Data
        var iterations: UInt32
        var sealedSeed: Data
    }

    /// A file sealed with its current Keychain key. Version 4 on.
    private struct SealedFile: Codable {
        var version = 4
        var sealed: Data
    }

    private enum Role: UInt8 { case identity = 1, panic = 2 }

    // MARK: Identity

    /// A fresh vault: the identity in slot 0, filler in the rest, bound to this device. Refuses to replace an
    /// existing one unless the caller says so, so a restore or a link can never quietly shred the account already
    /// on this device.
    ///
    /// `replacing` is only for bringing an older lock file up to date (`upgrade`) with the passcode of its first slot:
    /// that slot is sealed again in the newest form (format 4, bound to the Secure Enclave where there is one). Every
    /// other slot is kept as it is: a decoy or panic passcode may be in one of them, and this device can't tell (nor
    /// rewrite them without their passcodes). They are listed as possibly older (`LockFile.older`), so they still
    /// open, and no data file is touched.
    func create(_ identity: Identity, passcode: String, replacing: Bool = false, settings: LockSettings? = nil) throws {
        if replacing { return try upgrade(identity, passcode: passcode) }
        #if DEBUG
        if Self.oldFormatForTests { return try createBeforeFormat4(identity, passcode: passcode, settings: settings) }
        #endif
        // The stretching and the Secure Enclave take a while: done before taking the lock.
        let stretch = Self.freshStretch()
        let enclave = Self.makeEnclaveKey()
        let stretched = try Self.argon2id(passcode, stretch)
        let first = try Self.seal(.identity, identity.seed, stretched: stretched, enclave: enclave)
        try Self.mutation.withLock {
            guard !exists else { throw VaultError.alreadyExists }
            var slots = (0..<Self.slotCount).map { _ in Self.filler() }
            slots[0] = first
            var file = LockFile(version: 4, slots: slots, stretch: stretch, enclave: enclave, generation: .random(16))
            // A new account wipes after 10 wrong guesses unless something else was chosen.
            file.settings = settings ?? LockSettings(style: nil, wipeAfter: 10)
            if file.settings?.wipeAfter == nil { file.settings?.wipeAfter = 10 }
            try writeLock(file)
            rebalance(real: [identity])
        }
    }

    /// Whether the lock file is older than this build's form (`upgrade` brings it up to date with the first slot's
    /// passcode): stretched with PBKDF2, or not bound to a Secure Enclave this device now has.
    var needsUpgrade: Bool {
        guard let file = try? readLock() else { return false }
        return file.stretch == nil || (file.enclave == nil && Self.canBindToDevice)
    }

    /// Seals the first slot again in the newest form, keeping every other slot opening (see `create`).
    private func upgrade(_ identity: Identity, passcode: String) throws {
        // A file that's gone (a Burn got there first) is never made again from here.
        guard exists else { throw VaultError.missing }
        // Nothing safe to keep in a file that won't open: refuse rather than write over it.
        let before = try readLock()
        let stretch = before.stretch ?? Self.freshStretch()
        // Already bound: keep that key, or the other slots, sealed with its answers, would stop opening.
        let enclave = before.enclave ?? Self.makeEnclaveKey()
        // Already in this form, and the Secure Enclave won't make a key now: nothing would change.
        if before.stretch != nil, before.enclave == nil, enclave == nil { return }
        let stretched = try Self.argon2id(passcode, stretch)
        let first = try Self.seal(.identity, identity.seed, stretched: stretched, enclave: enclave)
        try Self.mutation.withLock {
            guard exists else { throw VaultError.missing }
            var file = try readLock()
            // Changed meanwhile (a panic, another upgrade): this is no longer the file to change.
            guard file.generation == before.generation, file.stretch == before.stretch, file.enclave == before.enclave,
                  file.device == before.device else { throw VaultError.corrupt }
            file.slots[0] = first
            if file.stretch == nil {
                // Slots 1 and 2 keep opening the old way (PBKDF2, with the old device secret where there was one) until
                // they're next set. `device` and `unbound` stay for them.
                file.beforeFormat4 = true
                file.older = Array(1..<Self.slotCount)
            } else if file.enclave == nil, enclave != nil {
                file.older = Array(Set(file.older ?? []).union(1..<Self.slotCount)).sorted()
            }
            file.version = 4
            file.stretch = stretch
            file.enclave = enclave
            if file.generation == nil { file.generation = .random(16) }
            try writeLock(file)
        }
    }

    /// Whether this device can bind a lock file to its Secure Enclave at all. Without one, a file stays unbound, and
    /// trying again on every unlock would only rewrite it for nothing.
    static var canBindToDevice: Bool {
        guard SecureEnclave.isAvailable else { return false }
        #if DEBUG
        if ProcessInfo.processInfo.environment["PULSHADE_NO_ENCLAVE"] != nil || bindingOffForTests { return false }
        #endif
        return true
    }

    #if DEBUG
    /// Tests only: lock files made while this is set aren't bound, as if made where there's no Secure Enclave.
    nonisolated(unsafe) static var bindingOffForTests = false
    /// Tests only: whether the Secure Enclave will make a key right now. It won't while this machine is locked (or the run has
    /// no login session), though it's there: a test that needs one skips then, as it does on a machine without one.
    static var enclaveMakesKeysNow: Bool { makeEnclaveKey() != nil }
    /// Tests only: new lock files are written as a build before format 4 wrote them (PBKDF2, the passcode-independent
    /// device secret), to test the upgrade.
    nonisolated(unsafe) static var oldFormatForTests = false
    /// Tests only: the real stretching cost even where tests keep keys in memory (`FileKeys.inMemory`), which otherwise
    /// use a light one so hundreds of test accounts don't take minutes.
    nonisolated(unsafe) static var fullStretchForTests = false
    /// Tests only: whether slot `index` opens with `passcode` the current way (Argon2id, with this file's Secure Enclave
    /// answer where it has one), not only an older way.
    func slotIsCurrentForm(_ index: Int, passcode: String) -> Bool {
        guard let file = try? readLock(), let stretch = file.stretch, file.slots.indices.contains(index),
              let stretched = try? Self.argon2id(passcode, stretch),
              let key = try? Self.slotKey(stretched: stretched, salt: file.slots[index].salt, enclave: file.enclave),
              let box = try? AES.GCM.SealedBox(combined: file.slots[index].sealed) else { return false }
        return (try? AES.GCM.open(box, using: key)) != nil
    }
    #endif

    /// Tries every slot, always all of them, so timing doesn't reveal which one matched.
    func unlock(passcode: String) throws -> Opened {
        try unlockKeepingStretch(passcode: passcode).opened
    }

    /// `unlock`, also giving back the stretched passcode, so a panic can seal the landing account without stretching it
    /// again (which made a panic unlock slower than any other).
    func unlockKeepingStretch(passcode: String) throws -> (opened: Opened, stretched: SymmetricKey?) {
        let file = try readLock()
        let stretched = try file.stretch.map { try Self.argon2id(passcode, $0) }
        let legacySecret = try file.device.map(Self.legacyDeviceSecret)
        let older = Set(file.older ?? [])
        let unbound = Set(file.unbound ?? [])
        var opened: Opened?
        for (index, slot) in file.slots.enumerated() {
            // A malformed salt (only possible in an editable, Keychain-less lock file) would make the KDF
            // trap; treat such a slot as unusable instead.
            guard !slot.salt.isEmpty else { continue }
            // Derive and decrypt every slot even after one matches: stopping early would let the timing (and
            // the number of decryptions) say which slot a passcode opened, defeating decoy/panic deniability.
            var keys: [SymmetricKey] = []
            if let stretched {
                keys.append(try Self.slotKey(stretched: stretched, salt: slot.salt, enclave: file.enclave))
                // Sealed before the file was bound to the Secure Enclave.
                if older.contains(index), file.enclave != nil {
                    keys.append(try Self.slotKey(stretched: stretched, salt: slot.salt, enclave: nil))
                }
            }
            if file.stretch == nil || (older.contains(index) && file.beforeFormat4 == true) {
                let old = Self.stretch(passcode, salt: slot.salt, iterations: Self.safeIterations(slot.iterations))
                keys.append(Self.legacySlotKey(stretched: old, salt: slot.salt, device: legacySecret))
                // A slot sealed before the old binding opens without its secret.
                if legacySecret != nil, unbound.contains(index) { keys.append(old) }
            }
            let box = try? AES.GCM.SealedBox(combined: slot.sealed)
            var plain: Data?
            // Every key is tried, even after one opens, so a listed slot always does the same work whatever it holds.
            for key in keys {
                if let box, let opened = try? AES.GCM.open(box, using: key), plain == nil { plain = opened }
            }
            guard opened == nil, let plain else { continue }
            if plain.count == 32 {
                // Written by version 1: a bare seed.
                opened = .identity(try Identity(seed: plain), slot: index)
            } else if plain.count == 33, let role = Role(rawValue: plain[plain.startIndex]) {
                let identity = try Identity(seed: Data(plain.dropFirst()))
                opened = role == .panic ? .panic(identity, slot: index) : .identity(identity, slot: index)
            }
        }
        guard let opened else { throw VaultError.wrongPasscode }
        return (opened, stretched)
    }

    /// The stretch count an old slot asks for, clamped so an editable (Keychain-less) lock file can neither
    /// lower the work below what builds before format 4 used nor make unlocking take forever.
    private static func safeIterations(_ stored: UInt32) -> UInt32 {
        min(max(stored, iterations), 5_000_000)
    }

    /// Whether any slot already opens with this passcode.
    func passcodeInUse(_ passcode: String) -> Bool {
        (try? unlock(passcode: passcode)) != nil
    }

    /// Whether the lock file is bound to this device's Secure Enclave in the current form.
    var isDeviceBound: Bool { (try? readLock())?.enclave != nil }

    /// Whether the lock file is in the current form (format 4: Argon2id).
    var isCurrentFormat: Bool { (try? readLock())?.stretch != nil }

    /// Puts an identity (or a panic landing identity) behind a passcode in a slot.
    func setSlot(_ index: Int, identity: Identity, passcode: String, panic: Bool = false) throws {
        let role: Role = panic ? .panic : .identity
        // Stretching the passcode takes a while: it's done before taking the lock, so locking the app meanwhile
        // isn't held up, and done again in the rare case the file was upgraded in between.
        let before = try readLock()
        var sealed = try seal(role, identity.seed, passcode: passcode, for: before)
        try Self.mutation.withLock {
            var file = try readLock()
            if file.stretch != before.stretch || file.enclave != before.enclave || file.device != before.device
                || file.generation != before.generation {
                // Upgraded in the meantime: sealed again in the new form. Any other change is a panic having replaced the
                // whole file: a passcode set for the file before it must not land in it.
                let upgraded = (before.stretch == nil || before.stretch == file.stretch)
                    && (before.enclave == nil || before.enclave == file.enclave)
                    && (before.generation == nil || before.generation == file.generation)
                    && file.device == before.device
                guard upgraded else { throw VaultError.corrupt }
                sealed = try seal(role, identity.seed, passcode: passcode, for: file)
            }
            file.slots[index] = sealed
            try writeLock(file)
        }
    }

    /// A slot sealed the way this file seals new ones: format 4, or the old way in a file not yet upgraded.
    private func seal(_ role: Role, _ seed: Data, passcode: String, for file: LockFile) throws -> Slot {
        if let stretch = file.stretch {
            return try Self.seal(role, seed, stretched: try Self.argon2id(passcode, stretch), enclave: file.enclave)
        }
        return try Self.legacySeal(role, seed, passcode: passcode, device: try file.device.map(Self.legacyDeviceSecret))
    }

    /// The panic passcode was used: the landing identity becomes an ordinary account in the first slot,
    /// under a brand-new device key, every other slot becomes filler, and every other data file is
    /// destroyed along with Touch ID. `stretched` is the passcode as `unlockKeepingStretch` stretched it, if at hand.
    func panic(keeping landing: Identity, slot: Int, passcode: String, stretched: SymmetricKey? = nil) throws {
        let before = try readLock()
        // The same salt and cost as before, so the stretch the unlock already did seals the landing account too, and a
        // panic unlock takes no longer than any other.
        let stretch = before.stretch ?? Self.freshStretch()
        let key = try stretched.flatMap { before.stretch != nil ? $0 : nil } ?? Self.argon2id(passcode, stretch)
        let enclave = Self.makeEnclaveKey()
        let first = try Self.seal(.identity, landing.seed, stretched: key, enclave: enclave)
        try Self.mutation.withLock {
            var slots = (0..<Self.slotCount).map { _ in Self.filler() }
            slots[0] = first
            let settings = (try? readLock())?.settings ?? before.settings
            try writeLock(LockFile(version: 4, slots: slots, stretch: stretch, enclave: enclave, generation: .random(16),
                                   settings: settings))
            let keep = dataURL(for: landing).lastPathComponent
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            // Their Keychain keys go now, so nothing in them opens again; the bytes are overwritten in the background, from
            // the work folder (`setAside`), so the time this takes doesn't depend on how much the real account held.
            for url in files where url.pathExtension == "vault" && url.lastPathComponent != keep {
                dataKeys(url).forget()
                setAside(url)
            }
            disableBiometrics()
            rebalance(real: [landing])
            // The landing account is always new and empty, so every media file is the destroyed accounts' (or their
            // filler). Left behind, a pool of hundreds of files beside an account with nothing in it would say there
            // was another account; its keys are gone with the vault files above, and the files go too. In the background:
            // overwriting a big pool took seconds, and a panic passcode that opened slower than the real one gave it away.
            MediaPool(directory: directory).wipeSoon()
        }
    }

    /// Turns a slot back into filler and destroys the data it pointed at.
    func clearSlot(_ index: Int, identity: Identity?) throws {
        try Self.mutation.withLock {
            var file = try readLock()
            file.slots[index] = Self.filler()
            try writeLock(file)
            if let identity { shredData(dataURL(for: identity)) }
        }
    }

    /// Rewrites the lock file under a new Keychain key, so every earlier copy stops opening.
    func rotate() {
        Self.mutation.withLock {
            guard let file = try? readLock() else { return }
            try? writeLock(file)
        }
    }

    // MARK: Lock settings

    /// The lock screen's settings, or nil where there's no lock file (or it can't be read). Read often (every redraw of
    /// the lock screen), so kept in memory once read; any rewrite of the file updates it.
    var lockSettings: LockSettings? {
        let path = lockURL.standardizedFileURL.path
        // Gone with the file (a wipe, a Burn): nothing is kept of it.
        guard exists else {
            Self.settingsCache.withLock { $0[path] = nil }
            return nil
        }
        if let known = Self.settingsCache.withLock({ $0[path] }) { return known }
        guard let file = try? readLock() else { return nil }
        let settings = file.settings ?? LockSettings()
        Self.settingsCache.withLock { $0[path] = settings }
        return settings
    }

    /// Changes the lock screen's settings in the lock file. Fails where there's none (nothing to keep them in).
    func updateLockSettings(_ change: (inout LockSettings) -> Void) throws {
        try Self.mutation.withLock {
            var file = try readLock()
            var settings = file.settings ?? LockSettings()
            change(&settings)
            guard settings != file.settings else { return }
            file.settings = settings
            try writeLock(file)
        }
    }

    private static let settingsCache = OSAllocatedUnfairLock<[String: LockSettings]>(initialState: [:])

    /// Every change to the lock file and the Face ID file reads it, changes it and writes it back, with the Keychain's
    /// list of keys for it: two at once (a passcode set in the background while locking rotates the key) would undo
    /// each other, losing the passcode or leaving the file sealed under a key the Keychain has dropped. They take turns.
    private static let mutation = NSRecursiveLock()

    private func readLock() throws -> LockFile {
        let raw = try readSealed(lockURL, keys: lockKeys)
        if var file = try? JSONDecoder().decode(LockFile.self, from: raw), file.slots.count == Self.slotCount {
            let valid = (0..<Self.slotCount)
            file.unbound = file.unbound?.filter { valid.contains($0) }
            file.older = file.older?.filter { valid.contains($0) }
            if let stretch = file.stretch { file.stretch = Self.safeStretch(stretch) }
            return file
        }
        guard let old = try? JSONDecoder().decode(LegacyLockFile.self, from: raw) else { throw VaultError.corrupt }
        return LockFile(version: 1, slots: [Slot(salt: old.salt, iterations: old.iterations, sealed: old.sealedSeed)]
            + (1..<Self.slotCount).map { _ in Self.filler() })
    }

    private func writeLock(_ file: LockFile) throws {
        var file = file
        // Only listed with a binding: without one every old slot opens without a device secret anyway.
        if file.device == nil || (file.unbound ?? []).isEmpty { file.unbound = nil }
        if (file.older ?? []).isEmpty { file.older = nil; file.beforeFormat4 = nil }
        // The old binding goes once no slot can need it.
        if file.stretch != nil, file.beforeFormat4 != true { file.device = nil; file.unbound = nil }
        file.unbound = file.unbound.map { Array(Set($0)).sorted() }
        file.version = file.stretch == nil ? 3 : 4
        // Padded with spaces (which JSON ignores) to a whole kilobyte, so the file's size doesn't say which keypad or how
        // many wrong guesses were chosen.
        var plain = try Self.encoder.encode(file)
        plain.append(Data(repeating: 0x20, count: (1024 - plain.count % 1024) % 1024))
        try writeSealed(plain, to: lockURL, keys: lockKeys)
        let path = lockURL.standardizedFileURL.path, settings = file.settings ?? LockSettings()
        Self.settingsCache.withLock { $0[path] = settings }
    }

    /// No slash escaping, so a file is the same size whatever the random bytes are.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    // MARK: Keychain seal

    /// Seals a file under a brand-new Keychain key. The new key is added before the file is written and
    /// the old one dropped after, so whatever is on disk always has its key.
    private func writeSealed(_ plain: Data, to url: URL, keys: FileKeys) throws {
        Self.mutation.lock()
        defer { Self.mutation.unlock() }
        let old = keys.load()
        let fresh = SymmetricKey(size: .bits256)
        do {
            try keys.store(old + [fresh])
        } catch {
            // Never write a lock file without its Keychain seal. An unsealed copy is exactly what this key exists
            // to stop, and failing here is better than quietly weakening every copy on the disk.
            throw error
        }
        let sealed = try AES.GCM.seal(plain, using: fresh).combined!
        try write(Self.encoder.encode(SealedFile(sealed: sealed)), to: url)
        try? keys.store([fresh])
    }

    private func readSealed(_ url: URL, keys: FileKeys) throws -> Data {
        guard let raw = try? Data(contentsOf: url) else { throw VaultError.missing }
        guard let file = try? JSONDecoder().decode(SealedFile.self, from: raw) else {
            // Written before files were sealed. Once this one has been, a copy like this can only be old.
            guard !keys.inUse else { throw VaultError.corrupt }
            return raw
        }
        guard let box = try? AES.GCM.SealedBox(combined: file.sealed) else { throw VaultError.corrupt }
        for key in keys.load().reversed() {
            if let plain = try? AES.GCM.open(box, using: key) { return plain }
        }
        // Sealed under an older name for this file (iOS moved the app's folder): adopt that key, drop the old item.
        Self.mutation.lock()
        defer { Self.mutation.unlock() }
        for stray in keys.others() {
            for key in stray.load() {
                guard let plain = try? AES.GCM.open(box, using: key) else { continue }
                try keys.store([key])
                stray.forget()
                return plain
            }
        }
        throw VaultError.corrupt
    }

    // MARK: Passcode to key (format 4)

    /// Argon2id's cost. 64 MiB and 3 passes (RFC 9106's second recommended setting, on one lane): about 0.1 s on an Apple
    /// silicon computer and a few tenths of a second on the oldest iPhone this build runs on.
    static let standardMemory: UInt32 = 65_536
    static let standardPasses: UInt32 = 3
    /// The least a lock file may ask for, so an editable (Keychain-less) copy can't lower the work. It never rises with
    /// `standardMemory`: files made with today's cost must keep opening if a later build asks for more.
    private static let floorMemory: UInt32 = 65_536
    private static let floorPasses: UInt32 = 3
    /// And the most, so a file can't make unlocking take forever or more memory than a phone has.
    private static let ceilingMemory: UInt32 = 1_048_576
    private static let ceilingPasses: UInt32 = 16

    /// A new file's settings.
    private static func freshStretch() -> Stretch {
        #if DEBUG
        if lightStretch { return Stretch(salt: .random(16), memory: 64, passes: 1) }
        #endif
        return Stretch(salt: .random(16), memory: standardMemory, passes: standardPasses)
    }

    static func safeStretch(_ stretch: Stretch) -> Stretch {
        var floor = (floorMemory, floorPasses)
        #if DEBUG
        if lightStretch { floor = (8, 1) }
        #endif
        return Stretch(salt: stretch.salt, memory: min(max(stretch.memory, floor.0), ceilingMemory),
                       passes: min(max(stretch.passes, floor.1), ceilingPasses))
    }

    #if DEBUG
    private static var lightStretch: Bool { FileKeys.inMemory && !fullStretchForTests }
    #endif

    /// Argon2id (version 1.3, one lane) of the passcode, 32 bytes. Throws only if the memory can't be had.
    static func argon2id(_ passcode: String, _ stretch: Stretch) throws -> SymmetricKey {
        guard stretch.salt.count >= 8 else { throw VaultError.corrupt }
        var password = Array(passcode.utf8)
        var out = [UInt8](repeating: 0, count: 32)
        // The stretched bytes are copied into the key below; neither buffer is left in memory.
        defer {
            _ = memset_s(&password, password.count, 0, password.count)
            _ = memset_s(&out, out.count, 0, out.count)
        }
        let status = stretch.salt.withUnsafeBytes { salt in
            argon2id_hash_raw(stretch.passes, stretch.memory, 1, password, password.count,
                              salt.baseAddress, salt.count, &out, out.count)
        }
        guard status == ARGON2_OK.rawValue else { throw VaultError.corrupt }
        return SymmetricKey(data: out)
    }

    /// A format 4 slot: the role and the seed, under a key from the stretched passcode and this device's chip.
    private static func seal(_ role: Role, _ seed: Data, stretched: SymmetricKey, enclave: Data?) throws -> Slot {
        let salt = Data.random(16)
        let key = try slotKey(stretched: stretched, salt: salt, enclave: enclave)
        let sealed = try AES.GCM.seal(Data([role.rawValue]) + seed, using: key).combined!
        return Slot(salt: salt, iterations: iterations, sealed: sealed)
    }

    /// The stretched passcode mixed with the Secure Enclave's answer for it, when there's an enclave key.
    private static func slotKey(stretched: SymmetricKey, salt: Data, enclave: Data?) throws -> SymmetricKey {
        var material = stretched.bytes
        if let enclave { material += try enclaveSecret(enclave, stretched: stretched, salt: salt).bytes }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt,
                                      info: Data("pulshade.slot.v4".utf8), outputByteCount: 32)
    }

    /// The chip's answer for one passcode and one slot: its private key times a point on P-256 made from the stretched
    /// passcode, whose discrete logarithm nobody knows (`passcodePoint`). Working out the answer for one passcode needs the
    /// enclave key, which never leaves the chip, and an answer got for one passcode says nothing about any other (the
    /// computational Diffie-Hellman problem): someone who once had code running on this device can't take the answers
    /// away and guess offline. Every guess needs this device's chip.
    private static func enclaveSecret(_ enclave: Data, stretched: SymmetricKey, salt: Data) throws -> SymmetricKey {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: enclave)
        let shared = try key.sharedSecretFromKeyAgreement(with: try passcodePoint(stretched, salt: salt))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: Data("pulshade.slot.enclave.v4".utf8),
                                              outputByteCount: 32)
    }

    /// A point on P-256 from the stretched passcode and a slot's salt, by trying candidate x coordinates until one is on
    /// the curve (about half are). Every candidate is always tried, so the time taken doesn't depend on the passcode.
    static func passcodePoint(_ stretched: SymmetricKey, salt: Data) throws -> P256.KeyAgreement.PublicKey {
        var found: P256.KeyAgreement.PublicKey?
        for counter in 0..<UInt8(64) {
            let x = HMAC<SHA256>.authenticationCode(for: Data("pulshade.slot.point.v4".utf8) + salt + [counter], using: stretched)
            let point = try? P256.KeyAgreement.PublicKey(compressedRepresentation: Data([0x02]) + Data(x))
            if found == nil { found = point }
        }
        guard let found else { throw VaultError.corrupt }
        return found
    }

    /// A new Secure Enclave key for this vault's slots, made so only this device's chip can use it, and only while the
    /// device is unlocked. Nil where there's no Secure Enclave (the Simulator, older machines), when it won't make one right
    /// now, and when tests ask for none.
    private static func makeEnclaveKey() -> Data? {
        guard canBindToDevice else { return nil }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage], &error),
              let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access) else { return nil }
        return enclave.dataRepresentation
    }

    // MARK: Before format 4

    private static let iterations: UInt32 = 600_000

    private static func legacySeal(_ role: Role, _ seed: Data, passcode: String, device: SymmetricKey?) throws -> Slot {
        let salt = Data.random(16)
        let key = legacySlotKey(stretched: stretch(passcode, salt: salt, iterations: iterations), salt: salt, device: device)
        let sealed = try AES.GCM.seal(Data([role.rawValue]) + seed, using: key).combined!
        return Slot(salt: salt, iterations: iterations, sealed: sealed)
    }

    private static func legacySlotKey(stretched: SymmetricKey, salt: Data, device: SymmetricKey?) -> SymmetricKey {
        guard let device else { return stretched }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: stretched.bytes + device.bytes), salt: salt,
                                      info: Data("pulshade.slot.v3".utf8), outputByteCount: 32)
    }

    /// The old device secret: the same whatever the passcode, which is why format 4 replaced it.
    private static func legacyDeviceSecret(_ binding: DeviceBinding) throws -> SymmetricKey {
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: binding.enclaveKey)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: binding.ephemeral)
        return try enclave.sharedSecretFromKeyAgreement(with: ephemeral)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("pulshade.device".utf8), outputByteCount: 32)
    }

    #if DEBUG
    /// Tests only: a lock file as a build before format 4 made it, bound with the old device secret where it can be.
    private func createBeforeFormat4(_ identity: Identity, passcode: String, settings: LockSettings?) throws {
        var device: DeviceBinding?
        if let enclave = Self.makeEnclaveKey() {
            device = DeviceBinding(enclaveKey: enclave, ephemeral: P256.KeyAgreement.PrivateKey().publicKey.x963Representation)
        }
        let first = try Self.legacySeal(.identity, identity.seed, passcode: passcode, device: try device.map(Self.legacyDeviceSecret))
        try Self.mutation.withLock {
            guard !exists else { throw VaultError.alreadyExists }
            var slots = (0..<Self.slotCount).map { _ in Self.filler() }
            slots[0] = first
            try writeLock(LockFile(version: 3, slots: slots, device: device, settings: settings))
            rebalance(real: [identity])
        }
    }

    #endif

    /// Random bytes the same shape as a real slot.
    private static func filler() -> Slot {
        Slot(salt: .random(16), iterations: iterations, sealed: .random(12 + 33 + 16))
    }

    // MARK: Touch ID

    /// A second sealed copy of the seed whose key only the Secure Enclave can produce, and only
    /// after Touch ID. The enclave key never leaves the chip; this file holds an encrypted handle to it.
    private struct BiometricFile: Codable {
        var enclaveKey: Data
        var ephemeral: Data
        var sealedSeed: Data
    }

    var hasBiometrics: Bool { FileManager.default.fileExists(atPath: biometricURL.path) }

    /// "Face ID" or "Touch ID", whichever this iPhone has.
    static var biometryName: String { LAContext().biometryType == .faceID ? "Face ID" : "Touch ID" }
    static var biometrySymbol: String { LAContext().biometryType == .faceID ? "faceid" : "touchid" }

    static var biometricsAvailable: Bool {
        SecureEnclave.isAvailable && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    /// `slot` travels sealed with the seed, so Face ID opens the identity it was turned on in, as the same slot.
    func enableBiometrics(for identity: Identity, slot: Int = 0) throws {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage, .biometryCurrentSet], &error) else {
            throw VaultError.corrupt
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let key = Self.biometricKey(try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey))
        let sealed = try AES.GCM.seal(Data([UInt8(slot)]) + identity.seed, using: key).combined!
        let file = BiometricFile(enclaveKey: enclave.dataRepresentation,
                                 ephemeral: ephemeral.publicKey.x963Representation, sealedSeed: sealed)
        try writeSealed(JSONEncoder().encode(file), to: biometricURL, keys: biometricKeys)
    }

    /// Revokes the file's Keychain key as well, so a copy of it left on the disk never answers a fingerprint.
    func disableBiometrics() {
        Self.mutation.withLock {
            if hasBiometrics || biometricKeys.inUse { biometricKeys.revoke() }
            shred(biometricURL)
        }
    }

    /// Shows the Touch ID prompt. Blocks until the person answers, so call it off the main thread.
    func unlockWithBiometrics(reason: String) throws -> (identity: Identity, slot: Int) {
        guard let raw = try? readSealed(biometricURL, keys: biometricKeys),
              let file = try? JSONDecoder().decode(BiometricFile.self, from: raw) else { throw VaultError.missing }
        let context = LAContext()
        context.localizedReason = reason
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: file.enclaveKey,
                                                                     authenticationContext: context)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: file.ephemeral)
        let key = Self.biometricKey(try enclave.sharedSecretFromKeyAgreement(with: ephemeral))
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: file.sealedSeed), using: key)
        // Older files held the bare seed of the main identity.
        if plain.count == 32 { return (try Identity(seed: plain), 0) }
        guard plain.count == 33 else { throw VaultError.corrupt }
        return (try Identity(seed: Data(plain.dropFirst())), Int(plain[plain.startIndex]))
    }

    private static func biometricKey(_ secret: SharedSecret) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("pulshade.biometric".utf8),
                                       outputByteCount: 32)
    }

    // MARK: Device keys

    /// Seals the seed of this device's own keys with a key kept in this device's Keychain only (never synced, never in
    /// a backup), made the first time it's needed. A copy of the data file, even with the recovery code, can't open it
    /// anywhere else, so the device's keys can't be taken along with the account's.
    func sealDeviceSeed(_ seed: Data) throws -> Data {
        let key: SymmetricKey
        if let held = deviceKeyKeys.load().last {
            key = held
        } else {
            key = SymmetricKey(size: .bits256)
            try deviceKeyKeys.store([key])
        }
        return try AES.GCM.seal(seed, using: key, authenticating: Data("pulshade.device.seed.v1".utf8)).combined!
    }

    /// The seed, or nil where this device's Keychain has no key that opens it (the data file came from somewhere else,
    /// or the key went with a wipe).
    func openDeviceSeed(_ sealed: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        for key in deviceKeyKeys.load().reversed() {
            if let seed = try? AES.GCM.open(box, using: key, authenticating: Data("pulshade.device.seed.v1".utf8)),
               seed.count == 32 { return seed }
        }
        return nil
    }

    // MARK: Left by older builds

    /// Shreds the collectibles list an older build kept, and forgets its key, so nothing of the removed feature stays
    /// on the device. Burn and Detach would wipe it too; this doesn't wait for them.
    func dropOldCatalog() {
        Self.mutation.lock()
        defer { Self.mutation.unlock() }
        guard catalogKeys.inUse || FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        shred(catalogURL)
        catalogKeys.forget()
    }

    // MARK: Data

    /// Each identity's data file is named from its storage key, so names reveal nothing.
    private func dataURL(for identity: Identity) -> URL {
        let name = Data(SHA256.hash(data: identity.storageKey.bytes + Data("pulshade.file".utf8)).prefix(12)).hex
        return directory.appendingPathComponent("data-\(name).vault")
    }

    // A data file is sealed with a key made from two: the identity's storage key (which needs the passcode) and a key
    // kept in the Keychain (`dataKeys`) that is replaced on every save. Delete a message or a photo, and the next save
    // replaces the Keychain key, so an older copy of the file left in the disk's free space or a snapshot, still holding
    // what was deleted (a photo's own key included), no longer opens, even with the passcode. Filler files have
    // Keychain keys too, rotated with them, so the Keychain doesn't say which files are real.

    /// The Keychain key for one data file, named by the file.
    private func dataKeys(_ url: URL) -> FileKeys { FileKeys(directory: directory, file: url.lastPathComponent) }

    /// The key a data file is sealed with: the identity's storage key bound to the Keychain key.
    private static func dataKey(_ identity: Identity, _ wrap: SymmetricKey) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: identity.storageKey, salt: wrap.withUnsafeBytes { Data($0) },
                               info: Data("pulshade.data.wrap.v1".utf8), outputByteCount: 32)
    }

    /// Opens a data file's bytes: with each Keychain key it has (newest first); written before data files had one, with
    /// the storage key alone, but only while no Keychain key was ever made for it (after that, such a copy can only be
    /// an old one); or with a key left under an older name for the file (iOS moved the app's folder).
    private func openData(_ raw: Data, identity: Identity, url: URL) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: raw)
        let keys = dataKeys(url)
        for wrap in keys.load().reversed() {
            if let plain = try? AES.GCM.open(box, using: Self.dataKey(identity, wrap)) { return plain }
        }
        // On macOS (the test build), a key left in the other Keychain by a build that could (or couldn't) use the data protection one.
        for wrap in keys.loadEverywhere().reversed() {
            guard let plain = try? AES.GCM.open(box, using: Self.dataKey(identity, wrap)) else { continue }
            try? keys.store([wrap])
            return plain
        }
        if !keys.inUse { return try AES.GCM.open(box, using: identity.storageKey) }
        // A stray key that opens it was this file's under its old name. Another file's key is never taken or removed.
        let mine = Set(knownKeyAccounts())
        for stray in keys.others() where !mine.contains(stray.account) {
            for wrap in stray.load() {
                guard let plain = try? AES.GCM.open(box, using: Self.dataKey(identity, wrap)) else { continue }
                try keys.store([wrap])
                stray.forget()
                return plain
            }
        }
        throw VaultError.corrupt
    }

    /// The Keychain accounts of every file in the folder that has one, so a key that belongs to a file still here is
    /// never mistaken for a stray.
    private func knownKeyAccounts() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".vault") || ["identity.lock", "identity.bio", "device.key", "catalog.cache"].contains($0) }
            .map { FileKeys(directory: directory, file: $0).account }
    }

    /// A fresh Keychain key for a filler file, so it has one like any real file and the count and changes match. The
    /// item is made anew (not updated), so its creation date moves with the others' rather than marking it.
    private func refreshFillerKey(_ url: URL) {
        let keys = dataKeys(url)
        keys.forget()
        try? keys.store([SymmetricKey(size: .bits256)])
    }

    /// Whether any data file has no Keychain key yet (written by an older build): the main account then gives every
    /// file one in a single pass (`AppModel.wrapDataFilesTogether`), so their creation dates don't single out the real one.
    var hasUnwrappedDataFiles: Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.contains { $0.hasPrefix("data-") && $0.hasSuffix(".vault") && !dataKeys(directory.appendingPathComponent($0)).inUse }
    }

    /// Shreds a data file and removes its Keychain key with it.
    private func shredData(_ url: URL) {
        dataKeys(url).forget()
        shred(url)
    }

    func load(with identity: Identity) throws -> AppData? {
        let url = dataURL(for: identity)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacyDataURL.path) {
            // Older builds used one fixed name; move it over on first unlock.
            try? FileManager.default.moveItem(at: legacyDataURL, to: url)
        }
        // No file means a new account. A file that's there but can't be read is an error, never an empty account
        // that would then be saved over it.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let raw = try Data(contentsOf: url)
        let plain = try openData(raw, identity: identity, url: url)
        let json = try Self.unpad(plain)
        do {
            return try JSONDecoder.pulshade.decode(AppData.self, from: json)
        } catch {
            // One piece that won't read mustn't lock the whole account: open the rest and set that piece aside, sealed
            // in the vault as it was. Data from a newer build is still refused, so nothing it saved is lost.
            guard let rescued = AppData.rescue(json) else { throw error }
            return rescued
        }
    }

    /// Seals under a brand-new Keychain key. The new key is added before the file is written; the old ones are dropped
    /// only once the new file has been read back and opens, so whatever is on disk always has its key, and a save that
    /// failed part-way never strands the account. Old keys a failed drop left behind go with the next save.
    func save(_ data: AppData, with identity: Identity) throws {
        let plain = try JSONEncoder.pulshade.encode(data)
        let url = dataURL(for: identity)
        let keys = dataKeys(url)
        Self.mutation.lock()
        defer { Self.mutation.unlock() }
        let old = keys.load()
        let fresh = SymmetricKey(size: .bits256)
        let sealed = try AES.GCM.seal(Self.pad(plain), using: Self.dataKey(identity, fresh)).combined!
        // Checked in memory before anything is written.
        guard (try? AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: Self.dataKey(identity, fresh))) != nil
        else { throw VaultError.corrupt }
        // Only the key that opens the file there now is kept beside the new one, never every key from before: those
        // open only older copies. If the file can't be read to tell (an iPhone locked), the last two are kept, one of
        // which is it, so the list never grows past three.
        let current = (try? Data(contentsOf: url)).flatMap { try? AES.GCM.SealedBox(combined: $0) }
        let opener = current.flatMap { box in old.last { (try? AES.GCM.open(box, using: Self.dataKey(identity, $0))) != nil } }
        let keep = opener.map { [$0] } ?? (current == nil ? Array(old.suffix(2)) : [])
        // Never a file without its Keychain key: failing here beats quietly writing one an old key still opens.
        try keys.store(keep + [fresh])
        try write(sealed, to: url)
        // Read back before the old key goes. A file that can't be read back yet (an iPhone that locked: the file is
        // written, but can't be opened again until it unlocks) isn't a failure: the old key stays until the next save.
        guard let back = try? Data(contentsOf: url) else { return }
        guard let box = try? AES.GCM.SealedBox(combined: back),
              (try? AES.GCM.open(box, using: Self.dataKey(identity, fresh))) != nil else { throw VaultError.corrupt }
        try? keys.store([fresh])
    }

    /// Data files come in a few sizes only: 64 KB, then doubling. An empty decoy and a filler file look
    /// like any small account.
    static func paddedSize(_ count: Int) -> Int {
        var size = 65_536
        while size < count { size *= 2 }
        return size
    }

    private static let padMagic = Data("PSP1".utf8)

    private static func pad(_ plain: Data) -> Data {
        var out = padMagic
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(plain)
        // The seal adds 28 bytes; pad so the file itself lands on the bucket.
        let target = paddedSize(out.count + 28) - 28
        out.append(Data(count: target - out.count))
        return out
    }

    private static func unpad(_ plain: Data) -> Data {
        // Files written before padding are the bare JSON.
        guard plain.starts(with: padMagic), plain.count >= 8 else { return plain }
        let length = plain.dropFirst(4).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        return Data(plain.dropFirst(8).prefix(length))
    }

    /// There are always exactly this many data files, real or random, so counting them reveals nothing.
    static let dataFileCount = slotCount + 1

    /// Tops up or trims the random filler files around the identities we know are real.
    func rebalance(real: [Identity]) {
        let realNames = Set(real.map { dataURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var fillers = files.filter { $0.hasPrefix("data-") && $0.hasSuffix(".vault") && !realNames.contains($0) }
        let wanted = max(0, Self.dataFileCount - realNames.count)
        while fillers.count > wanted { shredData(directory.appendingPathComponent(fillers.removeLast())) }
        for _ in fillers.count..<wanted {
            let url = directory.appendingPathComponent("data-\(Data.random(12).hex).vault")
            try? write(.random(fillerSize(real: real)), to: url)
            refreshFillerKey(url)
        }
        // Fillers from before data files had Keychain keys get theirs from `refreshFillers`, which only the main account
        // runs: from here (a decoy runs this too) a real file written by an older build would look like filler, and a
        // random key put on it would lock that account out.
    }

    /// Rewrites the filler files with fresh random bytes, so they change size and time together with the
    /// real ones and nothing about the files says which is which.
    func refreshFillers(real: [Identity]) {
        let realNames = Set(real.map { dataURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasPrefix("data-") && name.hasSuffix(".vault") && !realNames.contains(name) {
            let url = directory.appendingPathComponent(name)
            try? write(.random(fillerSize(real: real)), to: url)
            refreshFillerKey(url)
        }
    }

    /// A bucket size somewhere between the smallest and twice the largest real file.
    private func fillerSize(real: [Identity]) -> Int {
        let largest = real.compactMap { try? FileManager.default.attributesOfItem(atPath: dataURL(for: $0).path)[.size] as? Int }
            .max() ?? 0
        var sizes = [65_536]
        while sizes.last! < largest * 2 { sizes.append(sizes.last! * 2) }
        return sizes.randomElement()!
    }

    /// Overwrites every file with random bytes before deleting them, and revokes their Keychain keys.
    /// `leavingNoTrace` (Burn) deletes the Keychain items and the folder too, rather than leaving revoked keys.
    func destroy(leavingNoTrace: Bool = false) {
        Self.mutation.lock()
        defer { Self.mutation.unlock() }
        if leavingNoTrace {
            lockKeys.forget()
            biometricKeys.forget()
            deviceKeyKeys.forget()
            catalogKeys.forget()
        } else {
            if catalogKeys.inUse { catalogKeys.revoke() }
            if deviceKeyKeys.inUse { deviceKeyKeys.revoke() }
            if exists || lockKeys.inUse { lockKeys.revoke() }
            if hasBiometrics || biometricKeys.inUse { biometricKeys.revoke() }
        }
        // Every data file's key too, real and filler alike.
        let present = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in present where url.pathExtension == "vault" { dataKeys(url).forget() }
        // The keys are gone above; only then are the media files and fillers wiped.
        MediaPool(directory: directory).wipe()
        // Anything a panic set aside and hasn't finished overwriting yet.
        let aside = ((try? FileManager.default.contentsOfDirectory(at: workURL, includingPropertiesForKeys: nil)) ?? [])
            + present.filter { $0.lastPathComponent.hasPrefix(".media-gone-") }
        for url in aside { Self.scrub(item: url) }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["lock", "vault", "bio", "cache"].contains(url.pathExtension) { shred(url) }
        if leavingNoTrace {
            // Everything left in it, whatever it is, is overwritten and removed, then the
            // folder itself. A Burn has to leave nothing that says an account was ever here.
            Self.scrub(folder: directory)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Overwrites and deletes whatever Pulshade left in its temporary and cache folders, and forgets anything the system
    /// kept of its web requests. On iPhone those folders belong to Pulshade alone, so they're emptied. On macOS (the test
    /// build) they are shared with every other app, so only Pulshade's own cache folder and its own temporary files go, never
    /// anything of anyone else's. The overwriting runs in the background, since it can take a moment.
    static func scrubLeftovers() {
        // Not the sealed media pool: Burn and Detach (`destroy`) and a panic unlock (`panic`) remove it themselves, after
        // its keys are gone.
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let files = FileManager.default
        func contents(of folder: URL) -> [URL] { (try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] }
        let caches = files.urls(for: .cachesDirectory, in: .userDomainMask).first
        var items: [URL] = []
        #if os(iOS)
        items = contents(of: files.temporaryDirectory) + (caches.map(contents(of:)) ?? [])
        #else
        // Under a test runner the bundle is Apple's, not ours: leave its folder alone.
        if let caches, let id = Bundle.main.bundleIdentifier, !id.hasPrefix("com.apple.") {
            items.append(caches.appendingPathComponent(id, isDirectory: true))
        }
        // Tor's relay lists and bridge descriptors live here, separate from the bundle's own cache folder.
        if let caches { items.append(caches.appendingPathComponent("Pulshade", isDirectory: true)) }
        items += contents(of: files.temporaryDirectory).filter { TempFiles.isOurs($0.lastPathComponent) }
        #endif
        Task.detached(priority: .userInitiated) { for item in items { scrub(item: item) } }
    }

    /// Overwrites a file or everything under a folder, then deletes it.
    nonisolated static func scrub(item: URL) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder) else { return }
        if isFolder.boolValue {
            scrub(folder: item)
            try? FileManager.default.removeItem(at: item)
        } else {
            if let size = (try? item.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0, size <= 64_000_000 {
                try? Data.random(size).write(to: item)
            }
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Overwrites every file under `root` (up to 64 MB each; larger ones are only deleted, so the wipe isn't held
    /// up) and deletes everything in it.
    private nonisolated static func scrub(folder root: URL) {
        let files = FileManager.default
        if let walker = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true else { continue }
                if let size = values.fileSize, size > 0, size <= 64_000_000 { try? Data.random(size).write(to: url) }
                try? files.removeItem(at: url)
            }
        }
        for url in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? files.removeItem(at: url)
        }
    }

    private func shred(_ url: URL) {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
            try? Data.random(size).write(to: url)
        }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Helpers

    private func write(_ data: Data, to url: URL) throws {
        // Burn removes the folder; the next account brings it back.
        if !FileManager.default.fileExists(atPath: directory.path) { prepareDirectory() }
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Contents are already sealed by us (and the disk by FileVault). Data Protection classes add
        // little on macOS (the test build) and some setups refuse them outright. On iPhone
        // the files also can't be read while the phone is locked, except while open (a call in a pocket).
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func stretch(_ passcode: String, salt: Data, iterations: UInt32) -> SymmetricKey {
        var derived = Data(count: 32)
        // The stretched bytes are copied into the key below; don't leave the working buffer in memory.
        defer {
            derived.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress { _ = memset_s(base, buffer.count, 0, buffer.count) }
            }
        }
        let password = Array(passcode.utf8).map { Int8(bitPattern: $0) }
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        precondition(status == kCCSuccess, "Key stretching failed")
        return SymmetricKey(data: derived)
    }
}

/// One received media item kept outside AppData: a random file name and its own random AES-GCM key. The key belongs
/// only in the encrypted vault's reference; the file body alone opens nothing.
struct MediaFileRef: Codable, Equatable {
    var name: String
    var key: Data
    var size: Int
    var sha256: Data
}

/// The sealed media pool beside the vault. Real items and random filler files use the same random names, padded bucket
/// sizes drawn from the account's own items, and one uniform timestamp. The pool only ever grows, in doubling steps to
/// at least twice what this account keeps in it, so its file count shows no more than a rough size, and arrivals and
/// deletions don't show in names, sizes or set dates. (The inode change time can't be set from an app, so it still
/// shows when the pool last changed.)
///
/// Several accounts can share the pool (the real one, a decoy, a panic landing), and none can tell another's files from
/// filler. So an account only ever reuses filler it made itself (`ownFillers`, kept in its own sealed data) and never
/// overwrites or removes a file it doesn't know: another account's media stays safe, and a file nobody claims looks
/// like any other filler. Only Burn and Detach (`wipe`) remove the pool. Keys are supplied by the caller and live in
/// AppData; nothing here writes plaintext.
final class MediaPool {
    /// The smallest pool, so a new account's first item changes nothing on disk either.
    static let smallest = 16
    /// Filler sizes before the account has items of its own to copy: the smaller padded buckets, where photos and voice
    /// notes land. Later fillers copy the sizes of real items, so the pool's total stays about twice what it keeps and
    /// its size histogram looks like the account's own.
    static let startingBuckets = [65_536, 131_072, 262_144, 524_288, 1_048_576]

    let directory: URL
    private(set) var realNames: Set<String>
    /// Filler files this account made and may reuse. Anything else that isn't one of its items is left alone.
    private(set) var ownFillers: Set<String>
    /// The sealed (on-disk) sizes of this account's items, which new filler copies.
    private(set) var realSizes: [Int]

    init(directory: URL, realNames: Set<String> = [], ownFillers: Set<String> = [], realSizes: [Int] = []) {
        self.directory = directory
        self.realNames = realNames.filter(Self.isValidName)
        self.ownFillers = ownFillers.filter(Self.isValidName).subtracting(realNames)
        self.realSizes = realSizes
    }

    /// Every name the pool makes is 32 lowercase hex characters. Anything else (a reference that came from another
    /// device, say) is never opened, overwritten or counted as this account's.
    static func isValidName(_ name: String) -> Bool {
        name.utf8.count == 32 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The size a sealed item of `plainCount` bytes takes on disk.
    static func sealedSize(ofPlain plainCount: Int) -> Int { Vault.paddedSize(plainCount + 8 + 28) }

    var mediaDirectory: URL { directory.appendingPathComponent("media", isDirectory: true) }

    /// The file count the pool grows to for `real` items of this account: a power of two, at least twice as many.
    static func target(forReal real: Int, files: Int) -> Int {
        var size = smallest
        while size < max(2 * real, files) { size *= 2 }
        return size
    }

    /// Set by `store(_:growLater:)` when the pool should grow and that was left for `topUp`.
    private(set) var wantsGrowth = false

    /// Writes a new sealed item into one of this account's filler files (growing the pool first if it has none) and
    /// returns the reference the vault must keep. Fails rather than writing anything unencrypted.
    ///
    /// `growLater`: a pool that already exists isn't grown here (doubling a big one writes hundreds of megabytes, and the
    /// app calls this on the main thread, for anything anyone sends). At most one new filler is made, for this item, and
    /// `wantsGrowth` says the caller should `topUp` a copy of the pool in the background.
    func store(_ plaintext: Data, growLater: Bool = false) throws -> MediaFileRef {
        try prepare()
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        guard let sealed = try AES.GCM.seal(Self.pad(plaintext), using: key).combined else { throw VaultError.corrupt }
        realSizes.append(sealed.count)
        let existing = Set(allFiles().map(\.lastPathComponent))
        ownFillers.formIntersection(existing)
        let short = ownFillers.isEmpty || existing.count < Self.target(forReal: realNames.count + 1, files: existing.count)
        if short, growLater, existing.count >= Self.smallest {
            wantsGrowth = true
            if ownFillers.isEmpty {
                let url = try makeFiller()
                ownFillers.insert(url.lastPathComponent)
            }
        } else {
            if short { try grow(toHold: realNames.count + 1) }
            // Still none of its own (the pool is full of another account's files, which it can't tell from filler): double
            // the pool with filler of its own rather than ever borrowing a file it doesn't know.
            if ownFillers.isEmpty { try grow(toHold: realNames.count + 1, doubling: true) }
        }
        guard let name = ownFillers.sorted().first else { throw VaultError.corrupt }
        let url = mediaDirectory.appendingPathComponent(name)
        // Into the filler's own file, not a new one put in its place: a new file would get a new inode and its own
        // change time, telling real files from filler, and when each came.
        try writeInPlace(sealed, to: url)
        ownFillers.remove(name)
        realNames.insert(name)
        stamp([url])
        return MediaFileRef(name: name, key: keyData, size: plaintext.count,
                            sha256: Data(SHA256.hash(data: plaintext)))
    }

    /// Opens a reference. A missing file, a wrong key or any changed byte is an error; never a crash and never a
    /// plaintext fallback.
    func load(_ file: MediaFileRef) throws -> Data {
        guard file.key.count == 32, Self.isValidName(file.name) else { throw VaultError.corrupt }
        let raw = try Data(contentsOf: mediaDirectory.appendingPathComponent(file.name))
        let box = try AES.GCM.SealedBox(combined: raw)
        let padded = try AES.GCM.open(box, using: SymmetricKey(data: file.key))
        let plain = try Self.unpad(padded)
        guard plain.count == file.size, Data(SHA256.hash(data: plain)) == file.sha256 else {
            throw VaultError.corrupt
        }
        return plain
    }

    /// Overwrites a deleted item in place with random bytes of the same size and keeps it as this account's filler.
    /// The file, its name and its size stay, so a deletion is not visible on disk.
    func delete(_ file: MediaFileRef) throws {
        try release(file.name)
    }

    /// `delete` by name, for an item whose reference is already gone from the account's data.
    func release(_ name: String) throws {
        guard Self.isValidName(name) else { return }
        let url = mediaDirectory.appendingPathComponent(name)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
        if size > 0 { try overwriteInPlace(url, size: size) }
        realNames.remove(name)
        ownFillers.insert(name)
        stamp([url])
    }

    /// Adds filler (this account's own) until the pool is the size it should be for `real` items. Never removes. Stops,
    /// and removes what it made, if the pool is wiped meanwhile (Burn, Detach or a panic, while it grew in the background).
    func grow(toHold real: Int, doubling: Bool = false, since: Int? = nil) throws {
        let started = since ?? wipes
        // Asked for before a wipe (Burn, Detach, a panic): nothing is made, and a pool that's gone isn't made again.
        guard wipes == started else { throw VaultError.missing }
        if since != nil, !FileManager.default.fileExists(atPath: mediaDirectory.path) { throw VaultError.missing }
        try prepare()
        var count = allFiles().count
        let wanted = doubling ? max(Self.smallest, count * 2) : Self.target(forReal: real, files: count)
        var made: [URL] = []
        while count < wanted {
            guard wipes == started else {
                for url in made { try? FileManager.default.removeItem(at: url) }
                throw VaultError.missing
            }
            let url = try makeFiller()
            made.append(url)
            ownFillers.insert(url.lastPathComponent)
            count += 1
        }
        if !made.isEmpty { stamp(made) }
    }

    /// Grows the pool to its size for the items it holds, with filler of this account's own to spare. For a copy of the
    /// pool, in the background, after a `store(_:growLater:)` that left it short. Returns the new filler's names.
    /// `since`: the pool's `wipes` when the growth was asked for, so a wipe in between stops it.
    func topUp(since: Int) throws -> Set<String> {
        let before = ownFillers
        try grow(toHold: realNames.count, since: since)
        if ownFillers.subtracting(before).isEmpty, ownFillers.count < 2 {
            try grow(toHold: realNames.count, doubling: true, since: since)
        }
        return ownFillers.subtracting(before)
    }

    /// Counts each pool's wipes (by its folder), so a growth running in the background knows the pool it was growing is
    /// gone.
    nonisolated(unsafe) private static var wipeCounts: [String: Int] = [:]
    private static let wipeLock = NSLock()
    var wipes: Int { Self.wipeLock.withLock { Self.wipeCounts[mediaDirectory.standardizedFileURL.path] ?? 0 } }
    private func noteWipe() { Self.wipeLock.withLock { Self.wipeCounts[mediaDirectory.standardizedFileURL.path, default: 0] += 1 } }

    var fileCount: Int { allFiles().count }
    var fillerCount: Int { allFiles().filter { !realNames.contains($0.lastPathComponent) }.count }
    var ownFillerCount: Int { ownFillers.count }

    /// Like `wipe`, but returns at once: the pool is moved into the vault's work folder under a random name (so it's gone
    /// from where it was straight away) and overwritten in the background (`Vault.setAside`). One left part-way (the app
    /// was closed) is finished at the next launch, or the next time the pool is used. Its keys must already be gone.
    func wipeSoon() {
        noteWipe()
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { return }
        Vault.setAside(mediaDirectory, in: directory)
        realNames = []
        ownFillers = []
    }

    /// Pools moved aside by `wipeSoon` that weren't finished.
    private func finishWipes() {
        Vault.finishSetAside(in: directory)
    }

    /// Keys are destroyed by the vault before this is called; then every real file and filler is overwritten and removed.
    func wipe() {
        noteWipe()
        guard FileManager.default.fileExists(atPath: mediaDirectory.path) else { return }
        Vault.scrub(item: mediaDirectory)
        try? FileManager.default.removeItem(at: mediaDirectory)
        realNames = []
        ownFillers = []
    }

    // MARK: Files

    private func prepare() throws {
        finishWipes()
        var url = mediaDirectory
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private func allFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaDirectory,
                                                                  includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return files.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
    }

    private func freshName() throws -> String {
        for _ in 0..<32 {
            let name = Data.random(16).hex
            if !FileManager.default.fileExists(atPath: mediaDirectory.appendingPathComponent(name).path) { return name }
        }
        throw VaultError.corrupt
    }

    private func makeFiller() throws -> URL {
        let size = realSizes.randomElement() ?? Self.startingBuckets.randomElement() ?? 65_536
        let name = try freshName()
        let url = mediaDirectory.appendingPathComponent(name)
        try write(Data.random(size), to: url)
        return url
    }

    /// Gives the files just written, and the folder, the date every file in the pool shares: picked once at random when
    /// the pool is made, then copied, so only the touched files are stamped and no write shows by its date.
    private func stamp(_ touched: [URL]) {
        let names = Set(touched.map(\.lastPathComponent))
        let shared = allFiles().lazy.filter { !names.contains($0.lastPathComponent) }
            .compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.first
        let when = shared ?? Date(timeIntervalSince1970: Double.random(in: 1_600_000_000...Date().timeIntervalSince1970))
        for url in touched + [mediaDirectory] {
            try? FileManager.default.setAttributes([.modificationDate: when, .creationDate: when],
                                                   ofItemAtPath: url.path)
        }
        // The change time (ctime) can't be set, only moved to now: every file's is, so they all say only when the pool
        // last changed, not which file did.
        for url in allFiles() {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Writes `data` over a file that is already there, in its own blocks, and cuts it to that length. Falls back to a
    /// fresh file only if there's none (never an unencrypted one: `data` is already sealed).
    private func writeInPlace(_ data: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return try write(data, to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: data)
        try handle.truncate(atOffset: UInt64(data.count))
        try handle.synchronize()
    }

    /// Writes random bytes over the file's own blocks (no new file and rename, which would leave the old bytes where
    /// they were).
    private func overwriteInPlace(_ url: URL, size: Int) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: 0)
        var left = size
        while left > 0 {
            let chunk = min(left, 1_048_576)
            try handle.write(contentsOf: Data.random(chunk))
            left -= chunk
        }
        try handle.truncate(atOffset: UInt64(size))
        try handle.synchronize()
    }

    private func write(_ data: Data, to url: URL) throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mediaDirectory.path)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Padding

    private static let padMagic = Data("PSM1".utf8)

    static func pad(_ plain: Data) -> Data {
        var out = padMagic
        withUnsafeBytes(of: UInt32(plain.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(plain)
        let target = Vault.paddedSize(out.count + 28) - 28
        out.append(Data(count: target - out.count))
        return out
    }

    static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 8, padded.prefix(4) == padMagic else { throw VaultError.corrupt }
        let length = padded.dropFirst(4).prefix(4).reduce(0) { $0 << 8 | Int($1) }
        guard length <= padded.count - 8 else { throw VaultError.corrupt }
        return Data(padded.dropFirst(8).prefix(length))
    }
}

extension JSONEncoder {
    static let pulshade: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}

extension JSONDecoder {
    static let pulshade: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
