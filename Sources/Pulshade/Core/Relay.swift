import Foundation
import CryptoKit
import CommonCrypto
import Security
import os
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

    /// A relay can correct a clock that is wrong, but not by an unbounded amount: a hostile relay must not be able
    /// to date messages months away, expiring everything or bringing old disappearing messages back.
    private static let maxSkew: TimeInterval = 7 * 86_400

    /// Notes the relay's time from a response. The header is to the second, so small differences are left alone.
    static func note(_ response: URLResponse) {
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Date"),
              let theirs = lock.withLock({ format.date(from: header) }) else { return }
        let measured = theirs.timeIntervalSinceNow
        let bounded = min(max(measured, -maxSkew), maxSkew)
        lock.withLock { if abs(bounded - offset) > 2 { offset = abs(bounded) > 2 ? bounded : 0 } }
    }
}

/// Proof of work for onion requests, so that building fresh Tor circuits doesn't buy fresh rate-limit allowances.
/// Tied to one request and used once. How much work depends on the route (`light`, `heavy`) and, when the relay is busy
/// or one circuit has been asking a lot, on what the relay asks for: it answers a request whose proof was too light
/// with `X-Pulshade-Pow-Bits`, and the request is made again with that much work (see `RelayClient.load`).
/// The relay's `pow.rs` has the same table; the hash is SHA-256 over `pulshade.pow.v2|<bound>|<seconds>|<nonce>`, and
/// the header reads `2:<seconds>:<nonce>`. The first form (`<seconds>:<nonce>`, 18 bits) is no longer accepted.
enum Work {
    static let light = 21
    static let heavy = 23
    /// The most work ever done for one request: a few seconds on a recent iPhone, asked for only of a caller already
    /// sending far more than an ordinary account does, or when the relay is under a flood.
    static let ceiling = 27

    /// Routes that cost the relay more (a claim, a backup, a burn, a push registration, a new group mailbox).
    private static let heavyRoutes: Set<Substring> = ["claim", "retire", "backup", "burn", "push", "group", "giveaway-claim", "collectible-claim"]

    static func baseBits(for bound: String) -> Int {
        heavyRoutes.contains(bound.split(separator: "|", maxSplits: 1).first ?? "") ? heavy : light
    }

    /// What the relay last said it wants, by route, so the next request starts there: for ten minutes at most, and one bit
    /// lower for every `decayEvery` of requests that go through at it (`accepted`), so a flood that has passed stops costing
    /// every request seconds of work well before the ten minutes are up. If the relay still wants more, it says so again.
    private static let learned = OSAllocatedUnfairLock(initialState: [String: (bits: Int, until: Date, stepped: Date)]())
    static let decayEvery: TimeInterval = 60
    /// The route each header was made for, until its answer is in, so a refusal can be made again.
    private static let made = OSAllocatedUnfairLock(initialState: [String: String]())

    private static func route(_ bound: String) -> String { String(bound.split(separator: "|", maxSplits: 1).first ?? "") }

    static func bits(for bound: String) -> Int {
        let known = learned.withLock { $0[route(bound)].flatMap { $0.until > Date() ? $0.bits : nil } } ?? 0
        return min(max(baseBits(for: bound), known), ceiling)
    }

    static func learn(_ bits: Int, for bound: String, now: Date = Date()) {
        guard (1...ceiling).contains(bits) else { return }
        learned.withLock { $0[route(bound)] = (bits, now.addingTimeInterval(600), now) }
    }

    /// A request about `bound` was accepted: if what is being asked for is above the route's base, step it down one bit once
    /// `decayEvery` has passed since it was raised or last lowered, and forget it when it reaches the base.
    static func accepted(_ bound: String, now: Date = Date()) {
        let key = route(bound), base = baseBits(for: bound)
        learned.withLock { table in
            guard let entry = table[key] else { return }
            guard entry.until > now, entry.bits > base else { table[key] = nil; return }
            guard now.timeIntervalSince(entry.stepped) >= decayEvery else { return }
            table[key] = entry.bits - 1 > base ? (entry.bits - 1, entry.until, now) : nil
        }
    }

    /// Tells `accepted` about the proof a request carried, once its answer shows it was taken.
    static func accepted(header value: String) {
        if let bound = bound(ofHeader: value) { accepted(bound) }
    }

    /// The `X-Pulshade-Pow` value for a request about `bound`, stamped by the relay's clock.
    static func header(for bound: String, bits: Int? = nil) -> String {
        let proof = proof(for: bound, bits: bits ?? self.bits(for: bound))
        made.withLock { if $0.count > 64 { $0.removeAll() }; $0[proof] = bound }
        return proof
    }

    static func bound(ofHeader value: String) -> String? { made.withLock { $0.removeValue(forKey: value) } }

    static func proof(for bound: String, bits: Int) -> String {
        let ts = UInt64(max(0, RelayClock.now.timeIntervalSince1970))
        let found = solve(prefix: "pulshade.pow.v2|\(bound)|\(ts)|", bits: bits)
        return "2:\(ts):\(found)"
    }

    /// Finds a nonce whose hash has `bits` leading zero bits. The prefix is hashed once and each try copies that state, which
    /// is about twenty times faster than building a string per try, and the search is spread over the cores (a few, so
    /// the phone stays responsive): a heavy route takes a fraction of a second on a recent iPhone.
    static func solve(prefix: String, bits: Int, threads: Int = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 1))) -> UInt64 {
        var base = CC_SHA256_CTX()
        CC_SHA256_Init(&base)
        let bytes = Array(prefix.utf8)
        _ = bytes.withUnsafeBufferPointer { CC_SHA256_Update(&base, $0.baseAddress, CC_LONG(bytes.count)) }
        let start = UInt64.random(in: 0..<(1 << 40))
        let state = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        let stop = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.concurrentPerform(iterations: threads) { lane in
            var digits = [UInt8](repeating: 0, count: 20)
            var out = [UInt8](repeating: 0, count: 32)
            var nonce = start &+ UInt64(lane)
            var tries = 0
            while true {
                tries += 1
                if tries & 0x3fff == 0, stop.withLock({ $0 }) { return }
                var ctx = base
                var v = nonce
                var i = 20
                repeat { i -= 1; digits[i] = UInt8(48 + v % 10); v /= 10 } while v > 0
                digits.withUnsafeBufferPointer { _ = CC_SHA256_Update(&ctx, $0.baseAddress! + i, CC_LONG(20 - i)) }
                _ = CC_SHA256_Final(&out, &ctx)
                if leadingZeroBits(out) >= bits {
                    state.withLock { if $0 == nil { $0 = nonce } }
                    stop.withLock { $0 = true }
                    return
                }
                nonce &+= UInt64(threads)
            }
        }
        return state.withLock { $0 } ?? 0
    }

    static func leadingZeroBits(_ digest: [UInt8]) -> Int {
        var bits = 0
        for byte in digest {
            if byte != 0 { return bits + byte.leadingZeroBitCount }
            bits += 8
        }
        return bits
    }

    static func leadingZeroBits(_ digest: SHA256.Digest) -> Int { leadingZeroBits(Array(digest)) }
}

/// Pins the built-in relay's certificate on its direct, plain-HTTPS address (Tor off), as a second check
/// behind ordinary WebPKI trust. Only ever for that one host: any other relay, a self-hosted one for
/// development among them, is reached on WebPKI alone, because its certificate isn't known ahead of time —
/// Pulshade can point at someone's own relay (`PulshadeRelayDirect` in a build of your own), and there's
/// nothing here to pin it to. An onion address needs none of this either: Tor already authenticates the
/// service end to end by its address, and the direct connection to it is kept to plain `http://`.
///
/// Off unless a build sets `PulshadeRelayPin` to one or more base64 SHA-256 hashes, comma-separated, each of
/// either the relay's leaf certificate (DER) or its public key (SubjectPublicKeyInfo). A certificate hash is
/// exact but changes at every renewal; a public-key hash survives renewals for as long as the server keeps its
/// key (Caddy's `reuse_private_keys`, set by the server installer), so the shipped app keeps working through
/// them. Listing a second hash ahead of a planned key change lets both be accepted while it happens. Both
/// hashes are easy to reproduce with openssl: `openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`.
final class RelayPinning: NSObject, URLSessionDataDelegate {
    static let shared = RelayPinning()

    // MARK: Answers read with a cap

    /// One answer being read. The relay is not trusted to keep to the size it announces, so reading stops, and the
    /// connection is dropped, the moment either the announced length or what has actually arrived passes the cap.
    private final class Collected {
        let limit: Int
        var data = Data()
        var response: URLResponse?
        var tooBig = false
        let finish: (Result<(Data, URLResponse), Error>) -> Void
        init(limit: Int, finish: @escaping (Result<(Data, URLResponse), Error>) -> Void) {
            self.limit = limit
            self.finish = finish
        }
    }

    private let collecting = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Collected]())

    /// Sends the request and returns its answer, failing with `dataLengthExceedsMaximum` (and cancelling the
    /// transfer) if the body is, or turns out to be, more than `limit` bytes.
    func collect(_ request: URLRequest, body: Data?, in session: URLSession, limit: Int) async throws -> (Data, URLResponse) {
        let task = body.map { session.uploadTask(with: request, from: $0) } ?? session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                let entry = Collected(limit: limit) { continuation.resume(with: $0) }
                collecting.withLock { $0[ObjectIdentifier(task)] = entry }
                task.resume()
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let refuse = collecting.withLock { open -> Bool in
            guard let entry = open[ObjectIdentifier(dataTask)] else { return false }
            entry.response = response
            if response.expectedContentLength > Int64(entry.limit) { entry.tooBig = true }
            return entry.tooBig
        }
        completionHandler(refuse ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let exceeded = collecting.withLock { open -> Bool in
            guard let entry = open[ObjectIdentifier(dataTask)] else { return false }
            entry.data.append(data)
            if entry.data.count > entry.limit { entry.tooBig = true; entry.data = Data() }
            return entry.tooBig
        }
        if exceeded { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = collecting.withLock({ $0.removeValue(forKey: ObjectIdentifier(task)) }) else { return }
        if entry.tooBig {
            entry.finish(.failure(URLError(.dataLengthExceedsMaximum)))
        } else if let error {
            entry.finish(.failure(error))
        } else if let response = entry.response ?? task.response {
            entry.finish(.success((entry.data, response)))
        } else {
            entry.finish(.failure(URLError(.badServerResponse)))
        }
    }

    #if DEBUG
    /// Tests substitute this directly; every other build fixes it at launch from the bundle.
    nonisolated(unsafe) static var pins: [String: Set<Data>] = loaded()
    #else
    static let pins: [String: Set<Data>] = loaded()
    #endif

    private static func loaded() -> [String: Set<Data>] {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "PulshadeRelayPin") as? String,
              let host = URL(string: AppData.directRelay ?? "")?.host()?.lowercased() else { return [:] }
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        // Accept a file's trailing newlines as well as spaces around each comma-separated hash.
        let hashes = Set(configured.split(separator: ",").compactMap {
            Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
        // A pin was configured but nothing usable parsed: fail closed for this host rather than quietly fall
        // back to plain WebPKI trust while believing the relay is pinned.
        return [host: hashes]
    }

    /// Whether `host`'s pin, if it has one, accepts this leaf certificate. True when the host isn't pinned.
    static func accepts(host: String, leafDER: Data, leafKeyInfo: Data? = nil) -> Bool {
        guard let hashes = pins[host.lowercased()] else { return true }
        if hashes.contains(Data(SHA256.hash(data: leafDER))) { return true }
        if let info = leafKeyInfo, hashes.contains(Data(SHA256.hash(data: info))) { return true }
        return false
    }

    /// The leaf's public key as DER SubjectPublicKeyInfo, the form `openssl pkey -pubin -outform der` prints. Only
    /// P-256 and P-384 keys (what Let's Encrypt issues today) are rebuilt; any other kind is left to the
    /// certificate hash.
    static func keyInfo(of certificate: SecCertificate) -> Data? {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return keyInfo(ofPoint: point)
    }

    /// `keyInfo(of:)` from the key's uncompressed point (what Security hands back for an elliptic-curve key).
    static func keyInfo(ofPoint point: Data) -> Data? {
        let header: [UInt8]
        switch point.count {
        case 65: header = [0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                           0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00]
        case 97: header = [0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
                           0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22, 0x03, 0x62, 0x00]
        default: return nil
        }
        return Data(header) + point
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
              Self.accepts(host: space.host, leafDER: SecCertificateCopyData(leaf) as Data,
                           leafKeyInfo: Self.keyInfo(of: leaf)) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// Never follow a redirect on relay traffic. The base address is the relay, so a redirect is only somewhere
    /// else to send mailbox keys and envelopes (and would skip the pin, since only the built-in host has one).
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Talks to a relay over HTTP, directly or over Tor. No cookies, no cache, no identifying headers.
struct RelayClient {
    var base: URL
    /// Requests on different lanes never share a connection, so the relay can't group them by it. Over Tor
    /// each lane also has its own circuits, so they arrive from different addresses.
    var lane = "main"

    /// Caps on what a single answer may be. Envelopes are padded to a few fixed sizes, the largest 2 MiB; a
    /// hostile or broken relay can't make the app read without bound.
    fileprivate static let maxResponse = 64 * 1024 * 1024
    private static let maxEnvelope = 4 * 1024 * 1024

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
    private func load(_ request: URLRequest, body: Data? = nil, limit: Int = RelayClient.maxResponse) async throws -> (Data, URLResponse) {
        let session = try self.session
        let name = sessionName
        var request = request
        if Tor.uses(base), !isEstablished { request.timeoutInterval = max(request.timeoutInterval, Self.firstRequestTimeout) }
        do {
            var answer = try await RelayPinning.shared.collect(request, body: body, in: session, limit: limit)
            // Too little work for this route right now: the relay says how much, and the request is made once more with it.
            if let http = answer.1 as? HTTPURLResponse, http.statusCode == 429,
               let bits = http.value(forHTTPHeaderField: "X-Pulshade-Pow-Bits").flatMap(Int.init),
               let sent = request.value(forHTTPHeaderField: "X-Pulshade-Pow"), let bound = Work.bound(ofHeader: sent),
               (1...Work.ceiling).contains(bits) {
                Work.learn(bits, for: bound)
                let again = await Task.detached(priority: .userInitiated) { Work.header(for: bound, bits: bits) }.value
                request.setValue(again, forHTTPHeaderField: "X-Pulshade-Pow")
                answer = try await RelayPinning.shared.collect(request, body: body, in: session, limit: limit)
            }
            if let http = answer.1 as? HTTPURLResponse, http.statusCode != 429, http.statusCode != 426,
               let sent = request.value(forHTTPHeaderField: "X-Pulshade-Pow") {
                Work.accepted(header: sent)
            }
            Self.lock.withLock { _ = Self.established.insert(name) }
            // Every answer carries the relay's boot mark, so a restart is noticed whatever the app was doing.
            if let boot = (answer.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Pulshade-Boot") { Self.note(boot: boot, of: base) }
            return answer
        } catch {
            // A request cancelled because another one already got through says nothing about the circuit.
            // Requests still under way on it are left to finish or time out: they may be other routes racing this one.
            // A big upload that ran out of time was slow, not proof the route is dead: throwing the route away
            // would make the next request build a new one, which can take a minute.
            let slowUpload = (error as? URLError)?.code == .timedOut && (body?.count ?? 0) > 65_536
            // Over Tor the circuit is thrown away; on a plain connection the session is, so a dead connection kept
            // alive by the system (after a network change, say) isn't reused by every request that follows.
            if !Task.isCancelled, !slowUpload {
                if Tor.uses(base) { Tor.renew(lane: name) }
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
        let name = sessionName
        if Tor.uses(base) {
            Tor.renew(lane: name)
            Self.lock.withLock { _ = Self.established.remove(name) }
        } else {
            // No circuits on a plain connection: a new session opens new connections, and requests already under
            // way on the old one finish or time out beside it.
            let old = Self.lock.withLock { () -> URLSession? in
                Self.established.remove(name)
                defer { Self.sessions[name] = nil }
                return Self.sessions[name]
            }
            old?.finishTasksAndInvalidate()
        }
    }

    /// Drops every lane's connections, so the next requests open new ones (after Tor is switched on or off).
    /// `finishing` lets requests already under way end on the old ones instead of cutting them off.
    static func closeAll(finishing: Bool = false) {
        let old = lock.withLock {
            defer { sessions = [:]; established = [] }
            return sessions.values
        }
        // Dropping them from the cache is enough for the finishing case: a request already under way keeps its
        // own reference and ends safely, and the session goes once that reference does. Invalidating it here,
        // even with `finishTasksAndInvalidate`, could catch a request that had just picked it up and make
        // CFNetwork raise "task created in a session that has been invalidated", which Swift can't catch.
        if !finishing { old.forEach { $0.invalidateAndCancel() } }
    }

    /// The same plain configuration everywhere, calls included, over Tor when it's on.
    static func configuration(for url: URL, lane: String) throws -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // A constant user agent and language, so the relay can't fingerprint a build or a locale through them.
        config.httpAdditionalHeaders = ["User-Agent": "pulshade", "Accept-Language": "en"]
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
    /// How many restarts have been seen of each relay since this launch: a counter, so each part of the app can keep
    /// its own place in it.
    nonisolated(unsafe) private static var restartCounts: [String: Int] = [:]

    static func note(boot: String, of base: URL) {
        let host = base.host() ?? ""
        lock.withLock {
            if let known = boots[host], known != boot {
                restarted.insert(host)
                restartCounts[host, default: 0] += 1
            }
            boots[host] = boot
        }
    }

    /// How many times this relay has been seen to restart since the app launched.
    static func restartCount(of base: URL) -> Int {
        let host = base.host() ?? ""
        return lock.withLock { restartCounts[host] ?? 0 }
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
    /// `recall` stamps the envelope so a Burn can take it back (see docs/burn-order.md).
    /// `life` and `collapse` mark a signal: kept only that many seconds, and replacing this sender's older copy with
    /// the same tag (see `Outgoing.life`, `Outgoing.collapse`).
    func deposit(_ blob: Data, to sendID: Data, wake: Bool = false, ring: Bool = false, recall: (n: UInt64, hash: Data)? = nil,
                 life: Int? = nil, collapse: Data? = nil) async throws {
        var request = URLRequest(url: base.appending(path: "v1/q/\(sendID.hex)"))
        request.httpMethod = "PUT"
        // A send stuck on a slow circuit gives up sooner and is tried again on the next beat. A big one is
        // given time to go: a photo is a couple of megabytes, which a slow route needs well over 20 seconds for.
        request.timeoutInterval = max(20, 20 + Double(blob.count) / 25_000)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // 2 starts a call, which rings a phone that gave the relay a call token; older relays take it as a message.
        request.setValue(ring ? "2" : wake ? "1" : "0", forHTTPHeaderField: "X-Pulshade-Wake")
        if let recall {
            request.setValue(recall.hash.hex, forHTTPHeaderField: "X-Pulshade-Recall")
            request.setValue(String(recall.n), forHTTPHeaderField: "X-Pulshade-Recall-N")
        }
        if let life { request.setValue(String(life), forHTTPHeaderField: "X-Pulshade-Life") }
        if let collapse, collapse.count == 16 { request.setValue(collapse.hex, forHTTPHeaderField: "X-Pulshade-Collapse") }
        let (_, response) = try await load(request, body: blob)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 507 { throw RelayMailboxFull() }
        if status == 413 { throw RelayTooLarge() }
        guard status == 202 else { throw RelayRefused(status: status ?? 0) }
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
            guard data.count <= Self.maxResponse else { throw URLError(.dataLengthExceedsMaximum) }
            let response = try JSONDecoder().decode(Response.self, from: data)
            let now = Date()
            all += response.items.compactMap { item in
                guard chunk.indices.contains(item.k), let blob = Data(base64Encoded: item.blob),
                      blob.count <= Self.maxEnvelope else { return nil }
                return RelayEnvelope(receiveKey: chunk[item.k], id: item.id, blob: blob,
                                     deposited: item.age.map { now.addingTimeInterval(-max(0, $0)) })
            }
        }
        return all
    }

    /// Group mail: one envelope from a group mailbox, numbered by the relay (`seq`) so a phone can ask for what came
    /// after the last it saw. Nothing is acknowledged: the relay keeps it for every member until it expires.
    struct GroupMail {
        var receiveKey: Data
        var seq: UInt64
        var blob: Data
        var deposited: Date?
    }

    /// Posts into a group mailbox (see docs/groups-design.md). Says the envelope's number, so the sender's own cursor
    /// can move past it.
    @discardableResult
    func depositGroup(_ blob: Data, to sendID: Data, days: Int, wake: Bool, prove first: Bool = false) async throws -> UInt64? {
        var request = URLRequest(url: base.appending(path: "v1/g/\(sendID.hex)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = max(20, 20 + Double(blob.count) / 25_000)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(wake ? "1" : "0", forHTTPHeaderField: "X-Pulshade-Wake")
        request.setValue(String(min(max(days, 1), 7)), forHTTPHeaderField: "X-Pulshade-Days")
        if first { await prove(&request, "group|\(sendID.hex)") }
        let (_, response) = try await load(request, body: blob)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 507 { throw RelayMailboxFull() }
        if http?.statusCode == 413 { throw RelayTooLarge() }
        guard http?.statusCode == 202 else { throw RelayRefused(status: http?.statusCode ?? 0) }
        return (http?.value(forHTTPHeaderField: "X-Pulshade-Seq")).flatMap { UInt64($0) }
    }

    /// A fetch that also reads group mailboxes, each from just after `after`. `more` says the relay had more group mail
    /// than fitted: ask again straight away with the new cursors.
    func fetch(_ receiveKeys: [Data], groups: [(key: Data, after: UInt64)], wait: Int = 0) async throws
        -> (envelopes: [RelayEnvelope], groups: [GroupMail], more: Bool) {
        guard !groups.isEmpty else { return (try await fetch(receiveKeys, wait: wait), [], false) }
        struct Cursor: Encodable { var key: String; var after: UInt64 }
        struct Request: Encodable { var keys: [String]; var wait: Int; var groups: [Cursor] }
        struct Item: Decodable { var k: Int; var id: UInt64; var blob: String; var age: Double? }
        struct GroupItem: Decodable { var g: Int; var seq: UInt64; var blob: String; var age: Double? }
        struct Response: Decodable { var items: [Item]; var groups: [GroupItem]?; var more: Bool? }
        // Group mailboxes take room in the same request, so only as many plain keys go with them as fit.
        let groups = Array(groups.prefix(256))
        let keys = Array(receiveKeys.prefix(max(0, 512 - groups.count)))
        let rest = Array(receiveKeys.dropFirst(keys.count))
        let body = try JSONEncoder().encode(Request(keys: keys.map(\.hex), wait: rest.isEmpty ? wait : 0,
                                                   groups: groups.map { Cursor(key: $0.key.hex, after: $0.after) }))
        let (data, raw) = try await post("v1/fetch", body, timeout: TimeInterval(20 + wait))
        RelayClock.note(raw)
        guard data.count <= Self.maxResponse else { throw URLError(.dataLengthExceedsMaximum) }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let now = Date()
        var envelopes = response.items.compactMap { item -> RelayEnvelope? in
            guard keys.indices.contains(item.k), let blob = Data(base64Encoded: item.blob),
                  blob.count <= Self.maxEnvelope else { return nil }
            return RelayEnvelope(receiveKey: keys[item.k], id: item.id, blob: blob, deposited: item.age.map { now.addingTimeInterval(-max(0, $0)) })
        }
        if !rest.isEmpty { envelopes += try await fetch(rest) }
        let mail = (response.groups ?? []).compactMap { item -> GroupMail? in
            guard groups.indices.contains(item.g), let blob = Data(base64Encoded: item.blob),
                  blob.count <= Self.maxEnvelope else { return nil }
            return GroupMail(receiveKey: groups[item.g].key, seq: item.seq, blob: blob, deposited: item.age.map { now.addingTimeInterval(-max(0, $0)) })
        }
        return (envelopes, mail, response.more == true)
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
        let proof = await Task.detached(priority: .userInitiated) { Work.header(for: bound) }.value
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
        guard http.statusCode == 200, data.count <= 4 * 1024 * 1024 else { throw DirectoryError.unreachable }
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
        guard status == 200, data.count <= Self.maxResponse else { throw BackupError.refused }
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
        guard data.count <= Self.maxResponse else { throw URLError(.dataLengthExceedsMaximum) }
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
        let (data, response) = try await load(request, limit: 1024 * 1024)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return nil }
        guard status == 200, data.count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// The zipped app. Large, so it may take a few minutes over Tor.
    func releaseArchive(maxBytes: Int = 256 * 1024 * 1024) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "v1/update/mac.zip"))
        request.timeoutInterval = 120
        await prove(&request, "update")
        let (data, response) = try await load(request, limit: maxBytes)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
#endif

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    /// The bytes a string of hex digits names. Nil if it isn't an even number of them.
    init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = Data(capacity: chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 97...102: c - 87; case 65...70: c - 55; default: nil }
        }
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
        }
        self = out
    }
}

/// The mailbox being written to is full. Says nothing about the relay as a whole.
struct RelayMailboxFull: Error {}
/// The relay refuses this envelope for its size, and always will.
struct RelayTooLarge: Error {}
/// The relay answered, but not with "taken". 429 is this connection sending too much this hour, 503 a relay
/// pausing (a handover), anything else a refusal of this one envelope.
struct RelayRefused: Error { var status: Int }

/// The relay said no to a push registration; `status` is its answer.
struct PushRefused: Error { var status: Int }

// MARK: Files kept on the relay (see docs/blob-store.md)

/// What the relay says about a file it holds.
struct BlobHead {
    var size: Int
    var complete: Bool
    var expires: Date
    /// Which pieces have arrived.
    var present: Set<Int>
}

extension RelayClient {
    /// Uploads one sealed piece. The first piece also names the file's size, the hash of its erase secret and its lifetime.
    func blobPut(_ id: String, index: Int, piece: Data, start: BlobStart) async throws {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)/\(index)"))
        request.httpMethod = "PUT"
        request.timeoutInterval = max(40, 40 + Double(piece.count) / 15_000)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        // Every piece says it, so they can go in any order.
        request.setValue(String(start.size), forHTTPHeaderField: "X-Pulshade-Blob-Size")
        request.setValue(start.secretHash, forHTTPHeaderField: "X-Pulshade-Blob-Delete")
        request.setValue(String(start.days), forHTTPHeaderField: "X-Pulshade-Blob-Days")
        let (_, response) = try await load(request, body: piece)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 202: return
        case 413: throw BlobError.tooLarge
        case 507, 429, 503: throw BlobError.relayFull
        default: throw URLError(.badServerResponse)
        }
    }

    /// Nil when the relay doesn't have the file (never uploaded, erased or expired).
    func blobHead(_ id: String) async throws -> BlobHead? {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)/head"))
        request.timeoutInterval = Tor.uses(base) ? 45 : 15
        let (data, response) = try await load(request)
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 404 { return nil }
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = object["size"] as? Int, let complete = object["complete"] as? Bool else { throw URLError(.badServerResponse) }
        let bytes = Data(hexString: object["have"] as? String ?? "") ?? Data()
        var present = Set<Int>()
        for (n, byte) in bytes.enumerated() { for bit in 0..<8 where byte & (1 << bit) != 0 { present.insert(n * 8 + bit) } }
        return BlobHead(size: size, complete: complete, expires: Date(timeIntervalSince1970: (object["expires"] as? Double) ?? 0),
                        present: present)
    }

    /// A part of the sealed file, by byte range.
    func blobGet(_ id: String, range: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)"))
        request.timeoutInterval = max(40, 40 + Double(range.count) / 15_000)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await load(request, limit: 8 * 1024 * 1024)
        switch (response as? HTTPURLResponse)?.statusCode {
        case 206, 200:
            // A download asks for four pieces at a time (4 MiB). Anything much beyond that is a relay ignoring
            // the range and trying to make the phone hold the whole file at once.
            guard data.count <= 8 * 1024 * 1024 else { throw BlobError.damaged }
            return data
        case 404: throw BlobError.gone
        case 429, 503: throw BlobError.relayFull
        default: throw URLError(.badServerResponse)
        }
    }

    /// Says who is to collect the file: a hash of each person's one-time token and how many of their devices will. The relay
    /// erases the file when all of them have.
    func blobReaders(_ id: String, secret: Data, readers: [(hash: Data, uses: Int)]) async throws {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)/readers"))
        request.httpMethod = "PUT"
        request.timeoutInterval = Tor.uses(base) ? 60 : 20
        request.setValue(secret.hex, forHTTPHeaderField: "X-Pulshade-Blob-Secret")
        var body = Data()
        for reader in readers { body += reader.hash; body.append(UInt8(max(1, min(16, reader.uses)))) }
        let (_, response) = try await load(request, body: body)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    /// This phone has the whole file: spends its token.
    func blobDone(_ id: String, token: Data) async throws {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)/done"))
        request.httpMethod = "POST"
        request.timeoutInterval = Tor.uses(base) ? 60 : 20
        let (_, response) = try await load(request, body: token)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    /// Sends a burn order (see `BurnOrder`): the relay erases what it names. Done is 204; the same order may be sent again.
    func burn(_ body: Data) async throws {
        var request = URLRequest(url: base.appending(path: "v1/burn"))
        request.httpMethod = "POST"
        request.timeoutInterval = Tor.uses(base) ? 90 : 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await load(request, body: body)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }

    /// Erases the file. Already gone counts as done; a wrong secret is an error.
    func blobDelete(_ id: String, secret: Data) async throws {
        var request = URLRequest(url: base.appending(path: "v1/blob/\(id)/delete"))
        request.httpMethod = "POST"
        request.timeoutInterval = Tor.uses(base) ? 60 : 20
        let (_, response) = try await load(request, body: secret)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw URLError(.badServerResponse) }
    }
}
