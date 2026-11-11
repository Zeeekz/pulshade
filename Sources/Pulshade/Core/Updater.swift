#if os(macOS)
import AppKit
import CryptoKit
import Foundation
import Security

/// A Mac release published on the relay by the operator.
struct Release: Decodable, Equatable, Sendable {
    var version: String
    var build: Int
    var size: Int
    var sha256: String
    var notes: String
    var signature: String

    /// Exactly what the release key signed. The notes are covered by their hash.
    var signed: Data {
        let notesHash = Data(SHA256.hash(data: Data(notes.utf8))).hex
        return Data("pulshade-update|mac|\(build)|\(version)|\(size)|\(sha256)|\(notesHash)".utf8)
    }

    func verified(by key: Curve25519.Signing.PublicKey) -> Bool {
        guard let sig = Data(base64Encoded: signature) else { return false }
        return key.isValidSignature(sig, for: signed)
    }
}

/// Keeps the Mac app up to date from the relay, over the same connection as everything else (Tor for an onion relay).
/// A release only counts if it's signed by the key built into this app, so neither the relay nor anyone on the way
/// can hand over an app of their own.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release)
        case installing
        case failed(String)
    }

    private(set) var phase = Phase.idle
    private(set) var lastChecked: Date?

    /// The release key, set by the build. Without it (a build of your own) the app never updates itself.
    static let key: Curve25519.Signing.PublicKey? = (Bundle.main.object(forInfoDictionaryKey: "PulshadeReleaseKey") as? String)
        .flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }

    static var build: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var enabled: Bool { key != nil }

    /// The highest build this device has ever seen offered under a valid signature, kept past relaunch so a
    /// relay (or anyone on the way, with Tor off) can't freeze it on an old one by replaying an older-but-
    /// still-newer-than-installed signed manifest once a newer one has been seen. Never below the build
    /// actually running, so a copy that was updated some other way starts with the right floor too.
    static var highWaterMark: Int {
        get { max(UserDefaults.standard.integer(forKey: "pulshade.updateHighWaterMark"), build) }
        set { UserDefaults.standard.set(newValue, forKey: "pulshade.updateHighWaterMark") }
    }

    /// Whether an already-verified release is new enough to act on: never older than the highest build this
    /// device has ever seen offered. Records `build` as the new high-water mark when it passes, so a relay
    /// can't walk the mark back down by withholding the newest manifest and later replaying an older one.
    static func acceptable(_ build: Int) -> Bool {
        guard build >= highWaterMark else { return false }
        highWaterMark = build
        return true
    }

    /// A newer release is waiting to be installed.
    var ready: Bool {
        if case .available = phase { return true }
        return false
    }

    func check(_ client: RelayClient) async {
        guard let key = Self.key else { return }
        switch phase {
        case .checking, .downloading, .installing: return
        default: break
        }
        let previous = phase
        phase = .checking
        let release = try? await client.latestRelease()
        lastChecked = Date()
        guard let release else {
            // Unreachable for now: keep showing what was known before.
            phase = previous
            return
        }
        guard release.verified(by: key) else { phase = .failed("The update's signature didn't match, so it was ignored."); return }
        guard Self.acceptable(release.build) else {
            // Older than one already seen for this app: a withheld or replayed manifest, not a real update.
            phase = .failed("That update is older than one already offered for this app, so it was ignored.")
            return
        }
        phase = release.build > Self.build ? .available(release) : .upToDate
    }

    func install(_ client: RelayClient) async {
        guard case .available(let release) = phase, let key = Self.key, release.verified(by: key) else { return }
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              !target.path.contains("/AppTranslocation/") else {
            phase = .failed("Move PULSHADE into your Applications folder first, then try again.")
            return
        }
        phase = .downloading(release)
        // The signed size caps what's held in memory: a broken or hostile relay can't make the updater read an
        // unbounded body.
        guard release.size > 0, release.size <= 256 * 1024 * 1024 else {
            phase = .failed("That update is too large, so it wasn't downloaded.")
            return
        }
        do {
            let zip = try await client.releaseArchive()
            guard zip.count == release.size, Data(SHA256.hash(data: zip)).hex == release.sha256 else {
                phase = .failed("The download didn't match the update, so it wasn't installed. Try again in a moment.")
                return
            }
            phase = .installing
            let app = try await Task.detached { try Self.unpack(zip, expecting: release) }.value
            defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app)
            Self.relaunch(target)
        } catch {
            phase = .failed("The update couldn't be installed. Try again in a moment.")
        }
    }

    /// Unzips the release beside nothing else and checks it is the app and build it claims to be.
    nonisolated private static func unpack(_ zip: Data, expecting release: Release) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pulshade-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appending(path: "update.zip")
        try zip.write(to: archive)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        let app = folder.appending(path: "Pulshade.app")
        guard ditto.terminationStatus == 0,
              let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleVersion"] as? String == String(release.build) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try verifySignature(of: app)
        return app
    }

    /// The release key and its signed SHA-256 prove the archive came from the operator. This proves the app inside
    /// is a validly signed app with this app's bundle identifier, and (when this build carries a Developer ID team)
    /// that it is anchored in Apple's trust store and signed by the same team: not something repackaged on the way.
    /// A build that is only ad hoc signed has no team to anchor to, so there the signature and identifier are what
    /// can be checked without breaking self-updates. (Notarization is left to Gatekeeper when the replacement opens.)
    nonisolated private static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var clauses: [String] = []
        if let team = signingTeam {
            clauses.append("anchor apple generic")
            clauses.append("certificate leaf[subject.OU] = \"\(team)\"")
        }
        if let identifier = Bundle.main.bundleIdentifier {
            clauses.append("identifier \"\(identifier)\"")
        }
        guard !clauses.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clauses.joined(separator: " and ") as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement) == errSecSuccess else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    /// This app's Developer ID team, when it is signed with one. A build signed ad hoc has none, and the update is
    /// then checked for a valid signature and the same bundle identifier, but no team or Apple anchor is compared.
    nonisolated private static var signingTeam: String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Quits, and opens the new app once this one has gone.
    private static func relaunch(_ app: URL) {
        let opener = Process()
        opener.executableURL = URL(filePath: "/bin/sh")
        opener.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", app.path]
        try? opener.run()
        NSApp.terminate(nil)
    }
}
#endif
