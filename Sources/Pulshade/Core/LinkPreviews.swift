import Foundation

/// Builds link previews on the sender's device. The receiver only ever sees what's inside the
/// encrypted message; it never fetches anything, so the site never learns who read it.
enum LinkPreviews {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Plain http(s) addresses only.
    static func isWebLink(_ text: String) -> Bool {
        guard text.count <= 2_000, let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    /// The first web link in some text.
    static func firstLink(in text: String) -> URL? {
        let range = NSRange(text.startIndex..., in: text)
        return detector?.matches(in: text, range: range).compactMap(\.url).first { isWebLink($0.absoluteString) }
    }

    /// Text with every web link made clickable.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let range = NSRange(text.startIndex..., in: text)
        for match in detector?.matches(in: text, range: range) ?? [] {
            guard let url = match.url, isWebLink(url.absoluteString), let r = Range(match.range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower..<upper].link = url
            out[lower..<upper].underlineStyle = .single
        }
        return out
    }

    /// Fetches the page over Tor (unless Tor is turned off) on a lane of its own, so the site sees a Tor exit
    /// rather than you, and can't be matched to your relay traffic. Only the page and one picture are fetched.
    static func fetch(_ url: URL) async -> LinkPreview? {
        guard let session = session(for: url) else { return nil }
        defer {
            session.invalidateAndCancel()
            // The next preview gets new circuits, so one site can't tie your previews together.
            if Tor.uses(url) { Tor.renew(lane: "preview") }
        }
        guard let (data, response) = await get(url, in: session, limit: 512 * 1024),
              (response.mimeType ?? "text/html").contains("html") else { return nil }
        let page = response.url ?? url
        let meta = Meta(html: String(decoding: data, as: UTF8.self))
        var image: Data?
        if let src = meta.image, let imageURL = URL(string: src, relativeTo: page)?.absoluteURL, isWebLink(imageURL.absoluteString),
           let (raw, _) = await get(imageURL, in: session, limit: 3 * 1024 * 1024),
           let picture = PlatformImage(data: raw) {
            image = cleanJPEG(picture, maxSide: 600)
        }
        let site = meta.site ?? page.host()?.replacingOccurrences(of: "www.", with: "")
        guard meta.title != nil || image != nil else { return nil }
        return LinkPreview(url: url.absoluteString, title: meta.title.map { String($0.prefix(200)) }, site: site, image: image)
    }

    /// Over Tor when it's on, like everything else. Nil when the link points into your own network.
    private static func session(for url: URL) -> URLSession? {
        guard let host = url.host()?.lowercased(), !Invite.isLocal(host) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpAdditionalHeaders = ["Accept": "text/html,image/*"]
        // A lane of its own, so previews never share circuits with your relay traffic.
        if Tor.uses(url) {
            guard (try? Tor.route(config, to: url, lane: "preview")) != nil else { return nil }
        }
        config.timeoutIntervalForRequest = Tor.uses(url) ? 30 : 8
        return URLSession(configuration: config, delegate: Redirects.shared, delegateQueue: nil)
    }

    /// Reads at most `limit` bytes; anything bigger isn't worth a preview.
    private static func get(_ url: URL, in session: URLSession, limit: Int) async -> (Data, URLResponse)? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              response.expectedContentLength <= Int64(limit) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit { return nil }
            }
        } catch { return nil }
        return (data, response)
    }

    /// A redirect never leads into your own network: the system would send that around Tor.
    private final class Redirects: NSObject, URLSessionTaskDelegate {
        static let shared = Redirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, isWebLink(url.absoluteString), let host = url.host()?.lowercased(),
                  !Invite.isLocal(host) else { return nil }
            return request
        }
    }

    /// The few tags a preview needs, read from the page's head.
    struct Meta {
        var title: String?
        var site: String?
        var image: String?

        init(html: String) {
            let head = String(html.prefix(200_000))
            var tags: [String: String] = [:]
            for match in head.matches(of: Self.metaTag) {
                let tag = String(head[match.range])
                guard let key = Self.attribute("property", in: tag) ?? Self.attribute("name", in: tag),
                      let value = Self.attribute("content", in: tag) else { continue }
                let k = key.lowercased()
                if tags[k] == nil { tags[k] = value }
            }
            let titleTag = head.firstMatch(of: Self.titleTag).flatMap { $0.output[1].substring.map(String.init) }
            title = (tags["og:title"] ?? tags["twitter:title"] ?? titleTag).flatMap(Self.clean)
            site = tags["og:site_name"].flatMap(Self.clean)
            image = tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"]
        }

        private static let metaTag = try! Regex("<meta\\s[^>]*>").ignoresCase()
        private static let titleTag = try! Regex("<title[^>]*>([^<]*)</title>").ignoresCase()

        private static func attribute(_ name: String, in tag: String) -> String? {
            let pattern = try? Regex("\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')").ignoresCase()
            guard let pattern, let match = tag.firstMatch(of: pattern) else { return nil }
            return (match.output[2].substring ?? match.output[3].substring).map { decode(String($0)) }
        }

        private static func clean(_ text: String) -> String? {
            let out = decode(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return out.isEmpty ? nil : out
        }

        private static func decode(_ text: String) -> String {
            var out = text
            for (entity, char) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                                   ("&nbsp;", " "), ("&amp;", "&")] {
                out = out.replacingOccurrences(of: entity, with: char)
            }
            return out
        }
    }
}
