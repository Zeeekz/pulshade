import Testing
import Foundation
@testable import Pulshade

/// The delivery counter. Simulated phones, each running the real app code, message each other for a while through a
/// relay of their own while things go wrong: phones go quiet (asleep, no network), apps are closed and opened again,
/// contacts are added from both sides at once (crossed hellos), and the relay crashes and comes back with what it had
/// on disk. Every message carries its own tag, so at the end each one is counted: arrived once, arrived twice, never
/// arrived, or arrived but never ticked as delivered on the sender's side.
///
///   scripts/canary.sh                      (5 phones, 10 minutes)
///   CANARY_PHONES=8 CANARY_MINUTES=120 scripts/canary.sh
///
/// It points the whole process at its own relay, so it never runs beside other suites.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PULSHADE_CANARY"] == "1"), .serialized)
struct CanaryTests {
    private static let env = ProcessInfo.processInfo.environment
    private static func setting(_ name: String, _ fallback: Double) -> Double { env[name].flatMap(Double.init) ?? fallback }

    /// A relay that crashes the hard way (SIGKILL) and starts again on the same folder and storage key, as a server
    /// that loses power or is restarted would.
    private final class CrashingRelay {
        let port: Int
        let directory: URL
        private let key = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        private var process: Process?
        var crashes = 0

        init(port: Int) throws {
            self.port = port + (Int(ProcessInfo.processInfo.environment["PULSHADE_PORT_OFFSET"] ?? "") ?? 0)
            directory = FileManager.default.temporaryDirectory.appending(path: "pulshade-canary-relay-\(UUID().uuidString)")
            try start()
        }

        var url: String { "http://127.0.0.1:\(port)" }
        var running: Bool { process != nil }

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

    @MainActor private final class Phone {
        let name: String
        let directory: URL
        var model: AppModel
        var asleepUntil = Date.distantPast
        var relaunches = 0
        var events: [String] = []
        /// Tags of canary messages this phone has shown, and when it first did.
        var arrived: [String: Date] = [:]
        init(name: String, directory: URL, model: AppModel) { self.name = name; self.directory = directory; self.model = model }
        var fingerprint: String { model.fingerprint }
        var awake: Bool { Date() >= asleepUntil }
    }

    private final class Tally: @unchecked Sendable {
        var handled = 0, junk = 0, retry = 0
    }

    private static let passcode = "canary-passcode"

    private func open(_ directory: URL, tally: Tally) -> AppModel {
        let model = AppModel(vault: Vault(directory: directory), watchSystem: false)
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
        return model
    }

    /// One sent message, as the counter remembers it.
    private struct Sent { let tag: String; let from: Int; let to: Int; let at: Date }

    @Test func everyMessageArrivesOnceAndIsTicked() async throws {
        let phones = Int(Self.setting("CANARY_PHONES", 5))
        let minutes = Self.setting("CANARY_MINUTES", 10)
        let drainMinutes = Self.setting("CANARY_DRAIN_MINUTES", 5)
        let sendEvery = Self.setting("CANARY_SEND_SECONDS", 20)       // per phone, on average
        let crashEvery = Self.setting("CANARY_CRASH_MINUTES", 4)      // relay, on average; 0 = never
        let relaunchEvery = Self.setting("CANARY_RELAUNCH_MINUTES", 5) // per phone, on average; 0 = never
        let sleepEvery = Self.setting("CANARY_SLEEP_MINUTES", 3)      // per phone, on average; 0 = never
        let desyncEvery = Self.setting("CANARY_DESYNC_MINUTES", 6)    // per phone, on average; 0 = never
        let tick = 0.25

        let relay = try CrashingRelay(port: 7896)
        let previousRelay = Self.env["PULSHADE_TEST_RELAY"]
        setenv("PULSHADE_TEST_RELAY", relay.url, 1)
        // The phone's resend schedule, sped up so a run of minutes sees what days of use would.
        let previousGaps = AppModel.resendGaps
        AppModel.resendGaps = (Self.env["CANARY_RESEND_GAPS"]?.split(separator: ",").compactMap { Double($0) }) ?? [8, 20, 45, 90, 180]
        defer {
            AppModel.resendGaps = previousGaps
            relay.stopForGood()
            if let previousRelay { setenv("PULSHADE_TEST_RELAY", previousRelay, 1) } else { unsetenv("PULSHADE_TEST_RELAY") }
        }

        FileKeys.inMemory = true
        let base = testDirectory("pulshade-canary")
        let tally = Tally()
        var crowd: [Phone] = []
        for n in 0..<phones {
            let dir = base.appending(path: "phone-\(n)")
            let model = open(dir, tally: tally)
            try await model.create(identity: .generate(), profile: Profile(name: "P\(n)"), passcode: Self.passcode)
            // A phone in use doesn't lock itself; closing and opening the app (below) stands in for that.
            model.data.security.autoLockMinutes = 0
            crowd.append(Phone(name: "P\(n)", directory: dir, model: model))
        }
        defer { for p in crowd { p.model.lock() } }

        // Everyone befriends everyone. Half the pairs add each other at the same moment, so their first hellos cross.
        var crossed = 0
        var crossedPairs: [String] = []
        for i in 0..<phones { for j in (i + 1)..<phones {
            if Bool.random() {
                let codeI = crowd[i].model.makeInviteCode(), codeJ = crowd[j].model.makeInviteCode()
                _ = crowd[i].model.addContact(code: codeJ, nickname: "")
                _ = crowd[j].model.addContact(code: codeI, nickname: "")
                crossed += 1
                crossedPairs.append("\(crowd[i].name)+\(crowd[j].name)")
            } else {
                _ = crowd[j].model.addContact(code: crowd[i].model.makeInviteCode(), nickname: "")
            }
        } }
        let introEnd = Date().addingTimeInterval(120)
        func everyoneKnowsEveryone() -> Bool {
            crowd.allSatisfy { p in crowd.allSatisfy { q in p === q || p.model.contact(q.fingerprint)?.devices.contains { $0.session != nil } == true } }
        }
        while Date() < introEnd, !everyoneKnowsEveryone() {
            for p in crowd { await p.model.syncOnce() }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let introduced = everyoneKnowsEveryone()
        let unconnected = crowd.flatMap { p in crowd.filter { q in p !== q && p.model.contact(q.fingerprint)?.devices.contains { $0.session != nil } != true }.map { "\(p.name) has no keys for \($0.name)" } }
        let introSeconds = 120 - introEnd.timeIntervalSinceNow

        var ledger: [Sent] = []
        var seq = 0
        var relayDownUntil: Date?
        var failedSyncs = 0
        var relayEvents: [String] = []
        // Copies of each phone's keys for each friend, a minute or more old: put back now and then, as a backup that was a
        // little behind would, so the keys fall out of step and have to mend.
        var oldKeys: [String: (at: Date, session: Ratchet)] = [:]
        var desyncs = 0
        let started = Date()
        let end = started.addingTimeInterval(minutes * 60)
        func chance(everySeconds: Double) -> Bool { everySeconds > 0 && Double.random(in: 0..<1) < tick / everySeconds }

        func look(_ p: Phone) {
            for convo in p.model.data.conversations {
                for m in convo.messages where m.sender != "me" && m.text.hasPrefix("canary ") {
                    if p.arrived[m.text] == nil { p.arrived[m.text] = Date() }
                }
            }
        }

        while Date() < end {
            // The relay.
            if let back = relayDownUntil, Date() >= back {
                try relay.start(); relayDownUntil = nil
            } else if relayDownUntil == nil, chance(everySeconds: crashEvery * 60) {
                relay.crash(); relayDownUntil = Date().addingTimeInterval(Double.random(in: 2...20))
                relayEvents.append("relay crashed at +\(Int(Date().timeIntervalSince(started))) s")
            }
            for (i, p) in crowd.enumerated() {
                // Asleep or out of signal for half a minute to a few minutes; still able to write, not to send.
                if p.awake, chance(everySeconds: sleepEvery * 60) { p.asleepUntil = Date().addingTimeInterval(Double.random(in: 30...240)) }
                // Closed and opened again: a fresh app on the same saved data.
                if chance(everySeconds: relaunchEvery * 60) {
                    p.model.lock()
                    let fresh = open(p.directory, tally: tally)
                    let ok = await fresh.unlock(passcode: Self.passcode)
                    #expect(ok, "\(p.name) opens again")
                    fresh.data.security.autoLockMinutes = 0
                    p.model = fresh
                    p.relaunches += 1
                    p.events.append("reopened at +\(Int(Date().timeIntervalSince(started))) s, phase \(fresh.phase)")
                }
                for q in crowd where q !== p {
                    let key = "\(p.name)|\(q.name)"
                    if let session = p.model.contact(q.fingerprint)?.devices.first?.session,
                       Date().timeIntervalSince(oldKeys[key]?.at ?? .distantPast) > 90 {
                        oldKeys[key] = (Date(), session)
                    }
                }
                if chance(everySeconds: desyncEvery * 60) {
                    var j = Int.random(in: 0..<(phones - 1)); if j >= i { j += 1 }
                    if let old = oldKeys["\(p.name)|\(crowd[j].name)"], Date().timeIntervalSince(old.at) > 30,
                       let ci = p.model.data.contacts.firstIndex(where: { $0.fingerprint == crowd[j].fingerprint }),
                       !p.model.data.contacts[ci].devices.isEmpty {
                        p.model.data.contacts[ci].devices[0].session = old.session
                        desyncs += 1
                        p.events.append("keys for \(crowd[j].name) put back at +\(Int(Date().timeIntervalSince(started))) s")
                    }
                }
                if chance(everySeconds: sendEvery) {
                    var j = Int.random(in: 0..<(phones - 1)); if j >= i { j += 1 }
                    seq += 1
                    let tag = "canary \(p.name)->\(crowd[j].name) #\(seq)"
                    let chat = p.model.startConversation(kind: .direct, title: "", members: [crowd[j].fingerprint])
                    p.model.send(tag, in: chat.id)
                    ledger.append(Sent(tag: tag, from: i, to: j, at: Date()))
                }
                if p.awake {
                    await p.model.syncOnce()
                    if p.model.link == .offline { failedSyncs += 1 }
                    look(p)
                }
            }
            try? await Task.sleep(for: .milliseconds(Int(tick * 1000)))
        }

        // Everyone wakes, the relay is up, and the phones get time to finish what is still in flight.
        if relayDownUntil != nil { try relay.start(); relayDownUntil = nil }
        for p in crowd { p.asleepUntil = .distantPast }
        func lost() -> [Sent] { ledger.filter { crowd[$0.to].arrived[$0.tag] == nil } }
        func unticked() -> [Sent] {
            ledger.filter { s in
                !crowd[s.from].model.data.conversations.contains { c in
                    c.messages.contains { $0.sender == "me" && $0.text == s.tag && ($0.status == .delivered || $0.status == .read) }
                }
            }
        }
        let drainStart = Date()
        let drainEnd = drainStart.addingTimeInterval(drainMinutes * 60)
        var lostAtEndOfRun = -1
        while Date() < drainEnd {
            for p in crowd { await p.model.syncOnce(); look(p) }
            if lostAtEndOfRun < 0 { lostAtEndOfRun = lost().count }
            if lost().isEmpty && unticked().isEmpty { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let drainSeconds = Date().timeIntervalSince(drainStart)

        // Duplicates: the same tag shown more than once in the recipient's chats.
        var duplicates: [String] = []
        for s in ledger {
            let shown = crowd[s.to].model.data.conversations.reduce(0) { n, c in n + c.messages.filter { $0.text == s.tag && $0.sender != "me" }.count }
            if shown > 1 { duplicates.append("\(s.tag) x\(shown)") }
        }
        // How long arrivals took (send to first shown on the other phone), in seconds.
        let delays = ledger.compactMap { s in crowd[s.to].arrived[s.tag].map { $0.timeIntervalSince(s.at) } }.sorted()
        func pct(_ q: Double) -> String {
            guard !delays.isEmpty else { return "-" }
            return String(format: "%.1f", delays[min(delays.count - 1, Int(Double(delays.count) * q))])
        }
        let lostNow = lost(), untickedNow = unticked()
        let report = """
        CANARY \(phones) phones, \(String(format: "%.0f", minutes)) min run + \(String(format: "%.0f", drainSeconds)) s drain
          introductions: \(introduced ? "all" : "NOT ALL") connected in \(String(format: "%.0f", introSeconds)) s (\(crossed) crossed pairs)
          relay crashes: \(relay.crashes), app relaunches: \(crowd.map(\.relaunches).reduce(0, +)), keys put back: \(desyncs), syncs while relay down/offline: \(failedSyncs)
          sent: \(ledger.count)
          lost: \(lostNow.count) (\(max(lostAtEndOfRun, 0)) still missing when the run ended, before the drain)
          duplicates: \(duplicates.count)
          not ticked delivered: \(untickedNow.count)
          envelopes handled \(tally.handled), junk \(tally.junk), held back \(tally.retry)
          delay to arrive p50 \(pct(0.5)) s, p90 \(pct(0.9)) s, p99 \(pct(0.99)) s, max \(delays.last.map { String(format: "%.1f", $0) } ?? "-") s
        \(lostNow.prefix(20).map { "  LOST \($0.tag) sent at +\(Int($0.at.timeIntervalSince(started))) s" }.joined(separator: "\n"))
        \(duplicates.prefix(20).map { "  DUP \($0)" }.joined(separator: "\n"))
        \(untickedNow.prefix(20).map { "  UNTICKED \($0.tag)" }.joined(separator: "\n"))
        """
        var detail = relayEvents + unconnected + ["crossed pairs: " + crossedPairs.joined(separator: " ")]
        for p in crowd {
            let m = p.model
            let sessions = crowd.filter { $0 !== p }.map { q in
                "\(q.name):\(m.contact(q.fingerprint)?.devices.filter { $0.session != nil }.count ?? -1)"
            }.joined(separator: " ")
            detail.append("\(p.name): phase \(m.phase), link \(m.link), outbox \(m.data.outbox.count), sessions \(sessions); \(p.events.joined(separator: "; "))")
        }
        let full = report + "\n" + detail.joined(separator: "\n")
        print(full)
        if let out = Self.env["CANARY_REPORT"] { try? full.write(toFile: out, atomically: true, encoding: .utf8) }

        #expect(introduced, "every pair connected")
        #expect(lostNow.isEmpty, "no message lost")
        #expect(duplicates.isEmpty, "no message shown twice")
        #expect(untickedNow.isEmpty, "every message ticked delivered")
    }
}
