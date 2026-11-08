import Foundation
import CryptoKit
import CommonCrypto
import LocalAuthentication

enum VaultError: Error {
    case wrongPasscode, corrupt, missing
    case keychain(OSStatus)
}

/// Everything Pulshade keeps lives in encrypted files in Application Support:
///  - `identity.lock`: three passcode slots. Each holds either a sealed identity, a panic marker,
///    or random filler, and all three look the same, so nobody can tell how many are real. Each slot's
///    key mixes the passcode with a key only this device's Secure Enclave can use, so a copied file
///    can't be guessed at anywhere else. The whole file is sealed again with a key from the Keychain,
///    replaced on every rewrite (and every lock), so an old copy recovered from the disk opens nowhere,
///    not even here. `identity.bio` is sealed the same way.
///  - `data-*.vault`: one per identity, sealed with a key derived from that identity, plus decoy
///    files of random bytes so the count doesn't give anything away. All are padded to the same
///    sizes, and the folder is kept out of backups.
struct Vault {
    private static let iterations: UInt32 = 600_000
    static let slotCount = 3

    let directory: URL

    init(directory: URL) {
        self.directory = directory
        prepareDirectory()
    }

    private func prepareDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // Backups would carry the sealed files somewhere they could be guessed at for ever.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }

    /// `PULSHADE_PROFILE=name` keeps a separate identity, handy for running two copies side by side.
    static var standard: Vault {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Pulshade", isDirectory: true)
        if let profile = ProcessInfo.processInfo.environment["PULSHADE_PROFILE"], !profile.isEmpty {
            dir = dir.appendingPathComponent("profiles/\(profile)", isDirectory: true)
        }
        return Vault(directory: dir)
    }

    private var lockURL: URL { directory.appendingPathComponent("identity.lock") }
    private var legacyDataURL: URL { directory.appendingPathComponent("data.vault") }
    private var biometricURL: URL { directory.appendingPathComponent("identity.bio") }
    private var lockKeys: FileKeys { FileKeys(directory: directory, file: "identity.lock") }
    private var biometricKeys: FileKeys { FileKeys(directory: directory, file: "identity.bio") }

    var exists: Bool { FileManager.default.fileExists(atPath: lockURL.path) }

    /// What a passcode opened.
    enum Opened {
        case identity(Identity, slot: Int)
        /// The panic passcode: wipe the real identity, then carry on as this harmless one.
        case panic(Identity, slot: Int)
    }

    private struct Slot: Codable {
        var salt: Data
        var iterations: UInt32
        var sealed: Data
    }

    /// A Secure Enclave key, wrapped so only this device's chip can use it, and the public half of a key it
    /// was paired with. Together they give the device secret mixed into every slot's key.
    private struct DeviceBinding: Codable {
        var enclaveKey: Data
        var ephemeral: Data
    }

    private struct LockFile: Codable {
        var version = 3
        var slots: [Slot]
        /// Nil where there's no Secure Enclave, and in files written before version 3.
        var device: DeviceBinding?
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

    /// A fresh vault: the identity in slot 0, filler in the rest, bound to this device.
    func create(_ identity: Identity, passcode: String) throws {
        let device = Self.makeBinding()
        let secret = try device.map(Self.deviceSecret)
        var slots = (0..<Self.slotCount).map { _ in Self.filler() }
        slots[0] = try Self.seal(.identity, identity.seed, passcode: passcode, device: secret)
        try writeLock(slots, device: device)
        rebalance(real: [identity])
    }

    /// Tries every slot, always all of them, so timing doesn't reveal which one matched.
    func unlock(passcode: String) throws -> Opened {
        let (slots, device) = try readLock()
        let secret = try device.map(Self.deviceSecret)
        var opened: Opened?
        for (index, slot) in slots.enumerated() {
            // A malformed salt (only possible in an editable, Keychain-less lock file) would make the KDF
            // trap; treat such a slot as unusable instead.
            guard !slot.salt.isEmpty else { continue }
            // Derive and decrypt every slot even after one matches: stopping early would let the timing (and
            // the number of decryptions) say which slot a passcode opened, defeating decoy/panic deniability.
            let key = Self.slotKey(passcode, salt: slot.salt, iterations: Self.safeIterations(slot.iterations), device: secret)
            let plain = (try? AES.GCM.SealedBox(combined: slot.sealed))
                .flatMap { try? AES.GCM.open($0, using: key) }
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
        return opened
    }

    /// The stretch count a slot asks for, clamped so an editable (Keychain-less) lock file can neither
    /// lower the work below what this build uses nor make unlocking take forever.
    private static func safeIterations(_ stored: UInt32) -> UInt32 {
        min(max(stored, iterations), 5_000_000)
    }

    /// Whether any slot already opens with this passcode.
    func passcodeInUse(_ passcode: String) -> Bool {
        (try? unlock(passcode: passcode)) != nil
    }

    /// Whether the lock file is bound to this device's Secure Enclave. Older files aren't until rewritten.
    var isDeviceBound: Bool { (try? readLock().device) != nil }

    /// Puts an identity (or a panic landing identity) behind a passcode in a slot.
    func setSlot(_ index: Int, identity: Identity, passcode: String, panic: Bool = false) throws {
        var (slots, device) = try readLock()
        slots[index] = try Self.seal(panic ? .panic : .identity, identity.seed, passcode: passcode,
                                     device: device.map(Self.deviceSecret))
        try writeLock(slots, device: device)
    }

    /// The panic passcode was used: the landing identity becomes an ordinary account in the first slot,
    /// under a brand-new device key, every other slot becomes filler, and every other data file is
    /// shredded along with Touch ID.
    func panic(keeping landing: Identity, slot: Int, passcode: String) throws {
        let device = Self.makeBinding()
        var slots = (0..<Self.slotCount).map { _ in Self.filler() }
        slots[0] = try Self.seal(.identity, landing.seed, passcode: passcode, device: device.map(Self.deviceSecret))
        try writeLock(slots, device: device)
        let keep = dataURL(for: landing).lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "vault" && url.lastPathComponent != keep { shred(url) }
        disableBiometrics()
        rebalance(real: [landing])
    }

    /// Turns a slot back into filler and destroys the data it pointed at.
    func clearSlot(_ index: Int, identity: Identity?) throws {
        var (slots, device) = try readLock()
        slots[index] = Self.filler()
        try writeLock(slots, device: device)
        if let identity { shred(dataURL(for: identity)) }
    }

    /// Rewrites the lock file under a new Keychain key, so every earlier copy stops opening.
    func rotate() {
        guard let (slots, device) = try? readLock() else { return }
        try? writeLock(slots, device: device)
    }

    private func readLock() throws -> (slots: [Slot], device: DeviceBinding?) {
        let raw = try readSealed(lockURL, keys: lockKeys)
        if let file = try? JSONDecoder().decode(LockFile.self, from: raw), file.slots.count == Self.slotCount {
            return (file.slots, file.device)
        }
        guard let old = try? JSONDecoder().decode(LegacyLockFile.self, from: raw) else { throw VaultError.corrupt }
        return ([Slot(salt: old.salt, iterations: old.iterations, sealed: old.sealedSeed)]
            + (1..<Self.slotCount).map { _ in Self.filler() }, nil)
    }

    private func writeLock(_ slots: [Slot], device: DeviceBinding?) throws {
        try writeSealed(Self.encoder.encode(LockFile(slots: slots, device: device)), to: lockURL, keys: lockKeys)
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
        let old = keys.load()
        let fresh = SymmetricKey(size: .bits256)
        do {
            try keys.store(old + [fresh])
        } catch {
            // No Keychain to be had: the file goes down as it did before, unless it has been sealed
            // here, since an unsealed one would then be refused.
            guard !keys.inUse else { throw error }
            try write(plain, to: url)
            return
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

    private static func seal(_ role: Role, _ seed: Data, passcode: String, device: SymmetricKey?) throws -> Slot {
        let salt = Data.random(16)
        let key = slotKey(passcode, salt: salt, iterations: iterations, device: device)
        let sealed = try AES.GCM.seal(Data([role.rawValue]) + seed, using: key).combined!
        return Slot(salt: salt, iterations: iterations, sealed: sealed)
    }

    /// The stretched passcode, mixed with the device secret when there is one.
    private static func slotKey(_ passcode: String, salt: Data, iterations: UInt32, device: SymmetricKey?) -> SymmetricKey {
        let stretched = stretch(passcode, salt: salt, iterations: iterations)
        guard let device else { return stretched }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: stretched.bytes + device.bytes), salt: salt,
                                      info: Data("pulshade.slot.v3".utf8), outputByteCount: 32)
    }

    // MARK: Device binding

    /// A new Secure Enclave key for this vault. Nil where there's no Secure Enclave (the Simulator,
    /// older Macs), and when tests ask for none.
    private static func makeBinding() -> DeviceBinding? {
        guard SecureEnclave.isAvailable else { return nil }
        #if DEBUG
        // Tests only. A shipped build never lets its surroundings switch the binding off.
        if ProcessInfo.processInfo.environment["PULSHADE_NO_ENCLAVE"] != nil { return nil }
        #endif
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           [.privateKeyUsage], &error),
              let enclave = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access) else { return nil }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        return DeviceBinding(enclaveKey: enclave.dataRepresentation, ephemeral: ephemeral.publicKey.x963Representation)
    }

    /// Only this device's Secure Enclave can work this out from the binding.
    private static func deviceSecret(_ binding: DeviceBinding) throws -> SymmetricKey {
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: binding.enclaveKey)
        let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: binding.ephemeral)
        return try enclave.sharedSecretFromKeyAgreement(with: ephemeral)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: Data("pulshade.device".utf8), outputByteCount: 32)
    }

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

    /// "Face ID" on iPhone, "Touch ID" on a Mac.
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
        if hasBiometrics || biometricKeys.inUse { biometricKeys.revoke() }
        shred(biometricURL)
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

    // MARK: Data

    /// Each identity's data file is named from its storage key, so names reveal nothing.
    private func dataURL(for identity: Identity) -> URL {
        let name = Data(SHA256.hash(data: identity.storageKey.bytes + Data("pulshade.file".utf8)).prefix(12)).hex
        return directory.appendingPathComponent("data-\(name).vault")
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
        let box = try AES.GCM.SealedBox(combined: raw)
        let plain = try AES.GCM.open(box, using: identity.storageKey)
        return try JSONDecoder.pulshade.decode(AppData.self, from: Self.unpad(plain))
    }

    func save(_ data: AppData, with identity: Identity) throws {
        let plain = try JSONEncoder.pulshade.encode(data)
        let sealed = try AES.GCM.seal(Self.pad(plain), using: identity.storageKey).combined!
        try write(sealed, to: dataURL(for: identity))
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

    /// Wipes one identity: its data, and Touch ID if it was the one using it.
    func wipeData(for identity: Identity) {
        shred(dataURL(for: identity))
        disableBiometrics()
    }

    /// There are always exactly this many data files, real or random, so counting them reveals nothing.
    static let dataFileCount = slotCount + 1

    /// Tops up or trims the random filler files around the identities we know are real.
    func rebalance(real: [Identity]) {
        let realNames = Set(real.map { dataURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var fillers = files.filter { $0.hasPrefix("data-") && $0.hasSuffix(".vault") && !realNames.contains($0) }
        let wanted = max(0, Self.dataFileCount - realNames.count)
        while fillers.count > wanted { shred(directory.appendingPathComponent(fillers.removeLast())) }
        for _ in fillers.count..<wanted {
            try? write(.random(fillerSize(real: real)), to: directory.appendingPathComponent("data-\(Data.random(12).hex).vault"))
        }
    }

    /// Rewrites the filler files with fresh random bytes, so they change size and time together with the
    /// real ones and nothing about the files says which is which.
    func refreshFillers(real: [Identity]) {
        let realNames = Set(real.map { dataURL(for: $0).lastPathComponent })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in files where name.hasPrefix("data-") && name.hasSuffix(".vault") && !realNames.contains(name) {
            try? write(.random(fillerSize(real: real)), to: directory.appendingPathComponent(name))
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
        if leavingNoTrace {
            lockKeys.forget()
            biometricKeys.forget()
        } else {
            if exists || lockKeys.inUse { lockKeys.revoke() }
            if hasBiometrics || biometricKeys.inUse { biometricKeys.revoke() }
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in files where ["lock", "vault", "bio"].contains(url.pathExtension) { shred(url) }
        if leavingNoTrace {
            for url in files where !["lock", "vault", "bio"].contains(url.pathExtension) && url.lastPathComponent != "profiles" {
                try? FileManager.default.removeItem(at: url)
            }
            // Other profiles (PULSHADE_PROFILE) live inside the main folder, so it only goes when empty.
            if ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).isEmpty {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Overwrites and deletes whatever Pulshade left in its temporary and cache folders, and forgets anything the system
    /// kept of its web requests. On iPhone those folders belong to Pulshade alone, so they're emptied. On the Mac they
    /// are shared with every other app, so only Pulshade's own cache folder and its own temporary files go, never
    /// anything of anyone else's. The overwriting runs in the background, since it can take a moment.
    static func scrubLeftovers() {
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
        // Contents are already sealed by us (and the disk by FileVault). Data Protection classes add
        // little on a Mac and some setups refuse them outright, which would stop Pulshade saving. On iPhone
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
