import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Text pasted from a web page, Notes, Mail or a document, kept in the shape it had there: paragraphs, headings on their
/// own lines, bulleted and numbered lists (nested ones indented), table rows on one line. Messages stay plain text, so
/// every app (and every older build) reads them; the shape travels as "• ", "1. " and line breaks, which the bubble
/// lays out as a list (`ListLine`).
///
/// HTML is read by our own small reader, never by WebKit's: the system's HTML import would fetch images and styles a
/// copied page names, telling that site you pasted it. RTF (Notes, Pages, Mail) carries no addresses to fetch.
enum PastedText {
    /// More than a message can carry (20,000 characters) even after the markup goes; anything beyond is not looked at.
    static let maxInput = 2_000_000
    /// The most the readers write: five times what a message can carry, so a hostile paste can't grow without end.
    static let maxOutput = 100_000
    /// Lists nested deeper than this are shown at this depth (the bubble indents four levels at most).
    static let maxDepth = 5

    /// The text to paste from the pasteboard's flavours, best first. Nil when there is nothing better than its plain text.
    static func best(html: Data?, rtf: Data?, plain: String?) -> String? {
        if let html, html.count <= maxInput, let text = String(data: html, encoding: .utf8) ?? String(data: html, encoding: .isoLatin1) {
            let made = fromHTML(text)
            // Only if it says the same words as the page's own plain text: a page can hide text from view (CSS, the
            // `hidden` attribute), which the plain text leaves out and this reader would keep.
            if !made.isEmpty, plain.map({ letters(of: $0) == letters(of: made) }) ?? true { return made }
        }
        if let rtf, rtf.count <= maxInput, let made = fromRTF(rtf), !made.isEmpty { return made }
        if let plain, plain.utf8.count <= maxInput {
            let made = tidy(plain)
            return made == plain ? nil : made
        }
        return nil
    }

    private static func letters(of s: String) -> String { String(s.lowercased().filter(\.isLetter)) }

    // MARK: HTML

    private struct List { var ordered: Bool; var next: Int }

    static func fromHTML(_ html: String) -> String {
        var out = ""
        var lists: [List] = []
        var skipping: String?   // inside <script>, <style>, <head> or <title>: nothing in it is text
        var pre = 0
        var cellsInRow = 0
        var itemOpen = false    // a list marker was just written and nothing after it yet: a <p> inside the item stays on its line
        let chars = Array(html.unicodeScalars)
        var i = 0
        var text = ""

        func flushText() {
            guard !text.isEmpty else { return }
            var piece = decodeEntities(text)
            text = ""
            if pre == 0 {
                piece = piece.replacingOccurrences(of: "\u{00A0}", with: " ")
                piece = collapseSpaces(piece)
                // At the start of a line, leading space is only the page's indentation.
                if out.isEmpty || out.hasSuffix("\n") || out.hasSuffix(" ") { piece = String(piece.drop { $0 == " " }) }
            }
            if !piece.isEmpty { itemOpen = false }
            out += piece
        }
        func newLine() {
            if itemOpen { return }
            while out.hasSuffix(" ") { out.removeLast() }
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
        }
        func blankLine() {
            if itemOpen { return }
            newLine()
            if !out.isEmpty && !out.hasSuffix("\n\n") { out += "\n" }
        }

        while i < chars.count, out.utf8.count < maxOutput {
            if chars[i] != "<" {
                text.unicodeScalars.append(chars[i])
                i += 1
                continue
            }
            // A comment, skipped whole.
            if i + 3 < chars.count, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                var j = i + 4
                while j + 2 < chars.count, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                i = j + 3
                continue
            }
            var j = i + 1
            var quote: Unicode.Scalar?
            while j < chars.count {
                let c = chars[j]
                if let q = quote { if c == q { quote = nil } } else if c == "\"" || c == "'" { quote = c } else if c == ">" { break }
                j += 1
            }
            guard j < chars.count else { text.unicodeScalars.append(contentsOf: chars[i...]); break }
            let inside = String(String.UnicodeScalarView(chars[(i + 1)..<j]))
            i = j + 1
            let closing = inside.hasPrefix("/")
            let body = closing ? String(inside.dropFirst()) : inside
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else { continue }

            if let s = skipping {
                // What was inside (a style sheet, a script, the page title) is thrown away, never pasted.
                if closing && name == s { skipping = nil; text = "" }
                continue
            }
            if !closing, ["script", "style", "head", "title", "noscript", "template", "svg"].contains(name) {
                if !inside.hasSuffix("/") { flushText(); skipping = name }
                continue
            }
            flushText()
            switch name {
            case "br":
                if itemOpen { break }
                while out.hasSuffix(" ") { out.removeLast() }
                out += "\n"
            case "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "figure", "hr", "dl":
                if name == "pre" { pre += closing ? (pre > 0 ? -1 : 0) : 1 }
                // A paragraph inside a list item stays with its item.
                if lists.isEmpty { blankLine() } else { newLine() }
            case "div", "section", "article", "header", "footer", "main", "aside", "nav", "dt", "dd", "caption", "address":
                newLine()
            case "ul", "ol":
                itemOpen = false
                if closing {
                    if !lists.isEmpty { lists.removeLast() }
                    if lists.isEmpty { blankLine() } else { newLine() }
                } else {
                    if lists.isEmpty { blankLine() } else { newLine() }
                    lists.append(List(ordered: name == "ol", next: Self.number(attribute("start", in: body)) ?? 1))
                }
            case "li":
                guard !closing else { itemOpen = false; newLine(); break }
                itemOpen = false
                newLine()
                let depth = min(max(lists.count, 1), maxDepth)
                let indent = String(repeating: "  ", count: depth - 1)
                if var list = lists.last, list.ordered {
                    let n = Self.number(attribute("value", in: body)) ?? list.next
                    out += indent + "\(n). "
                    list.next = min(n + 1, 999)
                    lists[lists.count - 1] = list
                } else {
                    out += indent + ListLine.bullets[min(depth - 1, ListLine.bullets.count - 1)] + " "
                }
                itemOpen = true
            case "tr":
                newLine()
                cellsInRow = 0
            case "td", "th":
                if !closing {
                    if cellsInRow > 0 { while out.hasSuffix(" ") { out.removeLast() }; out += " · " }
                    cellsInRow += 1
                }
            default:
                break
            }
        }
        flushText()
        return finish(String(out.prefix(maxOutput)))
    }

    /// A list number as written in the page, kept to what the bubble shows as one (0 to 999).
    private static func number(_ s: String?) -> Int? {
        guard let s, let n = Int(s.prefix(6)) else { return nil }
        return min(max(n, 0), 999)
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: #"\b\#(name)\s*=\s*["']?([^"'\s>]+)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let found = String(tag[r])
        guard let eq = found.firstIndex(of: "=") else { return nil }
        return found[found.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func collapseSpaces(_ s: String) -> String {
        var out = ""
        var lastSpace = false
        for c in s {
            if c.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.append(c)
                lastSpace = false
            }
        }
        return out
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "mdash": "—", "ndash": "–", "hellip": "…", "bull": "•", "middot": "·", "copy": "©",
        "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°", "times": "×",
        "divide": "÷", "rarr": "→", "larr": "←", "laquo": "«", "raquo": "»", "shy": "", "zwj": "\u{200D}", "zwnj": "\u{200C}",
    ]

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = String(after[..<semi])
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[name.lowercased()]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }

    // MARK: RTF

    /// Notes, Pages and Mail: the list markers are already in the text ("\t•\t", "\t1.\t"), and each paragraph's style says
    /// how deep its list is.
    static func fromRTF(_ data: Data) -> String? {
        guard let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                      documentAttributes: nil) else { return nil }
        let whole = attributed.string as NSString
        var lines: [String] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: [.byParagraphs]) { line, range, _, _ in
            guard var line else { return }
            let style = range.length > 0 ? attributed.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            let depth = min(style?.textLists.count ?? 0, maxDepth)
            if depth > 0 {
                line = line.replacingOccurrences(of: "\u{00A0}", with: " ")
                let stripped = line.drop { $0 == "\t" || $0 == " " }
                if let item = ListLine.split(String(stripped), allowTab: true) {
                    let marker = item.ordered ? item.marker : ListLine.bullets[min(depth - 1, ListLine.bullets.count - 1)]
                    line = String(repeating: "  ", count: depth - 1) + marker + " " + item.rest
                } else {
                    line = String(repeating: "  ", count: depth - 1) + ListLine.bullets[min(depth - 1, ListLine.bullets.count - 1)] + " " + stripped
                }
            }
            lines.append(line)
        }
        return finish(tidy(lines.joined(separator: "\n")))
    }

    // MARK: Plain text

    /// Plain text as some apps put it on the pasteboard: list markers followed by tabs, odd bullet characters, no-break
    /// spaces and runs of empty lines. Put into the same shape the HTML and RTF readers make.
    static func tidy(_ plain: String) -> String {
        var lines: [String] = []
        for raw in plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).replacingOccurrences(of: "\u{00A0}", with: " ")
            let tabs = min(line.prefix { $0 == "\t" }.count, maxDepth)
            let body = String(line.drop { $0 == "\t" || $0 == " " })
            // Only lines whose marker is followed by a tab are rewritten: those came from a list. "- " typed by hand stays.
            if let item = ListLine.split(body, allowTab: true), item.viaTab {
                let depth = max(tabs, 1)
                let marker = item.ordered ? item.marker : ListLine.bullets[min(depth - 1, ListLine.bullets.count - 1)]
                line = String(repeating: "  ", count: depth - 1) + marker + " " + item.rest
            }
            while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
            lines.append(line)
        }
        return finish(lines.joined(separator: "\n"))
    }

    /// No spaces at line ends, at most one empty line in a row, none at the start or end.
    private static func finish(_ s: String) -> String {
        var lines: [Substring] = []
        var blank = 0
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var l = line
            while l.last == " " || l.last == "\t" { l.removeLast() }
            if l.isEmpty {
                blank += 1
                if blank > 1 { continue }
            } else {
                blank = 0
            }
            lines.append(l)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

/// One line of a message that is a list item: how deep it is, its marker ("•", "3."), and the words after it.
struct ListLine: Equatable {
    static let bullets = ["•", "◦", "▪"]
    private static let bulletChars: Set<Character> = ["•", "◦", "▪", "▫", "‣", "⁃", "·", "-", "*", "–", "o", "§", "\u{F0B7}"]

    var level: Int
    var marker: String
    var rest: String

    /// A line as the bubble shows it: two leading spaces per level, then a bullet or "n." / "n)", a space, and words.
    static func parse(_ line: Substring) -> ListLine? {
        let spaces = line.prefix { $0 == " " }.count
        guard let item = split(String(line.dropFirst(spaces)), allowTab: false) else { return nil }
        // "o" and "§" only count as bullets after a tab (Word); "*" and "-" typed by hand are shown as lists too.
        guard !["o", "§", "\u{F0B7}"].contains(item.marker) else { return nil }
        let marker = ["-", "*", "–", "·"].contains(item.marker) ? "•" : item.marker
        return ListLine(level: min(spaces / 2, 4), marker: marker, rest: item.rest)
    }

    /// "• words", "-\twords", "12. words", "3) words": the marker and the rest, if it is one.
    static func split(_ s: String, allowTab: Bool) -> (marker: String, rest: String, ordered: Bool, viaTab: Bool)? {
        guard let first = s.first else { return nil }
        var marker = ""
        var ordered = false
        var idx = s.startIndex
        if first.isNumber {
            while idx < s.endIndex, s[idx].isASCII, s[idx].isNumber, s.distance(from: s.startIndex, to: idx) < 3 { idx = s.index(after: idx) }
            guard idx < s.endIndex, s[idx] == "." || s[idx] == ")" else { return nil }
            idx = s.index(after: idx)
            marker = String(s[s.startIndex..<idx])
            ordered = true
        } else if bulletChars.contains(first) {
            idx = s.index(after: idx)
            marker = String(first)
        } else {
            return nil
        }
        guard idx < s.endIndex else { return nil }
        let gap = s[idx]
        guard gap == " " || (allowTab && gap == "\t") else { return nil }
        // "o" and "§" are Word's bullets only before a tab.
        if (marker == "o" || marker == "§" || marker == "\u{F0B7}") && gap != "\t" { return nil }
        let rest = s[idx...].drop { $0 == " " || $0 == "\t" }
        guard !rest.isEmpty else { return nil }
        return (marker, String(rest), ordered, gap == "\t")
    }

    /// Whether any line of the text is a list item (worth laying out as rows).
    static func hasList(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }
        return text.split(separator: "\n").contains { parse($0) != nil }
    }
}

#if os(iOS)
/// Puts `PastedText` between the pasteboard and the message box: when a paste carries HTML or RTF, the box gets the
/// shaped text instead of the system's flattening of it. Reading the pasteboard here is part of the paste itself, so
/// iOS asks nothing more.
final class ShapedPaste: NSObject, UITextPasteDelegate {
    static let shared = ShapedPaste()

    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: UITextPasteConfigurationSupporting,
                                          transform item: UITextPasteItem) {
        let provider = item.itemProvider
        let html = provider.hasItemConformingToTypeIdentifier("public.html") ? "public.html" : nil
        let rtf = provider.hasItemConformingToTypeIdentifier("public.rtf") ? "public.rtf" : nil
        guard html != nil || rtf != nil || provider.hasItemConformingToTypeIdentifier("public.plain-text") else {
            item.setDefaultResult()
            return
        }
        Task {
            let h = html == nil ? nil : await Self.load(provider, "public.html")
            let r = rtf == nil ? nil : await Self.load(provider, "public.rtf")
            let plain = (await Self.load(provider, "public.utf8-plain-text")).flatMap { String(data: $0, encoding: .utf8) }
            // Read off the main thread, so a long paste never holds up typing.
            let shaped = await Task.detached(priority: .userInitiated) { PastedText.best(html: h, rtf: r, plain: plain) }.value
            await MainActor.run {
                if let shaped, !shaped.isEmpty { item.setResult(string: shaped) } else { item.setDefaultResult() }
            }
        }
    }

    private static func load(_ provider: NSItemProvider, _ type: String) async -> Data? {
        guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
        return await withCheckedContinuation { done in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in done.resume(returning: data) }
        }
    }

    /// Hands the paste to `shared` on whichever text view is being typed in, once the box has focus.
    @MainActor static func attachToFocusedField() {
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let field = UIResponder.typingIn else { return }
                if let view = field as? UITextView, view.pasteDelegate !== shared { view.pasteDelegate = shared }
                else if let view = field as? UITextField, view.pasteDelegate !== shared { view.pasteDelegate = shared }
            }
        }
    }
}

private extension UIResponder {
    private static weak var found: UIResponder?
    /// The view keyboard input goes to right now.
    static var typingIn: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(noteFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
    @objc private func noteFirstResponder() { UIResponder.found = self }
}
#endif
