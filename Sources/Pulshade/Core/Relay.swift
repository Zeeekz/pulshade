import Foundation
import CryptoKit
import Security
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A mailbox you read from. The relay stores envelopes under `sendID`, the hash
/// of the secret `receiveKey`, so giving someone the send id lets them write but never read.
struct Mailbox {
    let receiveKey: Data

    static func make() -> Mailbox { Mailbox(receiveKey: .random(32)) }
    static func sendID(for receiveKey: Data) -> Data { Data(SHA256.hash(data: receiveKey)) }

    var sendID: Data { Self.sendID(for: receiveKey) }
}

struct RelayEnvelope {
    var receiveKey: Data
    var id: UInt64
    var blob: Data
    /// When the relay took it in, by this device's clock. Relays from before that say leave it nil.
    var deposited: Date? = nil
}

/// The relay's clock, as this device sees it. Messages and envelopes are stamped by it, so a device whose own
/// clock is set wrong still dates what it sends correctly. Learnt from the `Date` header of fetches.
enum RelayClock {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var offset: TimeInterval = 0
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    /// Now, by the relay's clock.
    static var now: Date { Date().addingTimeInterval(lock.withLock { offset }) }

    /// A time by this device's clock, as the relay's clock shows it.
    static func relay(_ date: Date) -> Date { date.addingTimeInterval(lock.withLock { offset }) }

    /// A time by the relay's clock, as this device's clock shows it.
    static func local(_ date: Date) -> Date { date.addingTimeInterval(-lock.withLock { offset }) }

    /// Notes the relay's time from a response. The header is to the second, so small differences are left alone.
    static func note(_ response: URLResponse) {
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"),
              let theirs = lock.withLock({ format.date(from: header) }) else { return }
        let measured = theirs.timeIntervalSinceNow
        lock.withLock { if abs(measured - offset) > 2 { offset = abs(measured) > 2 ? measured : 0 } }
    }
}

/// Proof of work for onion requests, so that building fresh Tor circuits doesn't buy fresh rate-limit allowances
/// (relay/src/pow.rs). A fraction of a second's hashing, tied to one request and used once.
enum Work {
    static let bits = 18

    /// The `X-Pulshade-Pow` value for a request about `bound`, stamped by the relay's clock.
    static func proof(for bound: String) -> String {
        let ts = UInt64(max(0, RelayClock.now.timeIntervalSince1970))
        var nonce = UInt64.random(in: 0..<(1 << 40))
        while true {
            let digest = SHA256.hash(data: Data("pulshade.pow.v1|\(bound)|\(ts)|\(nonce)".utf8))
            if leadingZeroBits(digest) >= bits { return "\(ts):\(nonce)" }
            nonce += 1
        }
    }

    static func leadingZeroBits(_ digest: SHA256.Digest) -> Int {
        var bits = 0
        for byte in digest {
            if byte != 0 { return bits + byte.leadingZeroBitCount }
            bits += 8
        }
        return bits
    }
}

/// Pins the built-in relay's certificate on its direct, plain-HTTPS address (Tor off), as a second check
/// behind ordinary WebPKI trust. Only ever for that one host: any other relay, a self-hosted one for
/// development among them, is reached on WebPKI alone, because its certificate isn't known ahead of time —
/// Pulshade can point at someone's own relay (`PulshadeRelayDirect` in a build of your own), and there's
/// nothing here to pin it to. An onion address needs none of this either: Tor already authenticates the
/// service end to end by its address, and the direct connection to it is kept to plain `http://`.
///
/// Off unless a build sets `PulshadeRelayPin` to one or more base64 SHA-256 hashes of the relay's leaf
/// certificate (DER), comma-separated so the next certificate's hash can be published ahead of a renewal and
/// both accepted while it happens. Hashing the whole certificate rather than its key keeps the check exact
/// and easy for an operator to reproduce (`openssl x509 -in cert.pem -outform der | shasum -a 256`), at the
/// cost of a new hash to publish at every renewal rather than one that can outlive several.
final class RelayPinning: NSObject, URLSessionDelegate {
    static let shared = RelayPinning()

    #if DEBUG
    /// Tests substitute this directly; every other build fixes it at launch from the bundle.
    nonisolated(unsafe) static var pins: [String: Set<Data>] = loaded()
    #else
    static let pins: [String: Set<Data>] = loaded()
    #endif

    private static func loaded() -> [String: Set<Data>] {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "PulshadeRelayPin") as? String,
              let host = URL(string: AppData.directRelay ?? "")?.host()?.lowercased() else { return [:] }
        let hashes = Set(configured.split(separator: ",").compactMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespaces)) })
        return hashes.isEmpty ? [:] : [host: hashes]
    }

    /// Whether `host`'s pin, if it has one, accepts this leaf certificate. True when the host isn't pinned.
    static func accepts(host: String, leafDER: Data) -> Bool {
        guard let hashes = pins[host.lowercased()] else { return true }
        return hashes.contains(Data(SHA256.hash(data: leafDER)))
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard SecTrustEvaluateWithError(trust, nil),
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              Self.accepts(host: space.host, leafDER: SecCertificateCopyData(leaf) as Data) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

/// Talks to a relay over HTTP, directly or over Tor. No cookies, no cache, no identifying headers.
struct RelayClient {
    var base: URL
    /// Requests on different lanes never share a connection, so the relay can't group them by it. Over Tor
    /// each lane also has its own circuits, so they arrive from different addresses.
    var lane = "main"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]
    /// Lanes whose route has carried a request. Over Tor, a lane's first request builds its route into the onion
    /// service, which through a bridge or on a slow network can take well over a minute; given less, it gives up
    /// and starts again just before it would have got there, every time.
    nonisolated(unsafe) private static var established: Set<String> = []
    /// Through bridges everything is slower, so the first request there is given longer.
    private static var firstRequestTimeout: TimeInterval { Bridges.active ? 150 : 90 }

    /// Whether this lane already has a working route.
    var isEstablished: Bool { Self.lock.withLock { Self.established.contains(sessionName) } }

    /// This lane's connections, and over Tor its circuits too: Tor isolates by this name.
    private var sessionName: String { "\(lane)|\(base.host() ?? "")|\(Tor.uses(base))" }

    private var session: URLSession {
        get throws {
            let name = sessionName
            return try Self.lock.withLock {
                if let existing = Self.sessions[name] { return existing }
                let made = URLSession(configuration: try Self.configuration(for: base, lane: name),
                                       delegate: RelayPinning.shared, delegateQueue: nil)
                Self.sessions[name] = made
                return made
            }
        }
    }

    /// Every request goes through here. When one fails over Tor, the lane gets a fresh circuit and connection:
    /// a circuit into an onion service can stay up while carrying nothing, and every request after would hang
    /// on it until it timed out.
    private func load(_ request: URLRequest, body: Data? = nil) async throws -> (Data, URLResponse) {
        let session = try self.session
        let name = sessionName
        var request = request
        if Tor.uses(base), !isEstablished { request.timeoutInterval = max(request.timeoutInterval, Self.firstRequestTimeout) }
        do {
            let answer = if let body { try await session.upload(for: request, from: body) } else { try await session.data(for: request) }
            Self.lock.withLock { _ = Self.established.insert(name) }
            return answer
        } catch {
            // A request cancelled because another one already got through says nothing about the circuit.
            // Requests still under way on it are left to finish or time out: they may be other routes racing this one.
            // A big upload that ran out of time was slow, not proof the route is dead: throwing the route away
            // would make the next request build a new one, which can take a minute.
            let slowUpload = (error as? URLError)?.code == .timedOut && (body?.count ?? 0) > 65_536
            if Tor.uses(base), !Task.isCancelled, !slowUpload {
                Tor.renew(lane: name)
                let current = Self.lock.withLock {
                    Self.established.remove(name)
                    guard Self.sessions[name] === session else { return false }
                    Self.sessions[name] = nil
                    return true
                }
                if current { session.finishTasksAndInvalidate() }
            }
            throw error
        }
    }

    /// Points the lane's next connection at a fresh circuit, leaving those already open alone.
    func freshCircuit() {
        Tor.renew(lane: sessionName)
        Self.lock.withLock { _ = Self.established.remove(sessionName) }
    }

    /// Drops every lane's connections, so the next requests open new ones (after Tor is switched on or off).
    /// `finishing` lets requests already under way end on the old ones instead of cutting them off.
    static func closeAll(finishing: Bool = false) {
        let old = lock.withLock {
            defer { sessions = [:]; established = [] }
            return sessions.values
        }
        old.forEach { finishing ? $0.finishTasksAndInvalidate() : $0.invalidateAndCancel() }
    }

    /// The same plain configuration everywhere, calls included, over Tor when it's on.
    static func configuration(for url: URL, lane: String) throws -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "pulshade"]
        config.timeoutIntervalForRequest = 20
        if Tor.uses(url) { try Tor.route(config, to: url, lane: lane) }
        return config
    }

    func health() async -> Bool {
        // Short, so a relay that's gone shows as gone quickly. Over Tor, a new circuit into the onion often takes 10
        // to 20 seconds on a phone, so less than that would count a relay that's only slow to reach as gone.
        var request = URLRequest(url: base.appending(path: "v1/health"))
        request.timeoutInterval = Tor.uses(base) ? 45 : 15
        guard let (_, response) = try? await load(request) else { return false }
        if let boot = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Pulshade-Boot") { Self.note(boot: boot, of: base) }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Each relay's boot mark, from its health check: different every time it starts. Relays from before it say nothing.
    nonisolated(unsafe) private static var boots: [String: String] = [:]
    nonisolated(unsafe) private static var restarted: Set<String> = []

    static func note(boot: String, of base: URL) {
        let host = base.host() ?? ""
        lock.withLock {
            if let known = boots[host], known != boot { restarted.insert(host) }
            boots[host] = boot
        }
    }

    /// Whether this relay has restarted since this was last asked. A restart forgets wake-up registrations on relays
    /// that don't keep them, so the phone registers again straight away rather than at its next quarter-hour renewal.
    static func restartedSinceLastAsked(_ base: URL) -> Bool {
        let host = base.host() ?? ""
        return lock.withLock { restarted.remove(host) != nil }
    }

    /// The address the relay sees this lane's requests come from. Nil if it can't be reached or doesn't say.
    func seen() async -> String? {
        guard let (data, response) = try? await load(URLRequest(url: base.appending(path: "v1/seen"))),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `wake` says whether this is a real message, which may wake a locked iPhone; typing signals, receipts and
    /// the rest say no, so they don't make a banner. A relay from before this ignores it.
    func deposit(_ blob: Data, to sendID: Data, wake: Bool = false, ring: Bool = false) async throws {
        var request = URLRequest(url: base.appending(path: "v1/q/\(sendID.hex)"))
        request.httpMethod = "PUT"
        // A send stuck on a slow circuit gives up sooner and is tried again on the next beat. A big one is
        // given time to go: a photo is a couple of megabytes, which a slow route needs well over 20 seconds for.
        request.timeoutInterval = max(20, 20 + Double(blob.count) / 25_000)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // 2 starts a call, which rings a phone that gave the relay a call token; older relays take it as a message.
        request.setValue(ring ? "2" : wake ? "1" : "0", forHTTPHeaderField: "X-Pulshade-Wake")
        let (_, response) = try await load(request, body: blob)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 507 { throw RelayMailboxFull() }
        if status == 413 { throw RelayTooLarge() }
        guard status == 202 else { throw URLError(.badServerResponse) }
    }

    /// With `wait`, the relay holds the request open for up to that many seconds and answers the moment mail
    /// lands, so it arrives straight away instead of at the next check. Relays from before that answer at once.
    func fetch(_ receiveKeys: [Data], wait: Int = 0) async throws -> [RelayEnvelope] {
        struct Request: Encodable { var keys: [String]; var wait: Int }
        struct Item: Decodable { var k: Int; var id: UInt64; var blob: String; var age: Double? }
        struct Response: Decodable { var items: [Item] }
        var all: [RelayEnvelope] = []
        let chunks = stride(from: 0, to: receiveKeys.count, by: 256).map { Array(receiveKeys[$0..<min($0 + 256, receiveKeys.count)]) }
        for chunk in chunks {
            // Only a lane's single fetch waits; with more keys than fit in one, it's a plain check.
            let body = try JSONEncoder().encode(Request(keys: chunk.map(\.hex), wait: chunks.count == 1 ? wait : 0))
            let (data, raw) = try await post("v1/fetch", body, timeout: TimeInterval(20 + wait))
            RelayClock.note(raw)
            let response = try JSONDecoder().decode(Response.self, from: data)
            let now = Date()
            all += response.items.compactMap { item in
                guard chunk.indices.contains(item.k), let blob = Data(base64Encoded: item.blob) else { return nil }
                return RelayEnvelope(receiveKey: chunk[item.k], id: item.id, blob: blob,
                                     deposited: item.age.map { now.addingTimeInterval(-max(0, $0)) })
            }
        }
        return all
    }

    func ack(_ envelopes: [RelayEnvelope]) async throws {
        struct Ack: Encodable { var key: String; var ids: [UInt64] }
        let grouped = Dictionary(grouping: envelopes, by: \.receiveKey)
        let acks = grouped.map { Ack(key: $0.key.hex, ids: $0.value.map(\.id)) }
        _ = try await post("v1/ack", JSONEncoder().encode(["acks": acks]))
    }

    // MARK: Push

    /// Whether this relay can send wake-up pushes at all.
    func pushEnabled() async -> Bool {
        var request = URLRequest(url: base.appending(path: "v1/push"))
        request.timeoutInterval = Tor.uses(base) ? 45 : 15
        guard let (data, response) = try? await load(request), (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["enabled"] as? Bool ?? false
    }

    /// Asks the relay to wake this phone, through Apple, when mail lands in these mailboxes (256 at most per call).
    /// Holding the receive keys is what proves they're ours.
    func registerPush(keys: [Data], token: String, sandbox: Bool, sound: Bool, tone: MessageTone = .standard, voip: String? = nil) async throws {
        struct Body: Encodable { var keys: [String]; var token: String; var sandbox: Bool; var sound: Bool; var tone: String?; var voip: String? }
        var request = URLRequest(url: base.appending(path: "v1/push"))
        request.httpMethod = "PUT"
        await prove(&request, "push")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = try JSONEncoder().encode(Body(keys: keys.map(\.hex), token: token, sandbox: sandbox, sound: sound, tone: tone.relayName, voip: voip))
        let (_, response) = try await load(request, body: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 204 else { throw PushRefused(status: status) }
    }

    func unregisterPush(keys: [Data]) async throws {
        _ = try await post("v1/push/off", JSONEncoder().encode(["keys": keys.map(\.hex)]), work: "push")
    }

    /// Everything the relay holds for this device's token, for when there are no keys to name mailboxes with.
    func forgetPush(token: String) async throws {
        _ = try await post("v1/push/forget", JSONEncoder().encode(["token": token]), work: "push")
    }

    // MARK: Directory

    struct DirectoryEntry: Codable {
        var key: String
        var blob: String
        var sig: String
        var updated: UInt64
    }

    enum DirectoryError: Error { case taken, reserved, held, full, invalid, unreachable }

    /// Over the onion service, rate-limited requests carry a proof of work.
    private func prove(_ request: inout URLRequest, _ bound: String) async {
        guard Tor.isOnion(base) else { return }
        let proof = await Task.detached(priority: .userInitiated) { Work.proof(for: bound) }.value
        request.setValue(proof, forHTTPHeaderField: "X-Pulshade-Pow")
    }

    func claim(_ handle: String, _ entry: DirectoryEntry) async throws {
        var request = URLRequest(url: base.appending(path: "v1/dir/\(handle)"))
        request.httpMethod = "PUT"
        await prove(&request, "claim|\(handle)")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await load(request, body: JSONEncoder().encode(entry)),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw DirectoryError.unreachable }
        switch status {
        case 200..<300: return
        case 409: throw DirectoryError.taken
        case 403: throw DirectoryError.reserved
        case 423: throw DirectoryError.held
        case 422: throw DirectoryError.full
        default: throw DirectoryError.invalid
        }
    }

    /// Nil when nobody has that handle.
    func lookup(_ handle: String) async throws -> DirectoryEntry? {
        var request = URLRequest(url: base.appending(path: "v1/dir/\(handle)"))
        await prove(&request, "lookup|\(handle)")
        guard let (data, response) = try? await load(request),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw DirectoryError.unreachable }
        if status == 404 { return nil }
        guard status == 200 else { throw DirectoryError.invalid }
        return try JSONDecoder().decode(DirectoryEntry.self, from: data)
    }

    /// Where abuse reports go, if the admin app has set it up.
    func reportInbox() async throws -> ReportInbox? {
        guard let (data, response) = try? await load(URLRequest(url: base.appending(path: "v1/report-inbox"))),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw DirectoryError.unreachable }
        if status == 404 { return nil }
        guard status == 200 else { throw DirectoryError.invalid }
        return try JSONDecoder().decode(ReportInbox.self, from: data)
    }

    /// Everything Pulshade has told everyone, oldest first, and the list's version. Nil when it's still `version`, the
    /// one this app already has. The same for every app, so asking says nothing about who asks.
    func announcements(since version: String?) async throws -> (list: [Announcement], version: String?)? {
        var request = URLRequest(url: base.appending(path: "v1/announcements"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let version { request.setValue(version, forHTTPHeaderField: "X-Pulshade-Version") }
        await prove(&request, "announcements")
        guard let (data, response) = try? await load(request), let http = response as? HTTPURLResponse else {
            throw DirectoryError.unreachable
        }
        if http.statusCode == 304 { return nil }
        guard http.statusCode == 200 else { throw DirectoryError.unreachable }
        return (try JSONDecoder().decode([Announcement].self, from: data), http.value(forHTTPHeaderField: "X-Pulshade-Version"))
    }

    /// Every handle this key owns. The relay only answers with a fresh signature from the key.
    func owned(key: String, sig: String, ts: UInt64) async throws -> [(handle: String, entry: DirectoryEntry)] {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        struct Owned: Decodable { var handle: String; var entry: DirectoryEntry }
        let (data, _) = try await post("v1/mine", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)), work: "mine")
        return try JSONDecoder().decode([Owned].self, from: data).map { ($0.handle, $0.entry) }
    }

    /// For an account that's burning: its handles stay unclaimable for a while, but no longer point back to its key.
    func retire(key: String, sig: String, ts: UInt64) async throws {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        _ = try await post("v1/retire", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)), work: "retire")
    }

    /// The handles held for a key it no longer lists, and when each frees up.
    func held(key: String, sig: String, ts: UInt64) async throws -> [(handle: String, until: Date)] {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        struct Held: Decodable { var handle: String; var until: UInt64 }
        let (data, _) = try await post("v1/held", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)), work: "held")
        return try JSONDecoder().decode([Held].self, from: data).map { ($0.handle, Date(timeIntervalSince1970: TimeInterval($0.until))) }
    }

    /// The collectibles the creator gave this key, and whether each has a backup code set.
    func collectibles(key: String, sig: String, ts: UInt64) async throws -> [(collectible: Collectible, coded: Bool)] {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        struct Mine: Decodable { var item: String; var serial: UInt32; var owner: Data; var sig: Data; var coded: Bool?; var limit: UInt32? }
        let (data, _) = try await post("v1/collectibles", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)), work: "collectibles")
        return try JSONDecoder().decode([Mine].self, from: data).map {
            (Collectible(item: $0.item, serial: $0.serial, owner: $0.owner, sig: $0.sig, edition: $0.limit), $0.coded ?? false)
        }
    }

    /// Sets the backup code (only its hash travels) for one of this key's collectibles.
    func setCollectibleCode(key: String, sig: String, ts: UInt64, item: String, serial: UInt32, hash: Data) async throws {
        struct Set: Encodable { var key: String; var sig: String; var ts: UInt64; var item: String; var serial: UInt32; var hash: String }
        _ = try await post("v1/collectibles/code", JSONEncoder().encode(Set(key: key, sig: sig, ts: ts, item: item, serial: serial,
                                                                              hash: hash.base64EncodedString())))
    }

    enum ClaimError: Error { case unknownCode, unreachable }

    /// Brings back what a backup code belongs to, for this key. Returns the item and number of each.
    func claimCollectibles(key: String, sig: String, ts: UInt64, code: String) async throws -> [(item: String, serial: UInt32)] {
        struct Claim: Encodable { var key: String; var sig: String; var ts: UInt64; var code: String }
        struct Claimed: Decodable { var item: String; var serial: UInt32 }
        var request = URLRequest(url: base.appending(path: "v1/collectibles/claim"))
        await prove(&request, "collectible-claim")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await load(request, body: JSONEncoder().encode(Claim(key: key, sig: sig, ts: ts, code: code))),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw ClaimError.unreachable }
        if status == 404 { throw ClaimError.unknownCode }
        guard status == 200 else { throw ClaimError.unreachable }
        return try JSONDecoder().decode([Claimed].self, from: data).map { ($0.item, $0.serial) }
    }

    enum GiveawayError: Error { case unknownCode, full, unreachable }

    /// Enters a giveaway code for this key: which collectible it's for, and the place in line. The admin app then signs
    /// it over, in that order.
    func claimGiveaway(key: String, sig: String, ts: UInt64, code: String) async throws -> (item: String, place: Int) {
        struct Entry: Encodable { var key: String; var sig: String; var ts: UInt64; var code: String }
        struct Place: Decodable { var item: String; var place: Int }
        var request = URLRequest(url: base.appending(path: "v1/collectibles/giveaway"))
        await prove(&request, "giveaway-claim")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await load(request, body: JSONEncoder().encode(Entry(key: key, sig: sig, ts: ts, code: code))),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw GiveawayError.unreachable }
        if status == 404 || status == 403 { throw GiveawayError.unknownCode }
        if status == 410 { throw GiveawayError.full }
        guard status == 200 else { throw GiveawayError.unreachable }
        let place = try JSONDecoder().decode(Place.self, from: data)
        return (place.item, place.place)
    }

    /// An egg the creator gave this key, as the relay reports it. It never says what's inside.
    struct EggInfo: Decodable, Identifiable, Equatable {
        var id: String
        var kind: String
        /// When it will be ready, on the relay's clock (seconds since 1970), once it has been started.
        var hatches_at: UInt64?
        var seconds: UInt64
        /// The relay's clock when this was said.
        var now: UInt64
    }

    enum HatchError: Error { case notStarted, notReady, soldOut, unreachable }

    /// The eggs this key holds.
    func eggs(key: String, sig: String, ts: UInt64) async throws -> [EggInfo] {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        let (data, _) = try await post("v1/eggs", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)), work: "eggs")
        return try JSONDecoder().decode([EggInfo].self, from: data)
    }

    private struct EggAction: Encodable { var key: String; var sig: String; var ts: UInt64; var id: String }

    /// Puts an egg to hatch.
    func startEgg(key: String, sig: String, ts: UInt64, id: String) async throws -> EggInfo {
        let (data, _) = try await post("v1/eggs/start", JSONEncoder().encode(EggAction(key: key, sig: sig, ts: ts, id: id)))
        return try JSONDecoder().decode(EggInfo.self, from: data)
    }

    /// Opens an egg that's ready, and returns the pet inside (checked by the caller against the relay's key).
    func hatchEgg(key: String, sig: String, ts: UInt64, id: String) async throws -> Collectible {
        struct Mine: Decodable { var item: String; var serial: UInt32; var owner: Data; var sig: Data; var limit: UInt32? }
        var request = URLRequest(url: base.appending(path: "v1/eggs/hatch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await load(request, body: JSONEncoder().encode(EggAction(key: key, sig: sig, ts: ts, id: id))),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw HatchError.unreachable }
        switch status {
        case 200:
            let m = try JSONDecoder().decode(Mine.self, from: data)
            return Collectible(item: m.item, serial: m.serial, owner: m.owner, sig: m.sig, edition: m.limit)
        case 409: throw HatchError.notStarted
        case 425: throw HatchError.notReady
        case 410: throw HatchError.soldOut
        default: throw HatchError.unreachable
        }
    }

    /// Gives one of this key's collectibles to another account.
    func giftCollectible(key: String, sig: String, ts: UInt64, item: String, serial: UInt32, to: String) async throws {
        struct Gift: Encodable { var key: String; var sig: String; var ts: UInt64; var item: String; var serial: UInt32; var to: String }
        _ = try await post("v1/collectibles/gift", JSONEncoder().encode(Gift(key: key, sig: sig, ts: ts, item: item, serial: serial, to: to)))
    }

    /// Lets one of this key's collectibles go for good.
    func releaseCollectible(key: String, sig: String, ts: UInt64, item: String, serial: UInt32) async throws {
        struct Release: Encodable { var key: String; var sig: String; var ts: UInt64; var item: String; var serial: UInt32 }
        _ = try await post("v1/collectibles/release", JSONEncoder().encode(Release(key: key, sig: sig, ts: ts, item: item, serial: serial)))
    }

    /// Lets go of a handle held for this key before its three months are up.
    func unhold(_ handle: String, key: String, sig: String, ts: UInt64) async throws {
        struct Proof: Encodable { var key: String; var sig: String; var ts: UInt64 }
        _ = try await post("v1/dir/\(handle)/unhold", JSONEncoder().encode(Proof(key: key, sig: sig, ts: ts)))
    }

    func release(_ handle: String, sig: String, ts: UInt64) async throws {
        struct Removal: Encodable { var sig: String; var ts: UInt64 }
        _ = try await post("v1/dir/\(handle)/delete", JSONEncoder().encode(Removal(sig: sig, ts: ts)))
    }

    // MARK: Account backup

    enum BackupError: Error { case unreachable, refused }

    func putBackup(_ blob: Data, key: Data, sig: Data, ts: UInt64, forgetHash: Data? = nil) async throws {
        var request = URLRequest(url: base.appending(path: "v1/backup/\(key.hex)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = 120
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(sig.base64EncodedString(), forHTTPHeaderField: "X-Pulshade-Sig")
        request.setValue(String(ts), forHTTPHeaderField: "X-Pulshade-Ts")
        // A hash of the delete-only token the panic passcode holds; the relay keeps it beside the backup.
        if let forgetHash { request.setValue(forgetHash.hex, forHTTPHeaderField: "X-Pulshade-Forget") }
        await prove(&request, "backup|\(key.hex)")
        guard let (_, response) = try? await load(request, body: blob),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw BackupError.unreachable }
        guard (200..<300).contains(status) else { throw BackupError.refused }
    }

    /// Erases a backup with its delete-only token. The answer's status: 204 done, 410 nothing there, 401 not this
    /// token; anything else (or an error) means try again later.
    func forgetBackup(key: Data, token: Data) async throws -> Int {
        struct Body: Encodable { var token: String }
        var request = URLRequest(url: base.appending(path: "v1/backup/\(key.hex)/forget"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await load(request, body: try JSONEncoder().encode(Body(token: token.hex))),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw BackupError.unreachable }
        return status
    }

    /// Nil when there's no backup under this key.
    func backup(key: Data, sig: Data, ts: UInt64) async throws -> Data? {
        let (data, status) = try await backupRequest("get", key: key, sig: sig, ts: ts)
        if status == 404 { return nil }
        guard status == 200 else { throw BackupError.refused }
        return data
    }

    func deleteBackup(key: Data, sig: Data, ts: UInt64) async throws {
        let (_, status) = try await backupRequest("delete", key: key, sig: sig, ts: ts)
        guard (200..<300).contains(status) || status == 404 else { throw BackupError.refused }
    }

    private func backupRequest(_ action: String, key: Data, sig: Data, ts: UInt64) async throws -> (Data, Int) {
        struct Proof: Encodable { var sig: String; var ts: UInt64 }
        var request = URLRequest(url: base.appending(path: "v1/backup/\(key.hex)/\(action)"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if action == "get" { await prove(&request, "backup-read|\(key.hex)") }
        let body = try JSONEncoder().encode(Proof(sig: sig.base64EncodedString(), ts: ts))
        guard let (data, response) = try? await load(request, body: body),
              let status = (response as? HTTPURLResponse)?.statusCode else { throw BackupError.unreachable }
        return (data, status)
    }

    @discardableResult
    private func post(_ path: String, _ body: Data, timeout: TimeInterval? = nil, work: String? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: base.appending(path: path))
        if let timeout { request.timeoutInterval = timeout }
        if let work { await prove(&request, work) }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await load(request, body: body)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw URLError(.badServerResponse)
        }
        return (data, response)
    }
}

#if os(macOS)
extension RelayClient {
    /// The latest Mac release, nil when none is published. Checked against the release key by the caller.
    func latestRelease() async throws -> Release? {
        var request = URLRequest(url: base.appending(path: "v1/update/mac"))
        request.timeoutInterval = Tor.uses(base) ? 45 : 15
        let (data, response) = try await load(request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// The zipped app. Large, so it may take a few minutes over Tor.
    func releaseArchive() async throws -> Data {
        var request = URLRequest(url: base.appending(path: "v1/update/mac.zip"))
        request.timeoutInterval = 120
        await prove(&request, "update")
        let (data, response) = try await load(request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
#endif

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// The mailbox being written to is full. Says nothing about the relay as a whole.
struct RelayMailboxFull: Error {}
/// The relay refuses this envelope for its size, and always will.
struct RelayTooLarge: Error {}

/// The relay said no to a push registration; `status` is its answer.
struct PushRefused: Error { var status: Int }
