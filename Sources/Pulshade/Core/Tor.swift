import Foundation
import Network
import PulshadeTor

/// Tor, run inside the app (Arti, built from tor/). It listens as a SOCKS proxy on 127.0.0.1 that only this
/// app can use, and every lane signs in to it with its own name, so each lane gets its own circuits: two
/// personas reach the relay from different exits and can't be matched by IP address or circuit.
enum Tor {
    /// Guards `on` and `port`, only ever for a moment, so the screen never waits on Tor.
    private static let lock = NSLock()
    /// Held while Tor starts, so it starts once.
    private static let starting = NSLock()
    /// On until someone turns it off: a fresh install, before there's an account, goes over Tor like the rest.
    nonisolated(unsafe) private static var on = UserDefaults.standard.object(forKey: "pulshade.tor") as? Bool
        ?? SecuritySettings.torByDefault
    nonisolated(unsafe) private static var port: UInt16 = 0
    /// Picked at launch. Something else on this machine that finds the port can't use it without this.
    private static let secret = Data.random(16).hex
    /// Put before every lane's name and changed at every lock, so the next account opened on this device never
    /// shares a circuit with the last one's, even on lanes with the same name ("main", "send").
    nonisolated(unsafe) private static var routes = Data.random(8).hex

    /// Whether relay traffic goes over Tor. The setting lives in the vault; it's also kept outside it so
    /// requests made while locked (linking a new device, say) follow it too.
    static var enabled: Bool {
        get { lock.withLock { on } }
        set {
            lock.withLock { on = newValue }
            UserDefaults.standard.set(newValue, forKey: "pulshade.tor")
            // Started in the background so it's warm by the first request, and never on the main thread.
            if newValue { DispatchQueue.global(qos: .utility).async { start() } }
        }
    }

    /// Whether the person has chosen between Tor and a direct connection on this device.
    static var chosen: Bool { UserDefaults.standard.object(forKey: "pulshade.tor") != nil }

    /// Whenever there's no account on this device (a fresh install, after Detach or Burn), the first thing asked is how
    /// to connect, before anything connects. Not where the relay can only be reached over Tor: there is nothing to choose.
    static var needsChoice: Bool { AppData.directRelay != nil }

    /// An onion relay can only be reached over Tor, whatever the setting.
    static func uses(_ url: URL) -> Bool {
        enabled || isOnion(url)
    }

    static func isOnion(_ url: URL) -> Bool {
        url.host()?.lowercased().hasSuffix(".onion") == true
    }

    /// The local port Tor listens on, 0 until it starts.
    static var listeningPort: UInt16 { lock.withLock { port } }

    /// 0 to 100 while connecting, 100 once ready, -1 if it couldn't start. 0 until first used.
    static var progress: Int {
        lock.withLock { port } == 0 ? 0 : Int(pulshade_tor_progress())
    }

    /// Each lane's latest circuit: the Tor relays' addresses in order, then "onion" when it ends in an onion
    /// service. Kept in memory only, for the anonymity report.
    static func circuits() -> [(lane: String, hops: [String])] {
        guard lock.withLock({ port }) != 0, let raw = pulshade_tor_circuits() else { return [] }
        defer { pulshade_tor_free(raw) }
        let current = isolation("")
        return String(cString: raw).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            // Only this unlock's lanes: the last account's circuits aren't this one's to show.
            guard parts.count == 2, parts[0].hasPrefix(current) else { return nil }
            return (String(parts[0].dropFirst(current.count)), parts[1].split(separator: ",").map(String.init))
        }
    }

    /// Gives a lane fresh circuits, after a request on it failed.
    static func renew(lane: String) {
        guard lock.withLock({ port }) != 0 else { return }
        pulshade_tor_renew(isolation(lane))
    }

    /// Coming back to the front. iOS shuts an app's listening sockets while it's suspended, so Tor's port is
    /// opened again and every lane gets fresh circuits. Connections made through the old port are dead and
    /// need dropping too (`RelayClient.closeAll`). Waits on Tor for a moment: call it off the main thread.
    static func wake() {
        guard lock.withLock({ port }) != 0 else { return }
        let now = pulshade_tor_wake()
        if now != 0 { lock.withLock { port = now } }
    }

    /// New circuits for every lane from now on. Called when Pulshade locks or closes an account; connections
    /// already open need dropping too (`RelayClient.closeAll`).
    static func newRoutes() {
        lock.withLock { routes = Data.random(8).hex }
    }

    /// The name Tor isolates a lane's circuits by.
    static func isolation(_ lane: String) -> String {
        lock.withLock { routes } + "/" + lane
    }

    /// Starts Tor if it isn't running and returns its port, or nil if it couldn't start.
    @discardableResult
    static func start() -> UInt16? {
        if let running = lock.withLock({ port == 0 ? nil : port }) { return running }
        return starting.withLock {
            if let running = lock.withLock({ port == 0 ? nil : port }) { return running }
            let (state, cache) = directories()
            // Returns at once; Tor loads its saved state and connects in the background.
            let made = pulshade_tor_start(state.path, cache.path, secret, Bridges.lines)
            lock.withLock { port = made }
            return made == 0 ? nil : made
        }
    }

    /// Sends everything made with `config` over Tor, on `lane`'s own circuits. Never falls back to a direct
    /// connection: if Tor isn't there, or `url` is on your own network, requests fail.
    static func route(_ config: URLSessionConfiguration, to url: URL, lane: String) throws {
        // The system sends local addresses around the proxy, and Tor couldn't reach them anyway: refuse
        // rather than connect directly.
        guard let host = url.host(), !Invite.isLocal(host.lowercased()) else { throw URLError(.cannotConnectToHost) }
        guard let port = start(), let nwPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.cannotConnectToHost) }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: nwPort))
        proxy.applyCredential(username: isolation(lane), password: secret)
        proxy.allowFailover = false
        config.proxyConfigurations = [proxy]
        // Circuits take a moment to build, more so while Tor is still connecting.
        config.timeoutIntervalForRequest = 60
    }

    /// For Burn: removes Tor's saved state, its relay lists, the bridge choice and the Tor switch, so nothing on
    /// the disk says Tor ran here. Tor carries on from memory until Pulshade quits, and never makes these folders
    /// again while it runs.
    static func forget() {
        let files = FileManager.default
        let (state, cache) = paths()
        try? files.removeItem(at: state)
        try? files.removeItem(at: cache)
        let caches = cache.deletingLastPathComponent()
        if (try? files.contentsOfDirectory(atPath: caches.path))?.isEmpty == true { try? files.removeItem(at: caches) }
        Bridges.forget()
        UserDefaults.standard.removeObject(forKey: "pulshade.tor")
        lock.withLock { on = SecuritySettings.torByDefault }
    }

    /// Pulshade's folder in Application Support, where Tor's state and the bridge choice live.
    static var support: URL {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"], !test.isEmpty {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulshade", isDirectory: true)
    }

    private static func paths() -> (state: URL, cache: URL) {
        var caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulshade", isDirectory: true)
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"], !test.isEmpty {
            caches = URL(fileURLWithPath: test, isDirectory: true).appendingPathComponent("caches", isDirectory: true)
        }
        #endif
        return (support.appendingPathComponent("tor", isDirectory: true), caches.appendingPathComponent("tor", isDirectory: true))
    }

    /// Tor's network state, kept so later launches connect faster, and its cache of relay lists.
    private static func directories() -> (state: URL, cache: URL) {
        let files = FileManager.default
        let (state, cache) = paths()
        for var dir in [state, cache] {
            try? files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return (state, cache)
    }
}
