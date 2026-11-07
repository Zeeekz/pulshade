import Testing
import Foundation
@testable import Pulshade
import PulshadeShared

@Suite struct TorTests {
    @Test func onionRelaysAlwaysUseTor() throws {
        #expect(Tor.uses(try #require(URL(string: "http://pulshadexyz.onion"))))
        #expect(Tor.isOnion(try #require(URL(string: "http://PulshadeXYZ.onion:80/"))))
        #expect(!Tor.isOnion(try #require(URL(string: "https://relay.example.com"))))
    }

    @Test func settingSurvivesOlderVaults() throws {
        let old = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"autoLockMinutes": 1}"#.utf8))
        #expect(!old.tor)
        var on = SecuritySettings()
        on.tor = true
        #expect(try JSONDecoder().decode(SecuritySettings.self, from: JSONEncoder().encode(on)).tor)
    }
    /// Lanes share names across accounts ("main", "send"), so each lock moves every lane onto new circuits: the
    /// next account opened on this device never reaches the relay over the last one's.
    @MainActor @Test func lockingStartsNewCircuits() async throws {
        let model = testModel("pulshade-routes")
        try await model.create(identity: .generate(), profile: Profile(name: "Ann"), passcode: "test-passcode")
        let first = Tor.isolation("main")
        #expect(Tor.isolation("send") != first)
        model.lock()
        #expect(Tor.isolation("main") != first)
    }
}

/// A relay that's gone covers the app with the offline screen within half a minute, and coming back lifts it.
@MainActor @Suite struct RelayOfflineTests {
    @Test func aDeadRelayShowsAsOffline() async throws {
        let model = testModel("pulshade-offline")
        model.trafficShaping = true
        try await model.create(identity: .generate(), profile: Profile(name: "Ann"), passcode: "test-passcode")
        defer { model.lock() }
        let alive = model.data.relay
        model.data.relay = "http://127.0.0.1:9"  // nothing listens here
        let end = Date().addingTimeInterval(40)
        while Date() < end, !model.relayUnreachable { try await Task.sleep(for: .milliseconds(250)) }
        #expect(model.relayUnreachable)

        model.data.relay = alive
        await model.retryRelay()
        #expect(!model.relayUnreachable)
    }
}

/// Goes out over the real Tor network, so it's off by default and runs on its own (it switches Tor on for the
/// whole process): PULSHADE_TOR_TEST=1 ./scripts/test.sh --filter TorNetworkTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_TOR_TEST"] == "1"), .serialized)
struct TorNetworkTests {
    init() { Tor.enabled = true }

    private func exit(lane: String) async throws -> (tor: Bool, ip: String) {
        struct Check: Decodable { var IsTor: Bool; var IP: String }
        let url = try #require(URL(string: "https://check.torproject.org/api/ip"))
        let session = URLSession(configuration: try RelayClient.configuration(for: url, lane: lane))
        defer { session.invalidateAndCancel() }
        let check = try JSONDecoder().decode(Check.self, from: try await session.data(from: url).0)
        return (check.IsTor, check.IP)
    }

    /// iOS shuts an app's listening sockets while it's in the background. Coming back, Tor listens again on the
    /// same port, and requests go through as before.
    @Test func comingBackToTheFrontListensAgain() async throws {
        #expect(try await exit(lane: "wake").tor)
        let port = Tor.listeningPort
        #expect(port != 0)
        await Task.detached { Tor.wake() }.value
        #expect(Tor.listeningPort == port)
        #expect(try await exit(lane: "wake").tor, "a fresh circuit, through the port opened again")
    }

    /// Lanes never share a circuit. (One lane may move to a fresh circuit, so its own exit can change.)
    @Test func eachLaneGetsItsOwnCircuit() async throws {
        let a = try await exit(lane: "persona-a")
        let b = try await exit(lane: "persona-b")
        #expect(a.tor && b.tor)
        #expect(a.ip != b.ip)
        // The report shows each lane's circuit: guard, middle, exit.
        let circuits = Dictionary(Tor.circuits().map { ($0.lane, $0.hops) }, uniquingKeysWith: { a, _ in a })
        #expect(circuits["persona-a"]?.count == 3)
        #expect(circuits["persona-a"]?.last == a.ip)
    }

    /// An onion address only resolves inside Tor, so this also shows names never go to the local DNS.
    @Test func reachesOnionServices() async throws {
        let url = try #require(URL(string: "https://duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion/"))
        let session = URLSession(configuration: try RelayClient.configuration(for: url, lane: "onion"))
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(Tor.circuits().first { $0.lane == "onion" }?.hops.last == "onion")
    }

    @Test func callsGoOverTorToo() async throws {
        let url = try #require(URL(string: "wss://echo.websocket.org"))
        let task = URLSession(configuration: try RelayClient.configuration(for: url, lane: "call|test")).webSocketTask(with: url)
        task.resume()
        defer { task.cancel() }
        try await task.send(.string("pulse"))
        var heard: [String] = []
        for _ in 0..<2 { if case let .string(text) = try await task.receive() { heard.append(text) } }
        #expect(heard.contains("pulse"))
    }

    /// A relay's own onion service, end to end: PULSHADE_TEST_ONION=http://….onion (see relay/pulshade-onion/hostname).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"] != nil))
    func reachesARelayOverItsOnion() async throws {
        let relay = try #require(Invite.validRelay(ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"]).flatMap(URL.init))
        // A new onion service takes a little while to be published.
        var reached = false
        for _ in 0..<12 where !reached {
            reached = await RelayClient(base: relay, lane: "onion-relay").health()
            if !reached { try await Task.sleep(for: .seconds(5)) }
        }
        #expect(reached)
        // Onion connections have no IP address; the relay makes one up per circuit.
        let seen = try #require(await RelayClient(base: relay, lane: "onion-relay").seen())
        #expect(seen.hasPrefix("fd") && seen.contains(":"))
    }

    /// The announcements list comes over the onion, and asking again with its version gets "nothing new".
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"] != nil))
    func announcementsComeOverTheOnion() async throws {
        let relay = try #require(Invite.validRelay(ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"]).flatMap(URL.init))
        let client = RelayClient(base: relay, lane: "onion-announcements")
        var answer: (list: [Announcement], version: String?)?
        for _ in 0..<4 where answer == nil {
            answer = (try? await client.announcements(since: nil)) ?? nil
        }
        let first = try #require(answer)
        print("announcements over the onion:", first.list.map(\.text), first.version ?? "no version")
        #expect(first.version != nil)
        let again = try await client.announcements(since: first.version)
        #expect(again == nil, "nothing new")
    }

    /// About half of new circuits into an onion service carry nothing. A lane that lands on one gets a fresh
    /// circuit after the first failed request, so it never fails twice in a row.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"] != nil))
    func aLaneOnADeadCircuitGetsANewOne() async throws {
        let relay = try #require(Invite.validRelay(ProcessInfo.processInfo.environment["PULSHADE_TEST_ONION"]).flatMap(URL.init))
        var failedLast: Set<String> = []
        for round in 0..<3 {
            for lane in (0..<4).map({ "renew-\($0)" }) {
                let reached = await RelayClient(base: relay, lane: lane).health()
                #expect(reached || !failedLast.contains(lane), "\(lane) failed twice in a row (round \(round))")
                if reached { failedLast.remove(lane) } else { failedLast.insert(lane) }
            }
        }
    }

    /// Tor can't reach a relay on this machine, and nothing quietly falls back to a direct connection.
    @Test func neverFallsBackToDirect() async throws {
        let relay = try #require(URL(string: ProcessInfo.processInfo.environment["PULSHADE_TEST_RELAY"] ?? "http://127.0.0.1:7890"))
        #expect(await RelayClient(base: relay, lane: "fallback").health() == false)
    }
}

/// Connects through the built-in bridges over the real network, so it's off by default and runs on its own (Tor
/// starts once per process): PULSHADE_BRIDGE_TEST=snowflake ./scripts/test.sh --filter BridgeNetworkTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_BRIDGE_TEST"] != nil), .serialized)
struct BridgeNetworkTests {
    @Test func reachesTorThroughABridge() async throws {
        let mode = try #require(Bridges(rawValue: ProcessInfo.processInfo.environment["PULSHADE_BRIDGE_TEST"] ?? ""))
        UserDefaults.standard.set(mode.rawValue, forKey: "pulshade.bridges")
        defer { UserDefaults.standard.removeObject(forKey: "pulshade.bridges") }
        #expect(Bridges.usable(Bridges.lines) == Bridges.builtIn[mode]?.count)
        Tor.enabled = true

        struct Check: Decodable { var IsTor: Bool }
        let url = try #require(URL(string: "https://check.torproject.org/api/ip"))
        let config = try RelayClient.configuration(for: url, lane: "bridge-test")
        config.timeoutIntervalForRequest = 240
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let check = try JSONDecoder().decode(Check.self, from: try await session.data(from: url).0)
        #expect(check.IsTor)

        // The first hop is one of the bridges, not a public guard.
        let bridgeHosts = Set((Bridges.builtIn[mode] ?? []).compactMap { $0.split(separator: " ").dropFirst().first?.split(separator: ":").first.map(String.init) })
        let hops = try #require(Tor.circuits().first { $0.lane.hasPrefix("bridge-test") }?.hops)
        #expect(bridgeHosts.contains(hops.first ?? ""), "first hop \(hops.first ?? "?") should be a bridge")
    }
}

/// The bridge choice is kept sealed, never in the preferences file, and Burn leaves none of it behind.
@Suite(.serialized) struct BridgeStorageTests {
    @Test func theChoiceIsSealedAndBurnRemovesIt() throws {
        let folder = testDirectory("pulshade-bridges")
        Bridges.file = folder.appendingPathComponent("bridges.sealed")
        defer { Bridges.forget(); try? FileManager.default.removeItem(at: folder) }
        let line = "webtunnel 192.0.2.7:443 0123456789ABCDEF0123456789ABCDEF01234567 url=https://bridge.example/secret-path"

        Bridges.remember(.custom, custom: line)
        let raw = try Data(contentsOf: Bridges.file)
        #expect(raw.range(of: Data("bridge.example".utf8)) == nil)
        #expect(raw.range(of: Data("custom".utf8)) == nil)
        #expect(UserDefaults.standard.string(forKey: "pulshade.bridges") == nil)
        Bridges.reload()
        #expect(Bridges.current == .custom)
        #expect(Bridges.customLines == line)

        Bridges.forget()
        Bridges.reload()
        #expect(!FileManager.default.fileExists(atPath: Bridges.file.path))
        #expect(Bridges.current == .auto && !Bridges.autoUsesSnowflake && Bridges.customLines.isEmpty)
    }

    @Test func aChoiceFromOlderBuildsMovesOutOfThePreferences() throws {
        let folder = testDirectory("pulshade-bridges")
        Bridges.file = folder.appendingPathComponent("bridges.sealed")
        defer { Bridges.forget(); try? FileManager.default.removeItem(at: folder) }
        UserDefaults.standard.set("snowflake", forKey: "pulshade.bridges")
        UserDefaults.standard.set("", forKey: "pulshade.bridges.custom")

        Bridges.reload()
        #expect(Bridges.current == .snowflake)
        #expect(UserDefaults.standard.object(forKey: "pulshade.bridges") == nil)
        #expect(UserDefaults.standard.object(forKey: "pulshade.bridges.custom") == nil)
        Bridges.reload()
        #expect(Bridges.current == .snowflake)
    }

    @Test func automaticGoesDirectUntilSnowflakeIsNeededAndRemembersIt() throws {
        let folder = testDirectory("pulshade-bridges-auto")
        Bridges.file = folder.appendingPathComponent("bridges.sealed")
        defer { Bridges.forget(); try? FileManager.default.removeItem(at: folder) }
        Bridges.forget()
        #expect(Bridges.current == .auto && !Bridges.active && Bridges.lines.isEmpty)

        Bridges.switchAuto(toSnowflake: true)
        #expect(Bridges.active && Bridges.usable(Bridges.lines) == Bridges.builtIn[.snowflake]?.count)
        Bridges.reload()
        #expect(Bridges.current == .auto && Bridges.autoUsesSnowflake, "remembered for the next launch")

        Bridges.switchAuto(toSnowflake: false)
        #expect(!Bridges.active && Bridges.lines.isEmpty)

        // A choice made by hand isn't touched by the automatic one.
        Bridges.remember(.off)
        #expect(!Bridges.switchAuto(toSnowflake: true) && !Bridges.active)
    }
}

/// `pulshade://u/<handle>`, the link a website's Pulshade button opens.
@MainActor @Suite struct ProfileLinkTests {
    @Test func profileLinksNameAHandleAndNothingElse() throws {
        let handle = { (text: String) in URL(string: text).flatMap(DirectoryProfile.handle(fromLink:))?.handle }
        #expect(DirectoryProfile.link("nova") == "pulshade://u/nova")
        #expect(handle("pulshade://u/nova") == "nova")
        #expect(handle("PULSHADE://U/Nova") == "nova")
        #expect(handle("pulshade://u/1") == "1")
        #expect(handle("pulshade://u/no-dashes") == nil)
        #expect(handle("pulshade://u/") == nil)
        #expect(handle("pulshade://u/a/b") == nil)
        #expect(handle("pulshade://invite/nova") == nil)
        #expect(handle("https://u/nova") == nil)
    }

    @Test func aKeyedLinkOnlyMatchesItsOwnAccount() throws {
        let owner = try Identity(seed: Data(repeating: 1, count: 32))
        let stranger = try Identity(seed: Data(repeating: 2, count: 32))
        let text = DirectoryProfile.link("nova", key: owner.card.signing)
        #expect(text.hasPrefix("pulshade://u/nova?k="))
        let link = try #require(URL(string: text).flatMap(DirectoryProfile.handle(fromLink:)))
        #expect(link.handle == "nova")
        let check = try #require(link.keyCheck)
        let profile = { (id: Identity) in
            DirectoryProfile(handle: "nova", name: "", bio: "", avatar: nil, color: nil, signingKey: id.card.signing,
                             agreementKey: Data(), sendID: Data(), relay: nil)
        }
        #expect(profile(owner).matches(keyCheck: check))
        #expect(!profile(stranger).matches(keyCheck: check))
        #expect(URL(string: "pulshade://u/nova").flatMap(DirectoryProfile.handle(fromLink:))?.keyCheck == nil)
    }

    @Test func openingOneWaitsForContactsAndSendsNothing() throws {
        let model = testModel("pulshade-profile-link")
        model.open(try #require(URL(string: "pulshade://u/nova")))
        #expect(model.openedHandle == "nova")
        #expect(model.openedKeyCheck == nil)
        #expect(model.openedCode == nil)
        #expect(model.sentRequests.isEmpty)
        model.open(try #require(URL(string: "pulshade://invite/abc")))
        #expect(model.openedCode == "pulshade://invite/abc")
    }
}


/// Payloads from older apps, without the fields added since, still read.
@Suite struct PayloadCompatibilityTests {
    @Test func olderProfilesAndReceiptsStillDecode() throws {
        let id = UUID()
        let receipt = try JSONDecoder().decode(Payload.self, from: Data(#"{"receipt":{"ids":["\#(id.uuidString)"]}}"#.utf8))
        #expect(receipt == .receipt(ids: [id], read: nil))
        let profile = try JSONDecoder().decode(Payload.self, from: Data(#"{"profile":{"name":"Ann"}}"#.utf8))
        #expect(profile == .profile(name: "Ann", avatar: nil, color: nil, banner: nil, bio: nil))
        #expect(MessageStatus.read.rank > MessageStatus.delivered.rank)
    }
}
