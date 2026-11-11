import Foundation
import CryptoKit
import PulshadeTor

/// Bridges: a first hop into Tor that isn't on Tor's public list, for networks that block or watch for Tor. The
/// connection to the bridge is disguised by a pluggable transport (tor/pt, from Tor Project's lyrebird, built into
/// the app): Snowflake looks like a video call, webtunnel like ordinary HTTPS. (Not obfs4: lyrebird's includes
/// GPL-3 code, and Pulshade is MIT.)
///
/// The choice is kept outside the vault, since Tor connects before Pulshade is unlocked, in its own file sealed with
/// a Keychain key: on its own the file shows only that a choice was made, not which bridges.
enum Bridges: String, CaseIterable, Codable {
    case off, snowflake, custom
    /// Connects directly, and switches to Snowflake by itself when that doesn't get through (and back when it
    /// does), remembering what worked.
    case auto

    var title: String {
        switch self {
        case .auto: "Automatic"
        case .off: "Off"
        case .snowflake: "Snowflake"
        case .custom: "Your own"
        }
    }

    /// The bridges Tor Browser ships, from Tor Project.
    static let builtIn: [Bridges: [String]] = [
        .snowflake: [
        "snowflake 192.0.2.3:80 2B280B23E1107BB62ABFC40DDCC8824814F80A72 fingerprint=2B280B23E1107BB62ABFC40DDCC8824814F80A72 url=https://1098762253.rsc.cdn77.org/ fronts=app.datapacket.com,www.datapacket.com ice=stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478 utls-imitate=hellorandomizedalpn",
        "snowflake 192.0.2.4:80 8838024498816A039FCBBAB14E6F40A0843051FA fingerprint=8838024498816A039FCBBAB14E6F40A0843051FA url=https://1098762253.rsc.cdn77.org/ fronts=app.datapacket.com,www.datapacket.com ice=stun:stun.epygi.com:3478,stun:stun.uls.co.za:3478,stun:stun.voipgate.com:3478,stun:stun.mixvoip.com:3478,stun:stun.telnyx.com:3478,stun:stun.hot-chilli.net:3478,stun:stun.fitauto.ru:3478,stun:stun.m-online.net:3478 utls-imitate=hellorandomizedalpn",
        ],
    ]

    /// The choices as offered, Automatic first.
    static let choices: [Bridges] = [.auto, .off, .snowflake, .custom]

    static var current: Bridges { saved.choice }

    /// Bridge lines someone gave you (from bridges.torproject.org, say), one per line.
    static var customLines: String { saved.custom }

    /// Whether Automatic is on Snowflake right now: it got through when plain Tor didn't.
    static var autoUsesSnowflake: Bool { saved.fallback ?? false }

    /// Whether Tor is going out through bridges at all right now.
    static var active: Bool {
        switch current {
        case .off: false
        case .auto: autoUsesSnowflake
        default: true
        }
    }

    /// The lines Tor is given for the current choice.
    static var lines: String {
        switch current {
        case .off: ""
        case .auto: autoUsesSnowflake ? (builtIn[.snowflake] ?? []).joined(separator: "\n") : ""
        case .custom: customLines
        default: (builtIn[current] ?? []).joined(separator: "\n")
        }
    }

    /// How many of these lines Pulshade can use.
    static func usable(_ lines: String) -> Int {
        Int(pulshade_tor_count_bridges(lines))
    }

    /// Switches to a choice. False when Tor is running and couldn't switch straight away: it will on the next start.
    @discardableResult
    static func choose(_ choice: Bridges, custom lines: String? = nil) -> Bool {
        remember(choice, custom: lines)
        let applied = pulshade_tor_set_bridges(Self.lines) >= 0
        // Connections made through the old first hop go; the next requests build new ones.
        RelayClient.closeAll()
        return applied
    }

    /// Under Automatic: moves Tor onto Snowflake, or back to going direct, because the other one isn't getting
    /// through. Remembered for the next launch, so a network that needs Snowflake doesn't wait for it every time.
    @discardableResult
    static func switchAuto(toSnowflake: Bool) -> Bool {
        guard current == .auto else { return false }
        let now = Saved(choice: .auto, custom: customLines, fallback: toSnowflake)
        lock.withLock { cached = now }
        try? write(now)
        let applied = pulshade_tor_set_bridges(Self.lines) >= 0
        RelayClient.closeAll()
        return applied
    }

    // MARK: Saved choice

    private struct Saved: Codable {
        var choice: Bridges = .auto
        var custom = ""
        /// Under Automatic, whether Snowflake is what last worked. Optional so files from before it still open.
        var fallback: Bool?
        /// Whether relay traffic goes over Tor, if it was ever chosen. Kept here, not in the preferences file, so the
        /// file in the clear doesn't say which way this device connects. Optional so files from before still open.
        var tor: Bool?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: Saved?

    /// Where the choice is kept. Tests point it at a throwaway folder.
    nonisolated(unsafe) static var file = Tor.support.appendingPathComponent("bridges.sealed")
    private static var keys: FileKeys { FileKeys(directory: file.deletingLastPathComponent(), file: file.lastPathComponent) }

    private static var saved: Saved {
        lock.withLock {
            if let cached { return cached }
            let loaded = load()
            cached = loaded
            return loaded
        }
    }

    private static func load() -> Saved {
        let defaults = UserDefaults.standard
        // Builds before this kept the choice in the preferences file, in the clear: move it into the sealed file.
        // The plaintext copy goes whatever happens next: if it can't be sealed right now, the choice is used from
        // memory for this launch rather than left readable in a plist.
        var loaded: Saved
        if let raw = try? Data(contentsOf: file), let key = keys.load().last,
           let box = try? AES.GCM.SealedBox(combined: raw), let plain = try? AES.GCM.open(box, using: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: plain) {
            loaded = saved
        } else {
            loaded = Saved()
        }
        var moved = false
        if let old = defaults.string(forKey: "pulshade.bridges") {
            loaded.choice = Bridges(rawValue: old) ?? .off
            loaded.custom = defaults.string(forKey: "pulshade.bridges.custom") ?? ""
            moved = true
        }
        // The Tor switch lived there in the clear too: same move.
        if let old = defaults.object(forKey: "pulshade.tor") as? Bool {
            loaded.tor = old
            moved = true
        }
        if moved {
            _ = try? write(loaded)
            for key in ["pulshade.bridges", "pulshade.bridges.custom", "pulshade.tor"] { defaults.removeObject(forKey: key) }
        }
        return loaded
    }

    /// Keeps a choice for the next launch. Without a Keychain it holds until Pulshade quits, rather than going
    /// down unsealed.
    static func remember(_ choice: Bridges, custom lines: String? = nil) {
        let saved = Saved(choice: choice, custom: lines ?? customLines, fallback: choice == .auto ? autoUsesSnowflake : nil,
                          tor: self.saved.tor)
        lock.withLock { cached = saved }
        try? write(saved)
    }

    /// The Tor switch, once chosen on this device. Nil if it never was.
    static var torSwitch: Bool? { saved.tor }

    /// Keeps the Tor switch for the next launch, beside the bridge choice.
    static func rememberTor(_ on: Bool) {
        var next = saved
        next.tor = on
        lock.withLock { cached = next }
        try? write(next)
    }

    /// Reads the file again, as the next launch would.
    static func reload() {
        lock.withLock { cached = nil }
    }

    private static func write(_ choice: Saved) throws {
        // The folder first: the key's name comes from the file's path, which can read differently until it exists.
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let key: SymmetricKey
        if let existing = keys.load().last {
            key = existing
        } else {
            key = SymmetricKey(size: .bits256)
            try keys.store([key])
        }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(choice), using: key).combined!
        try sealed.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// For Burn: the file, its Keychain key and any copy in the old preferences go.
    static func forget() {
        lock.withLock { cached = Saved() }
        try? FileManager.default.removeItem(at: file)
        keys.forget()
        UserDefaults.standard.removeObject(forKey: "pulshade.bridges")
        UserDefaults.standard.removeObject(forKey: "pulshade.bridges.custom")
        UserDefaults.standard.removeObject(forKey: "pulshade.tor")
    }
}
