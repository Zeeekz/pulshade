import Testing
import Foundation
@testable import Pulshade

/// The delivery counter for everything beyond plain one-to-one chats between phones (see `CanaryTests` for those):
/// shared groups, a second device linked to one account (a Mac beside the phone), a second persona on one phone, and a
/// phone that is detached and recovered from its sealed backup, all while the relay crashes, phones sleep and apps
/// are closed and opened again. Every message and post is counted on every device that should show it.
///
///   CANARY_SUITE=accounts scripts/canary.sh
///
/// Its relay is on its own port (7897), so it can run beside `CanaryTests`, but each points the process at its own
/// relay: never in the same process as other suites.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_CANARY_ACCOUNTS"] == "1"), .serialized)
struct CanaryAccountsTests {
    private static let env = ProcessInfo.processInfo.environment
    private static func setting(_ name: String, _ fallback: Double) -> Double { env[name].flatMap(Double.init) ?? fallback }

    private final class CrashingRelay {
        let port: Int
        let directory: URL
        private let key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        private var process: Process?
        var crashes = 0

        init(port: Int) throws {
            self.port = port + (Int(ProcessInfo.processInfo.environment["PULSHADE_PORT_OFFSET"] ?? "") ?? 0)
            directory = FileManager.default.temporaryDirectory.appending(path: "pulshade-canary2-relay-\(UUID().uuidString)")
            try start()
        }

        var url: String { "http://127.0.0.1:\(port)" }

        func start() throws {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let run = Process()
            run.executableURL = root.appending(path: "relay/target/release/pulshade-relay")
            run.currentDirectoryURL = directory
            var env = ProcessInfo.processInfo.environment
            env["PULSHADE_ONION"] = "0"
            env["PULSHADE_STORAGE_KEY"] = key
            env["PULSHADE_BIND"] = "127.0.0.1:\(port)"
            env["PULSHADE_DIRECTORY"] = directory.appending(path: "directory.json").path
            run.environment = env
            run.standardOutput = FileHandle.nullDevice
            run.standardError = FileHandle.nullDevice
            try run.run()
            process = run
            let end = Date().addingTimeInterval(15)
            while Date() < end {
                if (try? Data(contentsOf: URL(string: "\(url)/v1/health")!)) != nil { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
            throw CocoaError(.fileReadUnknown)
        }

        func crash() {
            if let process { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            process = nil
            crashes += 1
        }

        func stopForGood() {
            if let process { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
            process = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// One device: a phone, or the Mac linked to P0's account.
    @MainActor private final class Device {
        let name: String
        var directory: URL
        var model: AppModel
        let passcode: String
        var asleepUntil = Date.distantPast
        var events: [String] = []
        /// Canary tags this device has shown, and when it first did; kept through a Detach, which wipes its chats.
        var arrived: [String: Date] = [:]
        /// The most times any one tag was shown at once.
        var shownTwice: Set<String> = []
        init(name: String, directory: URL, model: AppModel, passcode: String) {
            self.name = name; self.directory = directory; self.model = model; self.passcode = passcode
        }
        var awake: Bool { Date() >= asleepUntil }
    }

    private final class Tally: @unchecked Sendable { var handled = 0, junk = 0, retry = 0 }

    private func prepare(_ model: AppModel, tally: Tally) {
        model.callAudio = false
        model.trafficShaping = false
        model.cutOffOnLock = false
        model.receiveResultTap = { result in
            switch result {
            case .handled: tally.handled += 1
            case .junk: tally.junk += 1
            case .retry: tally.retry += 1
            }
        }
    }

    private func open(_ directory: URL, tally: Tally) -> AppModel {
        let model = AppModel(vault: Vault(directory: directory), watchSystem: false)
        prepare(model, tally: tally)
        return model
    }

    private struct Sent {
        let tag: String
        let from: String          // device that sent it
        let to: [String]          // devices that should show it
        let at: Date
        let group: Bool
        var abandoned = false     // its sender was detached before it got through: nothing can send it again
    }

    @Test func groupsLinkedDevicesPersonasAndDetachAllDeliver() async throws {
        let minutes = Self.setting("CANARY_MINUTES", 10)
        let drainMinutes = Self.setting("CANARY_DRAIN_MINUTES", 5)
        let sendEvery = Self.setting("CANARY_SEND_SECONDS", 20)
        let crashEvery = Self.setting("CANARY_CRASH_MINUTES", 4)
        let relaunchEvery = Self.setting("CANARY_RELAUNCH_MINUTES", 6)
        let sleepEvery = Self.setting("CANARY_SLEEP_MINUTES", 4)
        let detachEvery = Self.setting("CANARY_DETACH_MINUTES", 6)
        let tick = 0.25

        let relay = try CrashingRelay(port: 7897)
        let previousRelay = Self.env["PULSHADE_TEST_RELAY"]
        setenv("PULSHADE_TEST_RELAY", relay.url, 1)
        let previousGaps = AppModel.resendGaps
        AppModel.resendGaps = [8, 20, 45, 90, 180]
        defer {
            AppModel.resendGaps = previousGaps
            relay.stopForGood()
            if let previousRelay { setenv("PULSHADE_TEST_RELAY", previousRelay, 1) } else { unsetenv("PULSHADE_TEST_RELAY") }
        }

        FileKeys.inMemory = true
        let base = testDirectory("pulshade-canary2")
        let tally = Tally()
        var devices: [String: Device] = [:]
        for n in 0..<4 {
            let dir = base.appending(path: "P\(n)-0")
            let model = open(dir, tally: tally)
            try await model.create(identity: .generate(), profile: Profile(name: "P\(n)"), passcode: "canary-passcode")
            model.data.security.autoLockMinutes = 0
            devices["P\(n)"] = Device(name: "P\(n)", directory: dir, model: model, passcode: "canary-passcode")
        }
        func d(_ name: String) -> Device { devices[name]! }
        func all() -> [Device] { devices.values.sorted { $0.name < $1.name } }
        func settle(_ seconds: Double, _ done: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end {
                for x in all() { await x.model.syncOnce() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { for x in all() { x.model.lock() } }

        // Friends: every phone with every other.
        for i in 0..<4 { for j in (i + 1)..<4 {
            _ = d("P\(j)").model.addContact(code: d("P\(i)").model.makeInviteCode(), nickname: "")
        } }
        func fp(_ name: String) -> String { d(name).model.fingerprint }
        var personaFP = ""
        func hasKeys(_ a: String, _ b: String, persona: UUID? = nil) -> Bool {
            d(a).model.contact(b == "P1b" ? personaFP : fp(b), in: persona)?.devices.contains { $0.session != nil } == true
        }
        await settle(60) { (0..<4).allSatisfy { i in (0..<4).allSatisfy { j in i == j || hasKeys("P\(i)", "P\(j)") } } }

        // A Mac linked to P0's account.
        let code = d("P0").model.makeLinkCode()
        let linker = DeviceLinker()
        linker.start(code)
        for _ in 0..<40 where d("P0").model.pendingLink == nil {
            try await Task.sleep(for: .milliseconds(200))
            await d("P0").model.syncOnce()
        }
        d("P0").model.approveLink()
        await d("P0").model.syncOnce()
        for _ in 0..<40 where linker.stage != .confirming { try await Task.sleep(for: .milliseconds(250)) }
        linker.confirm()
        let bundle = try #require(linker.bundle)
        let macDir = base.appending(path: "L0-0")
        let mac = open(macDir, tally: tally)
        try await mac.finishLink(bundle, deviceID: linker.deviceID, deviceKeySeed: linker.deviceKeySeed, selfMailbox: linker.selfMailbox, relay: linker.relay, passcode: "second-device")
        mac.data.security.autoLockMinutes = 0
        devices["L0"] = Device(name: "L0", directory: macDir, model: mac, passcode: "second-device")
        // Friends learn of the new device as they hear from the account.
        for name in ["P1", "P2", "P3"] {
            let chat = d("P0").model.startConversation(kind: .direct, title: "", members: [fp(name)])
            d("P0").model.send("setup from P0 to \(name)", in: chat.id)
        }
        await settle(60) {
            ["P1", "P2", "P3"].allSatisfy { n in (d(n).model.contact(fp("P0"))?.devices.filter { $0.session != nil }.count ?? 0) >= 2 }
        }

        // A second persona on P1, a friend of P2 and P3 only.
        let persona = try #require(d("P1").model.createPersona(name: "P1b"))
        personaFP = try #require(d("P1").model.me(persona.id)).fingerprint
        d("P1").model.switchPersona(persona.id)
        for name in ["P2", "P3"] {
            let invite = d("P1").model.makeInviteCode()
            _ = d(name).model.addContact(code: invite, nickname: "")
        }
        d("P1").model.switchPersona(nil)
        await settle(60) { ["P2", "P3"].allSatisfy { n in d(n).model.contact(personaFP)?.devices.contains { $0.session != nil } == true } }

        // Two shared groups: everyone's main accounts, and one with P1's persona in it.
        let g1 = d("P0").model.startConversation(kind: .group, title: "Everyone", members: [fp("P1"), fp("P2"), fp("P3")]).id
        let g2 = d("P2").model.startConversation(kind: .group, title: "With the persona", members: [fp("P3"), personaFP]).id
        func joined(_ name: String, _ g: UUID) -> Bool {
            guard let c = d(name).model.conversation(g) else { return false }
            return c.shared?.joining == false
        }
        await settle(120) {
            ["P1", "P2", "P3", "L0"].allSatisfy { joined($0, g1) } && ["P1", "P3"].allSatisfy { joined($0, g2) }
        }
        let setupReport = [
            "P0's friends have both its devices: \(["P1", "P2", "P3"].map { n in "\(n):\(d(n).model.contact(fp("P0"))?.devices.filter { $0.session != nil }.count ?? 0)" }.joined(separator: " "))",
            "persona friends: \(["P2", "P3"].map { n in "\(n):\(d(n).model.contact(personaFP)?.devices.contains { $0.session != nil } == true)" }.joined(separator: " "))",
            "group Everyone joined: \(["P0", "P1", "P2", "P3", "L0"].map { "\($0):\(joined($0, g1))" }.joined(separator: " "))",
            "group With the persona joined: \(["P2", "P1", "P3"].map { "\($0):\(joined($0, g2))" }.joined(separator: " "))",
        ]

        // What can be sent, and who should show it. P0's account is on P0 and L0.
        struct Route { let from: String; let persona: UUID?; let chat: () -> UUID?; let to: [String]; let group: Bool; let label: String }
        func direct(_ from: String, persona: UUID? = nil, to target: String, shows: [String]) -> Route {
            Route(from: from, persona: persona, chat: {
                let other = target == "P1b" ? personaFP : (target == "P0" || target == "L0" ? fp("P0") : fp(target))
                return d(from).model.startConversation(kind: .direct, title: "", members: [other], persona: .some(persona)).id
            }, to: shows, group: false, label: "\(from)\(persona == nil ? "" : "b")->\(target)")
        }
        var routes: [Route] = []
        for a in ["P0", "P1", "P2", "P3"] { for b in ["P0", "P1", "P2", "P3"] where a != b {
            routes.append(direct(a, to: b, shows: b == "P0" ? ["P0", "L0"] : [b]))
        } }
        for b in ["P1", "P2", "P3"] { routes.append(direct("L0", to: b, shows: [b])) }
        for b in ["P2", "P3"] {
            routes.append(direct("P1", persona: persona.id, to: b, shows: [b]))
            routes.append(direct(b, to: "P1b", shows: ["P1"]))
        }
        for from in ["P0", "P1", "P2", "P3", "L0"] {
            let others = ["P0", "P1", "P2", "P3", "L0"].filter { $0 != from && !(Set([from, $0]) == Set(["P0", "L0"])) }
            routes.append(Route(from: from, persona: nil, chat: { g1 }, to: others, group: true, label: "\(from)->Everyone"))
        }
        for from in ["P2", "P3", "P1"] {
            routes.append(Route(from: from, persona: nil, chat: { g2 }, to: ["P2", "P3", "P1"].filter { $0 != from }, group: true,
                                label: "\(from)->Persona group"))
        }

        func look(_ x: Device) {
            var counts: [String: Int] = [:]
            for convo in x.model.data.conversations {
                for m in convo.messages where !m.isMine && m.text.hasPrefix("canary ") {
                    counts[m.text, default: 0] += 1
                    if x.arrived[m.text] == nil { x.arrived[m.text] = Date() }
                }
            }
            for (tag, n) in counts where n > 1 { x.shownTwice.insert(tag) }
        }

        var ledger: [Sent] = []
        var seq = 0
        var relayDownUntil: Date?
        var detaches = 0, restores = 0, relaunches = 0
        var notes: [String] = []
        let started = Date()
        let end = started.addingTimeInterval(minutes * 60)
        func chance(everySeconds: Double) -> Bool { everySeconds > 0 && Double.random(in: 0..<1) < tick / everySeconds }
        func at() -> Int { Int(Date().timeIntervalSince(started)) }

        while Date() < end {
            if let back = relayDownUntil, Date() >= back {
                try relay.start(); relayDownUntil = nil
            } else if relayDownUntil == nil, chance(everySeconds: crashEvery * 60) {
                relay.crash(); relayDownUntil = Date().addingTimeInterval(Double.random(in: 2...20))
                notes.append("relay crashed at +\(at()) s")
            }
            // P3 is detached now and then (an instant wipe) and recovered from its sealed backup, as on a new phone.
            if relayDownUntil == nil, chance(everySeconds: detachEvery * 60) {
                let p3 = d("P3")
                let seed = try #require(p3.model.identity?.seed)
                // What it sent that hasn't got through can't be sent again by anyone now.
                for k in ledger.indices where ledger[k].from == "P3" && ledger[k].to.contains(where: { d($0).arrived[ledger[k].tag] == nil }) {
                    ledger[k].abandoned = true
                }
                do {
                    try await p3.model.detach(.thisDevice, recoveryCode: p3.model.recoveryCode)
                    detaches += 1
                    let dir = base.appending(path: "P3-\(detaches)")
                    let fresh = open(dir, tally: tally)
                    let identity = try Identity(seed: seed)
                    if case let .found(backup) = await fresh.backup(of: identity) {
                        try await Task.sleep(for: .seconds(1.1))
                        try await fresh.restore(seed: seed, passcode: "canary-passcode", from: backup)
                        fresh.data.security.autoLockMinutes = 0
                        p3.model = fresh
                        p3.directory = dir
                        restores += 1
                        p3.events.append("detached and recovered at +\(at()) s")
                    } else {
                        notes.append("DETACH LEFT NO BACKUP at +\(at()) s")
                    }
                } catch {
                    notes.append("detach failed at +\(at()) s: \(error)")
                }
            }
            for x in all() {
                if x.awake, chance(everySeconds: sleepEvery * 60) { x.asleepUntil = Date().addingTimeInterval(Double.random(in: 30...240)) }
                if chance(everySeconds: relaunchEvery * 60) {
                    x.model.lock()
                    let fresh = open(x.directory, tally: tally)
                    if await fresh.unlock(passcode: x.passcode) {
                        fresh.data.security.autoLockMinutes = 0
                        x.model = fresh
                        relaunches += 1
                        x.events.append("reopened at +\(at()) s")
                    } else {
                        notes.append("\(x.name) DID NOT OPEN AGAIN at +\(at()) s")
                    }
                }
                if chance(everySeconds: sendEvery) {
                    let options = routes.filter { $0.from == x.name }
                    if let route = options.randomElement(), let chat = route.chat() {
                        seq += 1
                        let tag = "canary \(route.label) #\(seq)"
                        x.model.send(tag, in: chat)
                        ledger.append(Sent(tag: tag, from: x.name, to: route.to, at: Date(), group: route.group))
                    }
                }
                if x.awake { await x.model.syncOnce(); look(x) }
            }
            try? await Task.sleep(for: .milliseconds(Int(tick * 1000)))
        }

        if relayDownUntil != nil { try relay.start() }
        for x in all() { x.asleepUntil = .distantPast }
        func missing() -> [(Sent, String)] {
            ledger.filter { !$0.abandoned }.flatMap { s in s.to.filter { d($0).arrived[s.tag] == nil }.map { (s, $0) } }
        }
        let drainStart = Date()
        let drainEnd = drainStart.addingTimeInterval(drainMinutes * 60)
        var missingAtEnd = -1
        while Date() < drainEnd {
            for x in all() { await x.model.syncOnce(); look(x) }
            if missingAtEnd < 0 { missingAtEnd = missing().count }
            if missing().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let drainSeconds = Int(Date().timeIntervalSince(drainStart))

        let lost = missing()
        let twice = all().flatMap { x in x.shownTwice.map { "\($0) on \(x.name)" } }
        func kind(_ s: Sent) -> String {
            if s.group { return "group" }
            if s.tag.contains("b->") || s.tag.contains("P1b") { return "persona" }
            if s.from == "L0" || s.to.contains("L0") { return "linked device" }
            if s.from == "P3" || s.to.contains("P3") { return "detached phone" }
            return "plain"
        }
        let kinds = ["plain", "group", "persona", "linked device", "detached phone"]
        let byKind = kinds.map { k in
            let sent = ledger.filter { kind($0) == k }
            return "  \(k): sent \(sent.count), lost \(lost.filter { kind($0.0) == k }.count)"
        }.joined(separator: "\n")
        let report = """
        CANARY accounts: 4 phones + 1 linked Mac, \(Int(minutes)) min run + \(drainSeconds) s drain
        \(setupReport.map { "  " + $0 }.joined(separator: "\n"))
          relay crashes: \(relay.crashes), app reopens: \(relaunches), detached and recovered: \(restores) of \(detaches)
          sent: \(ledger.count) (\(ledger.filter(\.abandoned).count) from P3 before a Detach, not counted)
          deliveries missing: \(lost.count) (\(max(missingAtEnd, 0)) when the run ended)
          shown twice: \(twice.count)
          envelopes handled \(tally.handled), junk \(tally.junk), held back \(tally.retry)
        \(byKind)
        \(lost.prefix(30).map { "  LOST \($0.0.tag) on \($0.1), sent at +\(Int($0.0.at.timeIntervalSince(started))) s" }.joined(separator: "\n"))
        \(twice.prefix(20).map { "  TWICE \($0)" }.joined(separator: "\n"))
        \(notes.joined(separator: "\n"))
        \(all().map { "\($0.name): \($0.events.joined(separator: "; "))" }.joined(separator: "\n"))
        """
        print(report)
        if let out = Self.env["CANARY_REPORT"] { try? report.write(toFile: out, atomically: true, encoding: .utf8) }
        #expect(lost.isEmpty, "every message and post reached every device that should show it")
        #expect(twice.isEmpty, "nothing shown twice")
    }
}
