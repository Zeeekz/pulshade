import UserNotifications
import Foundation
import CryptoKit

/// Pulshade's notification helper. iOS runs it for a few seconds whenever a message push arrives, even with the
/// phone locked or the app swiped away. It confirms to friends that their messages reached this phone (see
/// `LockedDelivery`), then shows the notification exactly as it came: "New message", nothing more.
///
/// It never opens a message. Short mail (texts, receipts, reactions) it takes off the relay into a sealed inbox on the
/// phone, so it's gone from the server within seconds; Pulshade reads it from there. Photos, videos and story pieces
/// stay on the relay for Pulshade itself: they're too big for the few seconds and little memory the helper gets.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var content: UNNotificationContent?
    private var finish: ((UNNotificationContent) -> Void)?
    private var work: Task<Void, Never>?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            content = request.content
            finish = contentHandler
        }
        work = Task { [weak self] in
            await Helper.confirm()
            self?.done()
        }
    }

    /// iOS is about to stop the helper: the notification goes as it came.
    override func serviceExtensionTimeWillExpire() {
        work?.cancel()
        done()
    }

    private func done() {
        let (handler, shown) = lock.withLock { () -> (((UNNotificationContent) -> Void)?, UNNotificationContent?) in
            defer { finish = nil }
            return (finish, content)
        }
        if let handler, let shown { handler(shown) }
    }
}

private enum Helper {
    /// Collects what's new (leaving it on the relay), works out the notes and sends them. Quietly does nothing when
    /// there's no bundle: the feature is off, or Pulshade hasn't been opened since it was installed.
    static func confirm() async {
        guard let bundle = HelperStore.load(), let base = URL(string: bundle.relay), !bundle.friends.isEmpty else { return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        // The same constant the app sends, so helper traffic doesn't stand out as a different client.
        config.httpAdditionalHeaders = ["User-Agent": "pulshade", "Accept-Language": "en"]
        let session = URLSession(configuration: config, delegate: Pinning(host: base.host()), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let fetched = await fetch(bundle.receiveKeys, from: base, in: session)
        guard !fetched.isEmpty, !Task.isCancelled else { return }
        let mail = fetched.map(\.mail)

        // Short mail into the inbox first, and only what was kept comes off the relay: saved, then acknowledged,
        // so nothing can be lost in between. A full inbox (Pulshade not opened for days) leaves the rest where it is.
        let kept = LockedDelivery.keepShortMail(fetched)
        if !kept.isEmpty, !Task.isCancelled { await acknowledge(kept, at: base, in: session) }

        let notes = LockedDelivery.notes(for: mail, bundle: bundle, confirmed: Set(HelperStore.confirmed().keys))
        var sent: [Data] = []
        for note in notes where !Task.isCancelled {
            if await deposit(note.blob, to: note.sendID, at: base, in: session) { sent += note.digests }
        }
        if !sent.isEmpty { HelperStore.remember(sent) }
    }

    typealias Fetched = LockedDelivery.Fetched

    /// What's waiting in these mailboxes. Nothing comes off the relay here.
    private static func fetch(_ keys: [Data], from base: URL, in session: URLSession) async -> [Fetched] {
        struct Item: Decodable { var k: Int; var id: UInt64; var blob: String; var age: Double? }
        struct Answer: Decodable { var items: [Item] }
        var mail: [Fetched] = []
        let now = Date()
        for start in stride(from: 0, to: keys.count, by: 256) {
            let chunk = Array(keys[start..<min(start + 256, keys.count)])
            var request = URLRequest(url: base.appending(path: "v1/fetch"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["keys": chunk.map(hex), "wait": 0]
            guard let json = try? JSONSerialization.data(withJSONObject: body),
                  let (data, response) = try? await session.upload(for: request, from: json),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let answer = try? JSONDecoder().decode(Answer.self, from: data) else { continue }
            for item in answer.items where chunk.indices.contains(item.k) {
                guard let blob = Data(base64Encoded: item.blob) else { continue }
                mail.append(Fetched(mail: .init(receiveKey: chunk[item.k], blob: blob), id: item.id,
                                    deposited: item.age.map { now.addingTimeInterval(-max(0, $0)) }))
            }
        }
        return mail
    }

    /// Takes what the inbox now holds off the relay.
    private static func acknowledge(_ items: [Fetched], at base: URL, in session: URLSession) async {
        let grouped = Dictionary(grouping: items, by: \.mail.receiveKey)
        let acks: [[String: Any]] = grouped.map { ["key": hex($0.key), "ids": $0.value.map(\.id)] }
        var request = URLRequest(url: base.appending(path: "v1/ack"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let json = try? JSONSerialization.data(withJSONObject: ["acks": acks]) else { return }
        _ = try? await session.upload(for: request, from: json)
    }

    /// Hands a note to the relay without waking anyone: it's only a tick.
    private static func deposit(_ blob: Data, to sendID: Data, at base: URL, in session: URLSession) async -> Bool {
        var request = URLRequest(url: base.appending(path: "v1/q/\(hex(sendID))"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "X-Pulshade-Wake")
        guard let (_, response) = try? await session.upload(for: request, from: blob) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 202
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

/// The same certificate pin the app uses (`RelayPinning`): when the build names the relay certificate's hashes,
/// only those are accepted. Without one, ordinary certificate checks apply, as in the app.
private final class Pinning: NSObject, URLSessionDelegate {
    private let hashes: Set<Data>?
    private let host: String?

    init(host: String?) {
        self.host = host?.lowercased()
        let configured = (Bundle.main.object(forInfoDictionaryKey: "PulshadeRelayPin") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A pin that's set but unreadable fails closed, as in the app.
        hashes = configured.isEmpty ? nil : Set(configured.split(separator: ",").compactMap {
            Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard SecTrustEvaluateWithError(trust, nil) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if let hashes, space.host.lowercased() == host {
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
                  hashes.contains(Data(SHA256.hash(data: SecCertificateCopyData(leaf) as Data))) else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// The relay address is the relay: a redirect would only take mailbox keys somewhere else.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
