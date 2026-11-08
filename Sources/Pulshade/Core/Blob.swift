import Foundation
import CryptoKit

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

    /// Whether a received attachment is well-formed, so nothing odd gets as far as the network.
    var isValid: Bool {
        id.count == 32 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase } && key.count == 32 && secret.count == 32 && sha256.count == 32
            && (1...BlobCrypto.maxFile).contains(size) && (name?.count ?? 0) <= 255 && (type?.count ?? 0) <= 100
    }

    /// The name to show: no folders, no control characters, never empty.
    var shownName: String {
        let base = (name ?? "").split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = String(base.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
        return clean.trimmingCharacters(in: .whitespaces).isEmpty ? "File" : clean
    }

    var sealedSize: Int { BlobCrypto.sealedSize(of: size) }
    var pieceCount: Int { BlobCrypto.pieceCount(of: size) }
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
    /// The relay has no room for it, or the sender has used their allowance for now. Try again later.
    case relayFull
    /// The relay no longer has it: erased by its sender, or expired.
    case gone
    case unreadable
    case cancelled

    var words: String {
        switch self {
        case .damaged: "The file didn't arrive intact."
        case .tooLarge: "That file is too big. Pulshade sends files up to 100 MB."
        case .relayFull: "The server is full right now. Try again in a little while."
        case .gone: "This file has been deleted or has expired."
        case .unreadable: "Pulshade couldn't read that file."
        case .cancelled: "Cancelled."
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
    }

    /// A clip or picture already in memory: its size and hash, key and secret. For media the app makes itself.
    static func prepare(data: Data, kind: Attachment.Kind, lifetime: TimeInterval = 7 * 24 * 3600) throws -> Prepared {
        guard !data.isEmpty else { throw BlobError.unreadable }
        guard data.count <= BlobCrypto.maxFile else { throw BlobError.tooLarge }
        let attachment = Attachment(id: Data.random(16).hex, key: .random(32), size: data.count, kind: kind, name: nil, type: nil,
                                    sha256: Data(SHA256.hash(data: data)), secret: .random(32), expires: RelayClock.now.addingTimeInterval(lifetime))
        return Prepared(attachment: attachment, url: nil, memory: data)
    }

    /// Reads the file once to find its size and hash, and makes its key and secret. Never holds more than a piece.
    static func prepare(_ url: URL, kind: Attachment.Kind = .file, lifetime: TimeInterval = 7 * 24 * 3600) throws -> Prepared {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw BlobError.unreadable }
        defer { try? handle.close() }
        var hash = SHA256()
        var size = 0
        while let piece = try? handle.read(upToCount: BlobCrypto.plainPiece), !piece.isEmpty {
            hash.update(data: piece)
            size += piece.count
            if size > BlobCrypto.maxFile { throw BlobError.tooLarge }
        }
        guard size > 0 else { throw BlobError.unreadable }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.preferredMIMEType
        let attachment = Attachment(id: Data.random(16).hex, key: .random(32), size: size, kind: kind, name: url.lastPathComponent,
                                    type: type, sha256: Data(hash.finalize()), secret: .random(32),
                                    expires: RelayClock.now.addingTimeInterval(lifetime))
        return Prepared(attachment: attachment, url: url, memory: nil)
    }

    /// Seals and uploads the file, a few pieces at a time, trying a refused or failed piece again after a pause. Where
    /// the relay already holds some pieces (an upload that was interrupted), only the missing ones go. `progress` is 0...1.
    static func upload(_ prepared: Prepared, to client: RelayClient, progress: @escaping @Sendable (Double) -> Void) async throws {
        let a = prepared.attachment
        let count = a.pieceCount
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
        let first = BlobStart(size: a.sealedSize, secretHash: Data(SHA256.hash(data: a.secret)).hex,
                              days: max(1, min(7, Int((a.expires.timeIntervalSince(RelayClock.now) / 86_400).rounded(.up)))))

        try await withThrowingTaskGroup(of: Int.self) { group in
            func launchNext() throws -> Bool {
                while next < count, have.contains(next) { next += 1 }
                guard next < count else { return false }
                let index = next
                next += 1
                let plain = try readPiece(index)
                guard !plain.isEmpty else { throw BlobError.unreadable }
                let sealed = try BlobCrypto.seal(plain, key: a.key, id: a.id, index: index, last: index == count - 1)
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
        let count = a.pieceCount
        var plain = Data(capacity: a.size)
        var index = 0
        let batch = 4
        while index < count {
            try Task.checkCancellation()
            let upto = min(index + batch, count)
            let low = index * BlobCrypto.sealedPiece
            let high = min(upto * BlobCrypto.sealedPiece, a.sealedSize) - 1
            let sealed = try await getWithRetry(client, a.id, low...high)
            guard sealed.count == high - low + 1 else { throw BlobError.damaged }
            for piece in index..<upto {
                let start = piece * BlobCrypto.sealedPiece - low
                let end = min(start + BlobCrypto.sealedPiece, sealed.count)
                plain.append(try BlobCrypto.open(sealed.subdata(in: start..<end), key: a.key, id: a.id, index: piece, last: piece == count - 1))
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
