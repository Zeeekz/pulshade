import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import Pulshade

/// Pasted text keeps the shape it had where it was copied from, and the bubble finds the lists in it.
struct PastedTextTests {
    @Test func aWebPageKeepsItsParagraphsAndLists() {
        let html = """
        <html><head><style>p { color: red }</style><title>Page</title></head><body>
        <h2>Before you go</h2>
        <p>Pack   these   things:</p>
        <ul><li>Passport</li><li>Charger <b>and</b> cable
          <ul><li>USB&#8209;C</li></ul></li><li>Snacks &amp; water</li></ul>
        <ol start="3"><li><p>Lock the door</p></li><li>Leave</li></ol>
        <p>See you&nbsp;soon!<br>Love</p><script>alert(1)</script>
        </body></html>
        """
        #expect(PastedText.fromHTML(html) == """
        Before you go

        Pack these things:

        • Passport
        • Charger and cable
          ◦ USB‑C
        • Snacks & water

        3. Lock the door
        4. Leave

        See you soon!
        Love
        """)
    }

    @Test func tablesAndCommentsAndOddMarkup() {
        let html = "<!-- x --><table><tr><th>Name</th><th>Age</th></tr><tr><td>Ann</td><td>30</td></tr></table><p>a &lt;b&gt; &unknown; c</p>"
        #expect(PastedText.fromHTML(html) == "Name · Age\nAnn · 30\n\na <b> &unknown; c")
    }

    @Test func plainTextFromAListIsTidied() {
        #expect(PastedText.tidy("Intro\n\t•\tOne\n\t\t◦\tTwo\n1.\tThree\n\n\n\nEnd  ") == "Intro\n• One\n  ◦ Two\n1. Three\n\nEnd")
        // Plain text with nothing to change is left to the system's own paste.
        #expect(PastedText.best(html: nil, rtf: nil, plain: "just words") == nil)
    }

    @Test func notesListsComeThroughRTF() throws {
        let list = NSTextList(markerFormat: .disc, options: 0)
        let style = NSMutableParagraphStyle()
        style.textLists = [list]
        let text = NSMutableAttributedString(string: "Shopping\n")
        text.append(NSAttributedString(string: "\t•\tMilk\n\t•\tBread\n", attributes: [.paragraphStyle: style]))
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        #expect(PastedText.fromRTF(data) == "Shopping\n• Milk\n• Bread")
    }

    @Test func theBubbleFindsListLines() {
        #expect(ListLine.parse("• Milk") == ListLine(level: 0, marker: "•", rest: "Milk"))
        #expect(ListLine.parse("  ◦ Oat") == ListLine(level: 1, marker: "◦", rest: "Oat"))
        #expect(ListLine.parse("12. Twelve") == ListLine(level: 0, marker: "12.", rest: "Twelve"))
        #expect(ListLine.parse("- typed by hand") == ListLine(level: 0, marker: "•", rest: "typed by hand"))
        #expect(ListLine.parse("2024. was a year") == nil)
        #expect(ListLine.parse("-5 degrees") == nil)
        #expect(ListLine.parse("o hello") == nil)
        #expect(!ListLine.hasList("• only one line"))
        #expect(ListLine.hasList("Shopping\n• Milk"))
    }
}

extension PastedTextTests {
    /// A hostile page can't crash the app or make it build an endless paste.
    @Test func hostileHTMLStaysSmallAndSafe() {
        #expect(PastedText.fromHTML("<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>") == "999. a\n999. b")
        let deep = String(repeating: "<ul>", count: 5_000) + String(repeating: "<li>x", count: 5_000)
        let made = PastedText.fromHTML(deep)
        #expect(made.utf8.count <= PastedText.maxOutput)
        #expect(!made.contains(String(repeating: " ", count: 2 * PastedText.maxDepth)), "indented no deeper than the limit")
    }

    /// Text the page hides isn't slipped into the paste: if the shaped text says other words than the plain one, the
    /// plain one is used.
    @Test func hiddenTextFallsBackToThePlainText() {
        let html = "<p>Hello</p><p style=\"display:none\">secret line</p>"
        #expect(PastedText.best(html: Data(html.utf8), rtf: nil, plain: "Hello") == nil)
        #expect(PastedText.best(html: Data("<ul><li>One</li><li>Two</li></ul>".utf8), rtf: nil, plain: "One\nTwo") == "• One\n• Two")
    }
}
