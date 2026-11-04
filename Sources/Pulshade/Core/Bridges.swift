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

    var title: String {
        switch self {
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

    static var current: Bridges { saved.choice }

    /// Bridge lines someone gave you (from bridges.torproject.org, say), one per line.
    static var customLines: String { saved.custom }

    /// The lines Tor is given for the current choice.
    static var lines: String {
        switch current {
        case .off: ""
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

    // MARK: Saved choice

    private struct Saved: Codable {
        var choice: Bridges = .off
        var custom = ""
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
        if let old = defaults.string(forKey: "pulshade.bridges") {
            let moved = Saved(choice: Bridges(rawValue: old) ?? .off, custom: defaults.string(forKey: "pulshade.bridges.custom") ?? "")
            if (try? write(moved)) != nil {
                defaults.removeObject(forKey: "pulshade.bridges")
                defaults.removeObject(forKey: "pulshade.bridges.custom")
            }
            return moved
        }
        guard let raw = try? Data(contentsOf: file), let key = keys.load().last,
              let box = try? AES.GCM.SealedBox(combined: raw), let plain = try? AES.GCM.open(box, using: key),
              let saved = try? JSONDecoder().decode(Saved.self, from: plain) else { return Saved() }
        return saved
    }

    /// Keeps a choice for the next launch. Without a Keychain it holds until Pulshade quits, rather than going
    /// down unsealed.
    static func remember(_ choice: Bridges, custom lines: String? = nil) {
        let saved = Saved(choice: choice, custom: lines ?? customLines)
        lock.withLock { cached = saved }
        try? write(saved)
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
    }
}
