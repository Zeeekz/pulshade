import Foundation
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// Everything a new device needs to become another device of your account. Sent once, encrypted to the
/// new device, over a mailbox only someone who scanned the QR code can know about.
struct LinkBundle: Codable {
    var seed: Data
    var profile: Profile
    var personas: [Persona]
    var contacts: [ContactCard]
    var conversations: [ConversationCard]
    var theme: String
    var relay: String
    var inviteRelay: String?
    var security: SecuritySettings
    var blocked: [String]
    /// Your devices that already exist, with the mailbox each reads your sync messages on.
    var siblings: [DeviceCard]
    /// The mailboxes behind your public @handles, so this device receives requests too.
    var publicInvites: [OpenInvite]?
    /// Requests waiting for an answer.
    var requests: [FriendRequest]?
}

/// The QR code: a one-time secret, the mailbox to answer on, and which relay to use.
struct LinkCode {
    var secret: Data
    var sendID: Data
    var relay: String

    var text: String {
        "pshlink1" + Base32.encode(secret + sendID + Data(relay.utf8)).lowercased()
    }

    init(secret: Data, sendID: Data, relay: String) {
        self.secret = secret
        self.sendID = sendID
        self.relay = relay
    }

    /// A relay that only means "this machine" (127.0.0.1, localhost) is useless to another device,
    /// so that device uses its own relay setting instead.
    var reachableRelay: String {
        guard let host = URL(string: relay)?.host()?.lowercased(),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host) else { return relay }
        return AppData.defaultRelay
    }

    init?(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.hasPrefix("pshlink1"), let raw = Base32.decode(String(clean.dropFirst(8)).uppercased()), raw.count > 64,
              let relay = Invite.allowedRelay(String(data: Data(raw.dropFirst(64)), encoding: .utf8)) else { return nil }
        secret = Data(raw.prefix(32))
        sendID = Data(raw.dropFirst(32).prefix(32))
        self.relay = relay
    }
}

/// The other way round: a QR code the new device shows, for a logged-in device to scan. It carries
/// the new device's whole request, so the logged-in device only has to approve it.
struct JoinCode {
    var secret: Data
    var request: LinkRequest
    /// Where the new device waits for the account.
    var relay: String

    var text: String {
        let name = Data(String(request.name.prefix(40)).utf8)
        let raw = secret + request.ephemeral + request.bundleSendID + request.selfSendID + request.deviceID
            + Data([UInt8(name.count)]) + name + Data(relay.utf8)
        return "pshjoin1" + Base32.encode(raw).lowercased()
    }

    init(secret: Data, request: LinkRequest, relay: String) {
        self.secret = secret
        self.request = request
        self.relay = relay
    }

    /// As a link, so the phone's own Camera app offers to open Pulshade instead of searching the web for it.
    static func link(_ text: String) -> String { "pulshade://join/" + text }

    init?(_ text: String) {
        let clean = scannedPayload(text).lowercased()
        guard clean.hasPrefix("pshjoin1"), let decoded = Base32.decode(String(clean.dropFirst(8)).uppercased()) else { return nil }
        let raw = Data(decoded)
        let fixed = 32 * 4 + 16
        guard raw.count > fixed else { return nil }
        let nameLength = Int(raw[raw.startIndex + fixed])
        guard raw.count > fixed + 1 + nameLength,
              let name = String(data: raw.subdata(in: fixed + 1 ..< fixed + 1 + nameLength), encoding: .utf8),
              let relay = Invite.allowedRelay(String(data: raw.subdata(in: fixed + 1 + nameLength ..< raw.count), encoding: .utf8)),
              (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw.subdata(in: 32 ..< 64))) != nil else { return nil }
        secret = raw.subdata(in: 0 ..< 32)
        request = LinkRequest(deviceID: raw.subdata(in: 128 ..< 144), name: name.isEmpty ? "New device" : name,
                              ephemeral: raw.subdata(in: 32 ..< 64), bundleSendID: raw.subdata(in: 64 ..< 96),
                              selfSendID: raw.subdata(in: 96 ..< 128))
        self.relay = relay
    }
}

/// A one-time chat link: a throwaway identity's one-use invite plus the moment the chat ends. Whoever
/// opens it joins with a throwaway identity of their own, and both are wiped when the time is up.
struct ChatLink: Equatable {
    var invite: String
    var endsAt: Date

    var text: String {
        let seconds = UInt64(endsAt.timeIntervalSince1970)
        return "pshchat1" + Base32.encode(withUnsafeBytes(of: seconds.bigEndian) { Data($0) } + Data(invite.utf8)).lowercased()
    }

    var link: String { "pulshade://chat/" + text }

    init(invite: String, endsAt: Date) {
        self.invite = invite
        self.endsAt = endsAt
    }

    init?(_ text: String) {
        let clean = scannedPayload(text).lowercased()
        guard clean.hasPrefix("pshchat1"), let raw = Base32.decode(String(clean.dropFirst(8)).uppercased()),
              raw.count > 8 else { return nil }
        let bytes = Data(raw)
        let seconds = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let invite = String(data: bytes.dropFirst(8), encoding: .utf8), Invite(code: invite)?.kind == .contact else { return nil }
        self.invite = invite
        endsAt = Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// A one-time chat link as twelve digits to read out or type, so no link has to be sent over another app.
/// The link waits on the relay, sealed, in a mailbox only the digits lead to, and the first device to type
/// them takes it. The digits are stretched slowly, like a passcode, so trying them all would take years.
struct ChatCode: Equatable {
    static let length = 12
    let digits: String

    static func make() -> ChatCode {
        ChatCode(digits: String(format: "%012llu", UInt64.random(in: 0..<1_000_000_000_000)))
    }

    private init(digits: String) { self.digits = digits }

    /// Twelve digits, with any spaces or dashes in between.
    init?(_ text: String) {
        let digits = text.filter(\.isNumber)
        guard digits.count == Self.length, text.allSatisfy({ $0.isNumber || " -".contains($0) }) else { return nil }
        self.digits = digits
    }

    /// In groups of four, easy to read out.
    var display: String {
        stride(from: 0, to: digits.count, by: 4).map { i in
            String(digits.dropFirst(i).prefix(4))
        }.joined(separator: " ")
    }

    /// The mailbox and seal behind the digits. Slow on purpose (a fraction of a second): run it off the main thread.
    func keys() -> (receiveKey: Data, seal: SymmetricKey) {
        let master = Vault.stretch(digits, salt: Data("pulshade.chatcode.v1".utf8), iterations: 600_000)
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(label.utf8), outputByteCount: 32)
        }
        return (derive("pulshade.chatcode.mailbox").withUnsafeBytes { Data($0) }, derive("pulshade.chatcode.seal"))
    }

    /// Every sealed link is the same size, so the relay can't tell anything from it.
    static let sealedSize = 2048

    static func seal(_ link: ChatLink, with key: SymmetricKey) -> Data? {
        let text = Data(link.text.utf8)
        guard text.count <= sealedSize - 2 else { return nil }
        var padded = withUnsafeBytes(of: UInt16(text.count).bigEndian) { Data($0) } + text
        padded.append(Data(count: sealedSize - padded.count))
        return try? ChaChaPoly.seal(padded, using: key).combined
    }

    static func open(_ blob: Data, with key: SymmetricKey) -> ChatLink? {
        guard let box = try? ChaChaPoly.SealedBox(combined: blob), let padded = try? ChaChaPoly.open(box, using: key),
              padded.count >= 2 else { return nil }
        let length = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard length <= padded.count - 2, let text = String(data: padded.dropFirst(2).prefix(length), encoding: .utf8) else { return nil }
        return ChatLink(text)
    }
}

/// A code you made, kept until its chat ends so the sealed link can be taken off the relay if nobody used it.
struct ChatCodeOffer: Codable, Equatable {
    var receiveKey: Data
    var endsAt: Date
}

/// The code inside a scanned pulshade:// link, or the text itself.
func scannedPayload(_ text: String) -> String {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard clean.lowercased().hasPrefix("pulshade://"), let last = URL(string: clean)?.lastPathComponent,
          !last.isEmpty, last != "/" else { return clean }
    return last
}

enum LinkCrypto {
    static func requestKey(_ secret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Data("pulshade.link.request".utf8),
                               outputByteCount: 32)
    }

    /// The bundle key mixes a fresh exchange with the QR secret: you need both the code and the new device's key.
    static func bundleKey(_ shared: SharedSecret, secret: Data) -> SymmetricKey {
        let ikm = shared.withUnsafeBytes { Data($0) } + secret
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), info: Data("pulshade.link.bundle".utf8),
                                      outputByteCount: 32)
    }
}

/// What this device calls itself when it asks to be linked. Just the kind of device: the name you gave it
/// often includes your own.
@MainActor var deviceDisplayName: String {
    #if os(macOS)
    "Mac"
    #else
    UIDevice.current.model
    #endif
}

extension LinkRequest {
    /// Six digits both devices show while linking. They only match when the device asking is the one in your
    /// hand, so someone who saw the code can't get in by answering it first.
    var checkCode: String {
        let digest = SHA256.hash(data: Data("pulshade.link.check".utf8) + ephemeral)
        let number = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        let digits = String(format: "%06d", number)
        return digits.prefix(3) + " " + digits.suffix(3)
    }
}

/// A new device waiting to be approved and receive the account.
@MainActor
@Observable
final class DeviceLinker {
    enum Stage: Equatable { case idle, waiting, received, failed(String) }

    private(set) var stage: Stage = .idle
    private(set) var bundle: LinkBundle?
    private(set) var code: LinkCode?
    /// The code this device shows while it waits to be scanned.
    private(set) var joinCode: String?
    /// The relay the account arrived through, which this device then keeps using.
    private(set) var relay = AppData.defaultRelay
    let deviceID = Data.random(16)
    let selfMailbox = Mailbox.make()
    private let bundleMailbox = Mailbox.make()
    private let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    private var task: Task<Void, Never>?

    /// The digits to compare with the device approving this one.
    var checkCode: String { request.checkCode }

    private var request: LinkRequest {
        LinkRequest(deviceID: deviceID, name: deviceDisplayName, ephemeral: ephemeral.publicKey.rawRepresentation,
                    bundleSendID: bundleMailbox.sendID, selfSendID: selfMailbox.sendID)
    }

    /// Uses a code from a logged-in device.
    func start(_ text: String) {
        guard let code = LinkCode(text) else {
            stage = .failed("That isn't a PULSHADE link code")
            return
        }
        self.code = code
        relay = code.reachableRelay
        stage = .waiting
        let request = request
        task?.cancel()
        task = Task { await run(code, request) }
    }

    /// Shows a code for a logged-in device to scan, and waits for it to send the account.
    func offer() {
        let secret = Data.random(32)
        relay = AppData.defaultRelay
        joinCode = JoinCode(secret: secret, request: request, relay: relay).text
        stage = .idle
        task?.cancel()
        task = Task { [relay] in
            guard let url = URL(string: relay) else { return }
            await waitForBundle(RelayClient(base: url), secret: secret)
        }
    }

    func cancel() {
        task?.cancel()
        stage = .idle
        bundle = nil
    }

    private func run(_ code: LinkCode, _ request: LinkRequest) async {
        guard let url = URL(string: code.reachableRelay),
              let plain = try? JSONEncoder().encode(request),
              let sealed = try? ChaChaPoly.seal(plain, using: LinkCrypto.requestKey(code.secret)).combined else {
            stage = .failed("Couldn't prepare the request")
            return
        }
        let relay = RelayClient(base: url)
        do {
            try await relay.deposit(sealed, to: code.sendID)
        } catch {
            stage = .failed("Can't reach the relay")
            return
        }
        await waitForBundle(relay, secret: code.secret)
    }

    /// Waits for your other device to approve and send the account (up to ten minutes).
    private func waitForBundle(_ relay: RelayClient, secret: Data) async {
        for _ in 0..<300 {
            if Task.isCancelled { return }
            if let envelopes = try? await relay.fetch([bundleMailbox.receiveKey]), let first = envelopes.first {
                try? await relay.ack(envelopes)
                if let bundle = open(first.blob, secret: secret) {
                    self.bundle = bundle
                    stage = .received
                } else {
                    stage = .failed("The account didn't check out")
                }
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        if !Task.isCancelled { stage = .failed("Timed out. Try again.") }
    }

    private func open(_ blob: Data, secret: Data) -> LinkBundle? {
        guard blob.count > 32, let theirs = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: blob.prefix(32)),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: theirs),
              let box = try? ChaChaPoly.SealedBox(combined: blob.dropFirst(32)),
              let plain = try? ChaChaPoly.open(box, using: LinkCrypto.bundleKey(shared, secret: secret)) else { return nil }
        return try? JSONDecoder.pulshade.decode(LinkBundle.self, from: plain)
    }
}
