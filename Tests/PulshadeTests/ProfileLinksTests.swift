import Testing
import Foundation
import CoreImage
@testable import PulshadeShared
@testable import Pulshade

struct ProfileLinksTests {
    // Well-known public example addresses, nobody's own.
    let btcLegacy = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"
    let btcSegwit = "bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4"
    let ethChecksummed = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    let xmr = "44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

    @Test func keccakMatchesTheKnownHashes() {
        #expect(hex(Keccak.hash256([])) == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        #expect(hex(Keccak.hash256(Array("abc".utf8))) == "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")
    }

    @Test func bitcoinAddresses() {
        #expect(ProfileLinkKind.bitcoin.normalize(btcLegacy) == btcLegacy)
        #expect(ProfileLinkKind.bitcoin.normalize(btcSegwit) == btcSegwit)
        #expect(ProfileLinkKind.bitcoin.normalize(btcSegwit.uppercased()) == btcSegwit.uppercased())
        // One character changed: the checksum catches it.
        #expect(ProfileLinkKind.bitcoin.normalize("1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNb") == nil)
        #expect(ProfileLinkKind.bitcoin.normalize("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t5") == nil)
        // Mixed case bech32 is not allowed, and neither is another coin's address.
        #expect(ProfileLinkKind.bitcoin.normalize("Bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4") == nil)
        #expect(ProfileLinkKind.bitcoin.normalize(ethChecksummed) == nil)
        #expect(ProfileLinkKind.litecoin.normalize(btcSegwit) == nil)
    }

    @Test func ethereumChecksum() {
        #expect(ProfileLinkKind.ethereum.normalize(ethChecksummed) == ethChecksummed)
        #expect(ProfileLinkKind.ethereum.normalize(ethChecksummed.lowercased()) != nil)
        // A wrong capital in a mixed-case address fails EIP-55.
        let broken = "0x5AAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
        #expect(ProfileLinkKind.ethereum.normalize(broken) == nil)
        #expect(ProfileLinkKind.ethereum.normalize("0x1234") == nil)
    }

    @Test func moneroAddresses() {
        #expect(ProfileLinkKind.monero.normalize(xmr) == xmr)
        var bad = Array(xmr)
        bad[40] = bad[40] == "a" ? "b" : "a"
        #expect(ProfileLinkKind.monero.normalize(String(bad)) == nil)
        #expect(ProfileLinkKind.monero.normalize(String(xmr.dropLast())) == nil)
        #expect(ProfileLinkKind.monero.normalize(btcLegacy) == nil)
    }

    @Test func solanaAndLightning() {
        #expect(ProfileLinkKind.solana.normalize("11111111111111111111111111111111") != nil)
        #expect(ProfileLinkKind.solana.normalize("0OIl") == nil)
        #expect(ProfileLinkKind.lightning.normalize("Satoshi@Wallet.example") == "satoshi@wallet.example")
        #expect(ProfileLinkKind.lightning.normalize("satoshi@localhost") == nil)
        #expect(ProfileLinkKind.lightning.normalize("a@b@c.example") == nil)
    }

    @Test func socialUsernamesBecomeLinks() {
        #expect(ProfileLinkKind.github.normalize("@octocat") == "https://github.com/octocat")
        #expect(ProfileLinkKind.x.normalize("https://twitter.com/jack") == "https://twitter.com/jack")
        #expect(ProfileLinkKind.mastodon.normalize("@gargron@mastodon.social") == "https://mastodon.social/@gargron")
        #expect(ProfileLinkKind.telegram.normalize("durov") == "https://t.me/durov")
    }

    @Test func linksRefuseWhatCouldBeUsedToTrickSomeone() {
        let bad = [
            "javascript:alert(1)", "http://example.com", "data:text/html,hi", "file:///etc/passwd",
            "https://x.com@evil.example/", "https://user:pass@example.com/", "https://example.com:8080/",
            "https://localhost/", "https://exa mple.com", "https://example.com/\u{202E}gpj.exe", "https://exаmple.com",
        ]
        for text in bad { #expect(ProfileLinkKind.website.normalize(text) == nil, "\(text)") }
        // Another network's domain, or one that only looks like it, is not accepted for a network.
        #expect(ProfileLinkKind.x.normalize("https://evil.example/x.com") == nil)
        #expect(ProfileLinkKind.x.normalize("https://notx.com/jack") == nil)
        #expect(ProfileLinkKind.github.normalize("https://github.com.evil.example/a") == nil)
        #expect(ProfileLinkKind.github.normalize("javascript:alert(1)") == nil)
    }

    @Test func customLinksNeedAHonestLabelAndShowTheirDomain() {
        let link = ProfileLink.make(.custom, from: "https://Blog.Example.com/me", label: "My shop")
        #expect(link?.domain == "blog.example.com")
        #expect(link?.url?.scheme == "https")
        #expect(ProfileLink.make(.custom, from: "https://example.com", label: nil) == nil)
        #expect(ProfileLink.make(.custom, from: "https://example.com", label: "bad\u{202E}label") == nil)
        #expect(ProfileLink.make(.custom, from: "https://example.com", label: String(repeating: "a", count: 31)) == nil)
    }

    @Test func walletsAreShownNotOpened() {
        let link = ProfileLink.make(.bitcoin, from: btcSegwit)
        #expect(link?.url == nil)
        #expect(link?.shortValue == "bc1qw508...w7kv8f3t4".replacingOccurrences(of: "w7kv8f3t4", with: String(btcSegwit.suffix(6))))
    }

    @Test func listsKeepOnlyGoodEntriesOnePerKind() {
        let list = ProfileLink.cleaned([
            ProfileLink(kind: .bitcoin, value: btcSegwit),
            ProfileLink(kind: .bitcoin, value: btcLegacy),               // second Bitcoin: dropped
            ProfileLink(kind: .website, value: "javascript:alert(1)"),   // invalid: dropped
            ProfileLink(kind: .github, value: "octocat"),                // not canonical yet: fixed
        ])
        #expect(list.map(\.kind) == [.bitcoin, .github])
        #expect(list[1].value == "https://github.com/octocat")
        #expect(ProfileLink.cleaned(nil).isEmpty)
        let many = (0..<50).map { ProfileLink(kind: .custom, value: "https://e\($0).example.com", label: "x") }
        #expect(ProfileLink.cleaned(many).count == ProfileLink.maxCount)
    }

    @Test func everyKindHasATitleSymbolAndAPrompt() {
        for kind in ProfileLinkKind.allCases {
            #expect(!kind.title.isEmpty && !kind.symbol.isEmpty && !kind.prompt.isEmpty)
        }
        #expect(Set(ProfileLinkKind.links + ProfileLinkKind.wallets) == Set(ProfileLinkKind.allCases))
    }

    @Test func linksTravelInAProfileAndOldProfilesStillOpen() throws {
        let links = [ProfileLink(kind: .bitcoin, value: btcSegwit), ProfileLink(kind: .github, value: "https://github.com/octocat")]
        let sent = Payload.profile(name: "Ann", avatar: nil, color: nil, links: links)
        let back = try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(sent))
        #expect(back == sent)
        // A profile from before this existed has no links and decodes the same as ever.
        let old = try JSONEncoder.pulshade.encode(Payload.profile(name: "Ann", avatar: nil, color: nil))
        #expect(try JSONDecoder.pulshade.decode(Payload.self, from: old) == .profile(name: "Ann", avatar: nil, color: nil))
    }

    @Test func aPeerAndAProfileKeepTheirLinksWhenSaved() throws {
        var profile = Profile()
        profile.links = [ProfileLink(kind: .monero, value: xmr)]
        let again = try JSONDecoder.pulshade.decode(Profile.self, from: JSONEncoder.pulshade.encode(profile))
        #expect(again.links == profile.links)
        #expect(try JSONDecoder.pulshade.decode(Profile.self, from: Data(#"{"name":"Ann"}"#.utf8)).links == nil)
    }

    @Test func theReviewedGapsAreClosed() throws {
        // SEC-002: a kind from a newer version, or a broken entry, doesn't break the rest.
        let json = #"[{"kind":"bluesky","value":"x"},{"kind":"github","value":"https://github.com/octocat"},{"kind":7}]"#
        let list = try JSONDecoder().decode([ProfileLink].self, from: Data(json.utf8))
        #expect(ProfileLink.cleaned(list).map(\.kind) == [.github])
        // SEC-003: invisible and filler characters.
        for bad in ["a\u{3164}b", "a\u{2064}b", "a\u{E0041}b", "a\u{FE0F}b", "a\u{034F}b"] {
            #expect(ProfileLinkKind.cleanLabel(bad) == nil, Comment(rawValue: "\(bad.unicodeScalars.map(\.value))"))
        }
        // SEC-004: a Bitcoin script address is not a Litecoin one.
        #expect(ProfileLinkKind.litecoin.normalize("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy") == nil)
        #expect(ProfileLinkKind.bitcoin.normalize("3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy") != nil)
        // SEC-006: a Lightning address or Mastodon domain can't carry a path, query or port.
        for bad in ["a@example.com/x", "a@example.com?y", "a@example.com#z", "a@example.com:80"] {
            #expect(ProfileLinkKind.lightning.normalize(bad) == nil, Comment(rawValue: bad))
        }
        #expect(ProfileLinkKind.mastodon.normalize("@a@good.com/evil?") == nil)
        // SEC-007: Nostr keys are lowercase, 63 characters, plain Bech32.
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        #expect(ProfileLinkKind.nostr.normalize(npub) == npub)
        #expect(ProfileLinkKind.nostr.normalize(npub.uppercased()) == nil)
        #expect(ProfileLinkKind.nostr.normalize(String(npub.dropLast())) == nil)
        // SEC-008: addresses made of numbers are not website names.
        for bad in ["https://192.168.0.1/admin", "https://0x7f.0.0.1/", "https://127.1/", "https://example.123/"] {
            #expect(ProfileLinkKind.website.normalize(bad) == nil, Comment(rawValue: bad))
        }
        #expect(ProfileLinkKind.website.normalize("https://example.com/a") != nil)
        // SEC-009: huge input is refused before any real work.
        #expect(ProfileLink.make(.website, from: "https://example.com/" + String(repeating: "a", count: 5000)) == nil)
    }

    @Test func logosDrawInsideTheirBox() {
        // The renderer on a few shapes whose size is known.
        let square = SVGPath.path("M0 0h10v10H0z").boundingRect
        #expect(square == CGRect(x: 0, y: 0, width: 10, height: 10))
        let half = SVGPath.path("M0 0a5 5 0 0 1 10 0").boundingRect
        #expect(abs(half.width - 10) < 0.01 && abs(half.height - 5) < 0.01)
        let rel = SVGPath.path("m2 2 l3 0 0 3 -3 0z").boundingRect
        #expect(rel == CGRect(x: 2, y: 2, width: 3, height: 3))
        // Every real logo parses to something that fills most of its 24 x 24 box and stays inside it.
        for kind in ProfileLinkKind.allCases {
            guard let data = kind.logoPath else { continue }
            let box = SVGPath.path(data).boundingRect
            #expect(box.minX >= -0.5 && box.minY >= -0.5 && box.maxX <= 24.5 && box.maxY <= 24.5, Comment(rawValue: kind.title))
            #expect(box.width > 12 && box.height > 12, Comment(rawValue: "\(kind.title) \(box)"))
        }
        // Only these four use a symbol instead of a logo.
        #expect(Set(ProfileLinkKind.allCases.filter { $0.logoPath == nil }) == [.website, .custom, .nostr, .lightning])
    }

    @Test func subtitlesReadNicely() {
        #expect(ProfileLink.make(.github, from: "octocat")?.subtitle == "@octocat")
        #expect(ProfileLink.make(.x, from: "https://twitter.com/jack")?.subtitle == "@jack")
        #expect(ProfileLink.make(.mastodon, from: "@gargron@mastodon.social")?.subtitle == "@gargron@mastodon.social")
        #expect(ProfileLink.make(.website, from: "https://example.com/me")?.subtitle == "example.com")
        #expect(ProfileLink.make(.bitcoin, from: btcSegwit)?.subtitle.contains("...") == true)
    }

    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// A wallet sent from the pinned sheet goes as a card whose QR code scans back to it: a `bitcoin:` link for
    /// Bitcoin. The chat reads the card back from the words, and nothing else looks like one.
    @MainActor @Test func walletCardScansBack() throws {
        let wallet = WalletMessage(kind: .bitcoin, address: btcSegwit)
        #expect(wallet.qrText == "bitcoin:\(btcSegwit)")
        #expect(WalletMessage(text: wallet.text) == wallet)
        #expect(WalletMessage(text: "My Bitcoin address:\nnot-an-address") == nil)
        #expect(WalletMessage(text: "Hello\n\(btcSegwit)") == nil)
        #expect(WalletMessage(kind: .monero, address: xmr).qrText == xmr)
        for w in [wallet, WalletMessage(kind: .monero, address: xmr), WalletMessage(kind: .ethereum, address: ethChecksummed)] {
            let jpeg = try #require(WalletCard.picture(w))
            #expect(jpeg.count < 400_000)
            let image = try #require(CIImage(data: jpeg))
            let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let read = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            #expect(read == [w.qrText])
        }
    }

    /// Photos fill their bubble at its full width, and odd shapes are cropped instead of shrunk to a sliver.
    @Test func mediaFrameKeepsBubblesSensible() {
        let wide = MediaFrame.size(for: CGSize(width: 4000, height: 3000))
        #expect(wide.width == MediaFrame.maxWidth)
        #expect(abs(wide.height - (MediaFrame.maxWidth * 0.75).rounded()) <= 1)
        let tall = MediaFrame.size(for: CGSize(width: 100, height: 2000))
        #expect(tall.height == MediaFrame.maxHeight && tall.width == MediaFrame.minWidth)
        let strip = MediaFrame.size(for: CGSize(width: 3000, height: 100))
        #expect(strip.height == MediaFrame.minHeight)
    }
}
