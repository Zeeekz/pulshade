import Foundation
import CryptoKit
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A file kept on the relay, as a message names it. The file itself is not in the message: it was sealed on the sender's
/// phone with `key` (which only travels in this end-to-end encrypted message) and uploaded once, in pieces, to the relay,
/// which keeps the scrambled bytes and can't open them. The receiver's phone fetches them into memory and opens them
/// there. `secret` lets whoever holds this message tell the relay to erase the file. See docs/blob-store.md.
struct Attachment: Codable, Equatable {
    enum Kind: String, Codable { case file, photo, video, voice }

    /// 32 hex characters, chosen by the sender.
    var id: String
    /// The 32-byte key the file was sealed with.
    var key: Data
    /// The file's size in bytes, before sealing.
    var size: Int
    var kind: Kind
    /// A file's name, for showing. Never trusted for anything else.
    var name: String?
    /// A file's type (for example "application/pdf"), only for choosing an icon.
    var type: String?
    /// SHA-256 of the file, checked once it has been fetched and opened.
    var sha256: Data
    /// 32 random bytes; their hash is what the relay holds, so only a holder of the message can erase the file.
    var secret: Data
    /// When the relay forgets it on its own.
    var expires: Date
    /// A one-time token for this person: spent (sent to the relay) once the whole file has been fetched and checked, so the
    /// relay can erase the file when everyone it was sent to has it. Nil for a file that stays until it's deleted or expires.
    var token: Data?
    /// This phone fetched it and the relay has been told: the file is no longer on the relay, and this phone doesn't keep it.
    var collected: Bool?
    /// What the relay holds, in bytes, when the sender padded the sealed file to a size bucket (`BlobPadding`) so the
    /// relay can't tell its real size: the sealed file, then random bytes. Receivers fetch it all and keep the sealed
    /// part. Nil from senders before build 22, whose files are stored as sealed. Apps before build 22 ignore it and still
    /// open the file: the sealed part comes first, and they only ask for that.
    var padded: Int?

    /// Whether a received attachment is well-formed, so nothing odd gets as far as the network.
    var isValid: Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } && key.count == 32 && secret.count == 32 && sha256.count == 32
            && (1...BlobCrypto.maxFile).contains(size) && (name?.count ?? 0) <= 255 && (type?.count ?? 0) <= 100
            && (token == nil || token?.count == 32)
            && (padded.map { (BlobCrypto.sealedSize(of: size)...BlobPadding.relayMax).contains($0) } ?? true)
    }

    /// The name to show: no folders, no control, direction-changing or other invisible characters (a name can't be
    /// made to read as a different file type), never empty.
    var shownName: String {
        let base = (name ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = String(base.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !ProfileLinkKind.hasHidden(String($0))
        }.prefix(120))
        return clean.trimmingCharacters(in: .whitespaces).isEmpty ? "File" : clean
    }

    var sealedSize: Int { BlobCrypto.sealedSize(of: size) }
    var pieceCount: Int { BlobCrypto.pieceCount(of: size) }
    /// What the relay holds: the sealed file and any padding after it.
    var storedSize: Int { padded ?? sealedSize }
    /// The relay's pieces of it, padding included.
    var storedPieces: Int { max(1, (storedSize + BlobCrypto.sealedPiece - 1) / BlobCrypto.sealedPiece) }
}

/// The sizes a file is padded to on the relay, so the relay (or anyone who can see its disk) learns only roughly how big a
/// file is: steps of a quarter up to a mebibyte, from 8 KiB, and above that the same steps rounded up to whole mebibytes.
/// What a file is padded with costs as much to upload and fetch as the file itself, at most a quarter more (a little
/// more than that for small files).
enum BlobPadding {
    static let smallest = 8 * 1024
    static let step = 1.25
    /// The most the relay takes for one file (its `MAX_BLOB`): 100 MiB of file and the sealing's 16 bytes for every MiB.
    static let relayMax = 104_857_600 + 1_638_400

    /// The size a sealed file of `sealed` bytes is padded to: never less than it, never more than the relay takes.
    static func padded(_ sealed: Int) -> Int {
        var bucket = Double(smallest)
        while bucket < Double(sealed) { bucket *= step }
        var size = Int(bucket.rounded(.up))
        let mib = BlobCrypto.sealedPiece
        if size > mib { size = (size + mib - 1) / mib * mib }
        return min(max(size, sealed), max(relayMax, sealed))
    }
}

/// The list of readers the relay is given for a file (see docs/blob-store.md): one token for each person it went to,
/// spent by each of their devices once it has the whole file, so the relay can erase it when everyone has. Left as it
/// was, the list told the relay how many people a file went to and how many devices each has. Now every list has a fixed
/// shape: at least four entries (a power of two past that), every one good for the same number of uses. The entries
/// nobody reads are the sender's own (`BlobSpend`), and the sender spends them, and the uses its readers' devices won't,
/// itself, at random moments, each on a connection of its own. Until it has, the file stays on the relay; if it never
/// can (the app deleted, say), the file simply expires with its message.
enum BlobReaders {
    /// The fewest entries a list has: the relay always takes a list this short, whatever the file's size.
    static let smallest = 4
    static let maxUses = 16

    /// How many entries, and how many uses each, a list for readers with these numbers of devices has, for a file of
    /// `size` bytes on the relay (a longer list must be no bigger than the file, 33 bytes an entry).
    static func shape(devices: [Int], size: Int) -> (count: Int, uses: Int) {
        let most = min(maxUses, max(1, devices.max() ?? 1))
        var uses = 2
        while uses < most { uses *= 2 }
        let n = devices.count
        var count = smallest
        while count < n { count *= 2 }
        count = min(count, 1024)
        if count > smallest, count * 33 > size { count = max(n, min(count, size / 33)) }
        return (count, min(uses, maxUses))
    }
}

/// Uses of a file's reader tokens that its sender spends itself, at `due`, so the relay can erase the file when the real
/// readers have it (see `BlobReaders`). Kept in the sealed vault until spent; dropped once the file has expired.
struct BlobSpend: Codable, Equatable {
    var id: String
    var token: Data
    var uses: Int
    var due: Date
    var expires: Date
}

/// Sealing a file piece by piece, so neither end ever holds more than a few pieces at once while sending, and the
/// pieces can't be swapped, reordered or cut short without the opening failing.
enum BlobCrypto {
    /// What the relay takes as one piece: exactly 1 MiB of sealed bytes, except the last, which may be shorter.
    static let sealedPiece = 1024 * 1024
    static let tag = 16
    /// How much of the file goes into each piece.
    static let plainPiece = sealedPiece - tag
    /// The biggest file Pulshade sends: a phone works in memory, and the receiving one holds the whole file in it.
    static let maxFile = 100 * 1024 * 1024

    static func pieceCount(of size: Int) -> Int { max(1, (size + plainPiece - 1) / plainPiece) }
    static func sealedSize(of size: Int) -> Int { size + pieceCount(of: size) * tag }

    /// Where piece `index` starts and ends in the sealed bytes the relay holds.
    static func sealedRange(of index: Int) -> ClosedRange<Int> { (index * sealedPiece)...(index * sealedPiece + sealedPiece - 1) }

    private static func nonce(_ index: Int) throws -> ChaChaPoly.Nonce {
        var bytes = Data(count: 8)
        withUnsafeBytes(of: UInt32(index).bigEndian) { bytes.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: bytes)
    }

    private static func aad(_ id: String, _ index: Int, last: Bool) -> Data {
        var data = Data("pulshade-blob".utf8) + Data(id.utf8)
        withUnsafeBytes(of: UInt32(index).bigEndian) { data.append(contentsOf: $0) }
        data.append(last ? 1 : 0)
        return data
    }

    static func seal(_ plain: Data, key: Data, id: String, index: Int, last: Bool) throws -> Data {
        let box = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key), nonce: nonce(index), authenticating: aad(id, index, last: last))
        // Made into a new Data so it starts at zero, whatever slices CryptoKit handed back.
        return Data(box.ciphertext) + Data(box.tag)
    }

    static func open(_ sealed: Data, key: Data, id: String, index: Int, last: Bool) throws -> Data {
        let bytes = Data(sealed)
        guard bytes.count >= tag else { throw BlobError.damaged }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(index), ciphertext: bytes.dropLast(tag), tag: bytes.suffix(tag))
        do { return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad(id, index, last: last)) }
        catch { throw BlobError.damaged }
    }
}

enum BlobError: Error, Equatable {
    /// A piece or the whole file doesn't open or doesn't match: cut short, swapped or changed on the way.
    case damaged
    /// The file is too big for Pulshade to send or hold.
    case tooLarge
    /// The file changed on this device after it was picked, so the rest of it can't be sent with the same key.
    case changed
    /// The relay has no room for it, or the sender has used their allowance for now. Try again later.
    case relayFull
    /// The relay no longer has it: erased by its sender, or expired.
    case gone
    case unreadable
    case cancelled
    /// A picture whose hidden details (location, camera, time) couldn't be taken out, so it wasn't sent.
    case notCleaned

    var words: String {
        switch self {
        case .damaged: "The file didn't arrive intact."
        case .tooLarge: "That file is too big. Pulshade sends files up to 100 MB."
        case .changed: "The file changed while it was being sent. Send it again."
        case .relayFull: "The server is full right now. Try again in a little while."
        case .gone: "This file has been deleted or has expired."
        case .unreadable: "Pulshade couldn't read that file."
        case .cancelled: "Cancelled."
        case .notCleaned: "Pulshade couldn't remove this picture's hidden details (such as where it was taken), so it wasn't sent."
        }
    }
}

/// Sending and receiving a file's pieces. Nothing here writes to disk.
enum BlobTransfer {
    /// A file as it will be sent: what the message needs, made by reading the file once from start to end.
    struct Prepared {
        var attachment: Attachment
        /// A file on disk (picked by the person), or nil when the bytes are in memory (a clip the app just made).
        var url: URL?
        var memory: Data?
        /// SHA-256 of each piece of the file as it was read then. Each piece is sealed under the attachment's key with its
        /// position as the nonce, so it may only ever be sealed with these bytes: a file changed on disk before an upload
        /// is tried again (or resumed) would otherwise put two different pieces under one key and nonce. A piece that no
        /// longer matches stops the upload (`BlobError.changed`).
        var pieceHashes: [Data] = []
    }

    /// A clip or picture already in memory: its size and hash, key and secret. For media the app makes itself.
    static func prepare(data: Data, kind: Attachment.Kind, lifetime: TimeInterval = 7 * 24 * 3600) throws -> Prepared {
        guard !data.isEmpty else { throw BlobError.unreadable }
        guard data.count <= BlobCrypto.maxFile else { throw BlobError.tooLarge }
        var attachment = Attachment(id: Data.random(16).hex, key: .random(32), size: data.count, kind: kind, name: nil, type: nil,
                                    sha256: Data(SHA256.hash(data: data)), secret: .random(32), expires: RelayClock.now.addingTimeInterval(lifetime))
        attachment.padded = BlobPadding.padded(attachment.sealedSize)
        let pieces = (0..<attachment.pieceCount).map { index -> Data in
            let start = index * BlobCrypto.plainPiece
            return Data(SHA256.hash(data: data.subdata(in: start..<min(start + BlobCrypto.plainPiece, data.count))))
        }
        return Prepared(attachment: attachment, url: nil, memory: data, pieceHashes: pieces)
    }

    /// Reads the file once to find its size and hash, and makes its key and secret. Never holds more than a piece.
    static func prepare(_ url: URL, kind: Attachment.Kind = .file, lifetime: TimeInterval = 7 * 24 * 3600) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw BlobError.unreadable }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        var pieces: [Data] = []
        while let piece = try? handle.read(upToCount: BlobCrypto.plainPiece), !piece.isEmpty {
            hash.update(data: piece)
            pieces.append(Data(SHA256.hash(data: piece)))
            size += piece.count
            if size > BlobCrypto.maxFile { throw BlobError.tooLarge }
        }
        guard size > 0 else { throw BlobError.unreadable }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
        var attachment = Attachment(id: Data.random(16).hex, key: .random(32), size: size, kind: kind, name: url.lastPathComponent,
                                    type: type, sha256: Data(hash.finalize()), secret: .random(32),
                                    expires: RelayClock.now.addingTimeInterval(lifetime))
        attachment.padded = BlobPadding.padded(attachment.sealedSize)
        // `read(upToCount:)` can hand back less than asked for, which would put the hashes out of step with the pieces.
        guard pieces.count == attachment.pieceCount else { throw BlobError.unreadable }
        return Prepared(attachment: attachment, url: url, memory: nil, pieceHashes: pieces)
    }

    /// A file picked to send: a picture with its hidden details taken out (`FileScrub`, done in memory), anything else as
    /// it is, and either way under a neutral name unless `keepName`. A picture whose details can't be taken out isn't sent.
    static func prepareForSending(_ url: URL, keepName: Bool, lifetime: TimeInterval) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        var prepared: Prepared
        if let type, FileScrub.kind(of: type) == .image {
            if let size = values?.fileSize, size > maxFileRead { throw BlobError.tooLarge }
            guard let original = try? Data(contentsOf: url) else { throw BlobError.unreadable }
            guard let clean = FileScrub.stripImage(original, type: type) else { throw BlobError.notCleaned }
            prepared = try prepare(data: clean, kind: .file, lifetime: lifetime)
            prepared.attachment.type = type.preferredMIMEType
        } else {
            prepared = try prepare(url, kind: .file, lifetime: lifetime)
        }
        prepared.attachment.name = keepName ? url.lastPathComponent : FileScrub.neutralName(for: url, type: type)
        return prepared
    }
    /// A picture is read whole to be cleaned, so only one that can be sent at all is.
    private static let maxFileRead = BlobCrypto.maxFile

    /// Seals and uploads the file, a few pieces at a time, trying a refused or failed piece again after a pause. Where
    /// the relay already holds some pieces (an upload that was interrupted), only the missing ones go. `progress` is 0...1.
    static func upload(_ prepared: Prepared, to client: RelayClient, progress: @escaping @Sendable (Double) -> Void) async throws {
        let a = prepared.attachment
        let real = a.pieceCount
        // The relay's pieces: the sealed file's, then the padding's (`BlobPadding`).
        let count = a.storedPieces
        guard prepared.pieceHashes.count == real, a.storedSize >= a.sealedSize else { throw BlobError.unreadable }
        let scoped = prepared.url?.startAccessingSecurityScopedResource() ?? false
        defer { if scoped { prepared.url?.stopAccessingSecurityScopedResource() } }
        let handle: FileHandle? = try prepared.url.map { url in
            guard let h = try? FileHandle(forReadingFrom: url) else { throw BlobError.unreadable }
            return h
        }
        defer { try? handle?.close() }
        /// One piece's worth of the file, from disk or memory.
        func readPiece(_ index: Int) throws -> Data {
            let start = index * BlobCrypto.plainPiece
            if let memory = prepared.memory { return memory.subdata(in: start..<min(start + BlobCrypto.plainPiece, memory.count)) }
            try handle?.seek(toOffset: UInt64(start))
            return try handle?.read(upToCount: BlobCrypto.plainPiece) ?? Data()
        }

        let have = (try? await client.blobHead(a.id))?.present ?? []
        var done = have.count
        progress(Double(done) / Double(count))
        var next = 0
        var running = 0
        let first = BlobStart(size: a.storedSize, secretHash: Data(SHA256.hash(data: a.secret)).hex,
                              days: max(1, min(30, Int((a.expires.timeIntervalSince(RelayClock.now) / 86_400).rounded(.up)))))

        try await withThrowingTaskGroup(of: Int.self) { group in
            func launchNext() throws -> Bool {
                while next < count, have.contains(next) { next += 1 }
                guard next < count else { return false }
                let index = next
                next += 1
                // How long this piece is on the relay: a whole one, or what's left of the stored size.
                let length = min(BlobCrypto.sealedPiece, a.storedSize - index * BlobCrypto.sealedPiece)
                var sealed = Data()
                if index < real {
                    let plain = try readPiece(index)
                    guard !plain.isEmpty else { throw BlobError.unreadable }
                    // Only the bytes this piece had when the file was read first: never other bytes under the same nonce.
                    guard Data(SHA256.hash(data: plain)) == prepared.pieceHashes[index] else { throw BlobError.changed }
                    sealed = try BlobCrypto.seal(plain, key: a.key, id: a.id, index: index, last: index == real - 1)
                }
                // The padding: random bytes, which nobody opens, after the sealed file's last piece and in the pieces after it.
                if sealed.count < length { sealed += Data.random(length - sealed.count) }
                running += 1
                group.addTask { try await put(client, a.id, index, sealed, first: first); return index }
                return true
            }
            // The first piece goes alone: it creates the file on the relay and says its size.
            if try launchNext() { _ = try await group.next(); running -= 1; done += 1; progress(Double(done) / Double(count)) }
            while running < 3, try launchNext() {}
            while running > 0 {
                _ = try await group.next()
                running -= 1
                done += 1
                progress(Double(done) / Double(count))
                _ = try launchNext()
            }
        }
    }

    private static func put(_ client: RelayClient, _ id: String, _ index: Int, _ sealed: Data, first: BlobStart) async throws {
        var delay = 1.0
        var attempts = 0
        while true {
            try Task.checkCancellation()
            do { return try await client.blobPut(id, index: index, piece: sealed, start: first) }
            catch BlobError.tooLarge { throw BlobError.tooLarge }
            catch {
                // The relay is full or busy, or the connection broke (a request is also cancelled when the app
                // switches networks): try again, a few times.
                try Task.checkCancellation()
                attempts += 1
                if attempts > 8 { throw error }
            }
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 1.7, 20)
        }
    }

    /// Fetches the sealed pieces into memory and opens them there, checking each, then the whole file. Nothing is written
    /// to disk; the bytes are the caller's to show, and to save if the person asks.
    static func download(_ a: Attachment, from client: RelayClient, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        guard a.isValid else { throw BlobError.damaged }
        let real = a.pieceCount
        // A padded file is fetched to its end, padding and all, so the relay doesn't learn the real size from what's asked for.
        let count = a.storedPieces
        var plain = Data(capacity: a.size)
        var index = 0
        let batch = 4
        while index < count {
            try Task.checkCancellation()
            let upto = min(index + batch, count)
            let low = index * BlobCrypto.sealedPiece
            let high = min(upto * BlobCrypto.sealedPiece, a.storedSize) - 1
            let sealed = try await getWithRetry(client, a.id, low...high)
            guard sealed.count == high - low + 1 else { throw BlobError.damaged }
            for piece in index..<min(upto, real) {
                let start = piece * BlobCrypto.sealedPiece - low
                // The sealed file ends at `sealedSize`; what follows in the last piece is padding.
                let end = min(start + BlobCrypto.sealedPiece, a.sealedSize - low)
                plain.append(try BlobCrypto.open(sealed.subdata(in: start..<end), key: a.key, id: a.id, index: piece, last: piece == real - 1))
            }
            index = upto
            progress(Double(index) / Double(count))
        }
        guard plain.count == a.size, Data(SHA256.hash(data: plain)) == a.sha256 else { throw BlobError.damaged }
        return plain
    }

    private static func getWithRetry(_ client: RelayClient, _ id: String, _ range: ClosedRange<Int>) async throws -> Data {
        var delay = 1.0
        for attempt in 0..<6 {
            try Task.checkCancellation()
            do { return try await client.blobGet(id, range: range) }
            catch BlobError.gone { throw BlobError.gone }
            catch { try Task.checkCancellation(); if attempt == 5 { throw error } }
            try await Task.sleep(for: .seconds(delay))
            delay = min(delay * 1.7, 15)
        }
        throw BlobError.gone
    }

    /// Asks the relay to erase the file. Best effort: if it can't be reached the file still expires on its own.
    static func erase(_ a: Attachment, from client: RelayClient) async -> Bool {
        (try? await client.blobDelete(a.id, secret: a.secret)) != nil
    }
}

/// A file on the relay that has to be erased: what the relay needs to accept the erase, and when it goes anyway.
struct BlobWipe: Codable, Equatable {
    var id: String
    var secret: Data
    var expires: Date
}

/// What the first piece of a file tells the relay.
struct BlobStart {
    var size: Int
    var secretHash: String
    var days: Int
}
