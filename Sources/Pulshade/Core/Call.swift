import Foundation
import AVFoundation
import CryptoKit

/// Ringing someone: the room to meet in on the relay, and the key that seals the call's audio. It only
/// ever travels inside an end-to-end encrypted message, so the relay never sees the key.
struct CallInvite: Codable, Equatable {
    var id: UUID
    var room: Data
    var key: Data
}

/// Seals and opens call packets. Each direction has its own key, every packet its own number, and a
/// packet that's been seen before (or is far too old) is refused. Every packet is padded to the same size,
/// so how loud or how much someone is talking doesn't show in the sizes.
struct CallCrypto {
    enum Kind: UInt8 { case hello = 0, audio = 1 }

    /// Room for any 20 ms Opus packet at the bitrate calls use, plus its length.
    static let bodySize = 256

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sent: UInt64 = 0
    private var newest: UInt64 = 0
    private var seen: Set<UInt64> = []

    init(key: Data, caller: Bool) {
        func derive(_ label: String) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), info: Data(label.utf8), outputByteCount: 32)
        }
        let a = derive("pulshade.call.caller"), b = derive("pulshade.call.callee")
        sendKey = caller ? a : b
        receiveKey = caller ? b : a
    }

    private static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: n.bigEndian) { Data($0) })
    }

    /// `kind | number | sealed`, with the kind and number bound into the seal.
    mutating func seal(_ kind: Kind, _ body: Data) -> Data? {
        guard body.count <= Self.bodySize - 2 else { return nil }
        sent += 1
        let header = Data([kind.rawValue]) + withUnsafeBytes(of: sent.bigEndian) { Data($0) }
        var padded = withUnsafeBytes(of: UInt16(body.count).bigEndian) { Data($0) } + body
        padded.append(Data(count: Self.bodySize - padded.count))
        guard let box = try? ChaChaPoly.seal(padded, using: sendKey, nonce: Self.nonce(sent), authenticating: header) else { return nil }
        return header + box.ciphertext + box.tag
    }

    mutating func open(_ packet: Data) -> (Kind, Data)? {
        let bytes = Data(packet)
        guard bytes.count >= 9 + 16, let kind = Kind(rawValue: bytes[0]) else { return nil }
        let n = bytes[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard n + 100 > newest, !seen.contains(n),
              let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(n), ciphertext: bytes[9..<(bytes.count - 16)],
                                                   tag: bytes[(bytes.count - 16)...]),
              let padded = try? ChaChaPoly.open(box, using: receiveKey, authenticating: bytes[0..<9]), padded.count >= 2
        else { return nil }
        let length = Int(padded[padded.startIndex]) << 8 | Int(padded[padded.startIndex + 1])
        guard length <= padded.count - 2 else { return nil }
        let body = Data(padded.dropFirst(2).prefix(length))
        seen.insert(n)
        newest = max(newest, n)
        if seen.count > 400 { seen = seen.filter { $0 + 200 > newest } }
        return (kind, body)
    }
}

/// One call's connection: a WebSocket to the relay's room, sealed packets both ways, and (unless it's a
/// test) the microphone and speaker. Reports when the other side is heard from and when the room closes.
final class CallMedia: @unchecked Sendable {
    enum Event { case peerHeard, closed }

    private let lock = NSLock()
    private var crypto: CallCrypto
    private let task: URLSessionWebSocketTask
    private let onEvent: @MainActor (Event) -> Void
    private let withAudio: Bool
    private var heard = false
    private var stopped = false
    private var speaker = false
    /// Hellos answered, so two sides that join at different moments always hear each other.
    private var answered = 0
    /// When the other side was last heard. Audio never stops, even in silence, so a long gap means they've gone.
    private var lastHeard = Date()
    private var watchdog: Task<Void, Never>?
    private var greeter: Task<Void, Never>?
    private var audio: CallAudio?
    /// Packets that arrived, for tests without a microphone.
    private(set) var received: [Data] = []

    var muted: Bool {
        get { lock.withLock { audio?.muted ?? false } }
        set { lock.withLock { audio?.muted = newValue } }
    }

    init?(relay: String, invite: CallInvite, caller: Bool, withAudio: Bool, onEvent: @escaping @MainActor (Event) -> Void) {
        guard var parts = URLComponents(string: relay) else { return nil }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        parts.path = (parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path) + "/v1/call/" + invite.room.hex
        // Each call on its own lane, so over Tor it gets its own circuit.
        guard let url = parts.url, let config = try? RelayClient.configuration(for: url, lane: "call|" + invite.room.hex) else { return nil }
        var request = URLRequest(url: url)
        // Over the onion service, joining is rate-limited per circuit only with a proof of work.
        if Tor.isOnion(url) { request.setValue(Work.proof(for: "call|" + invite.room.hex), forHTTPHeaderField: "X-Pulshade-Pow") }
        task = URLSession(configuration: config).webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024
        crypto = CallCrypto(key: invite.key, caller: caller)
        self.onEvent = onEvent
        self.withAudio = withAudio
    }

    func start() {
        task.resume()
        receive()
        // Say hello until the other side answers, so each knows the other is there even in silence.
        greeter = Task { [weak self] in
            while let self, !Task.isCancelled, !self.lock.withLock({ self.heard || self.stopped }) {
                self.send(.hello, Data())
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        if withAudio {
            watchdog = Task { [weak self] in
                while let self, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    let gone = self.lock.withLock { self.heard && !self.stopped && Date().timeIntervalSince(self.lastHeard) > 10 }
                    if gone {
                        Task { @MainActor in self.onEvent(.closed) }
                        return
                    }
                }
            }
            let audio = CallAudio { [weak self] packet in self?.send(.audio, packet) }
            let speaker = lock.withLock {
                self.audio = audio
                return self.speaker
            }
            audio?.start()
            audio?.setSpeaker(speaker)
        }
    }

    func stop() {
        let audio: CallAudio? = lock.withLock {
            stopped = true
            defer { self.audio = nil }
            return self.audio
        }
        greeter?.cancel()
        watchdog?.cancel()
        audio?.stop()
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Loudspeaker or earpiece (iPhone). Remembered, so it applies once the audio starts too.
    func setSpeaker(_ on: Bool) {
        let audio: CallAudio? = lock.withLock {
            speaker = on
            return self.audio
        }
        audio?.setSpeaker(on)
    }

    /// Sends a raw packet as audio. Tests use it in place of a microphone.
    func sendAudio(_ packet: Data) { send(.audio, packet) }

    private func send(_ kind: CallCrypto.Kind, _ body: Data) {
        guard let sealed = lock.withLock({ stopped ? nil : crypto.seal(kind, body) }) else { return }
        task.send(.data(sealed)) { _ in }
    }

    private func receive() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(.data(packet)):
                self.handle(packet)
                self.receive()
            case .success:
                self.receive()
            case .failure:
                let wasStopped = self.lock.withLock { self.stopped }
                if !wasStopped { Task { @MainActor in self.onEvent(.closed) } }
            }
        }
    }

    private func handle(_ packet: Data) {
        let (opened, firstTime, audio, reply): ((CallCrypto.Kind, Data)?, Bool, CallAudio?, Bool) = lock.withLock {
            guard let opened = crypto.open(packet) else { return (nil, false, nil, false) }
            let first = !heard
            heard = true
            lastHeard = Date()
            if opened.0 == .audio && !withAudio { received.append(opened.1) }
            // They're still saying hello, so they haven't heard us yet: answer.
            let reply = opened.0 == .hello && answered < 20
            if reply { answered += 1 }
            return (opened, first, self.audio, reply)
        }
        guard let opened else { return }
        if reply { send(.hello, Data()) }
        if firstTime { Task { @MainActor in self.onEvent(.peerHeard) } }
        if opened.0 == .audio { audio?.play(opened.1) }
    }
}

/// The microphone and speaker for a call: Apple's voice processing (echo cancelling, noise reduction)
/// on the way in, Opus in 20 ms packets, and a short buffer on the way out to ride out jitter.
final class CallAudio: @unchecked Sendable {
    private static let rate: Double = 48_000
    private static let frames: AVAudioFrameCount = 960

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let onPacket: (Data) -> Void
    private let opus: AVAudioFormat
    private let pcm: AVAudioFormat
    private var encoder: AVAudioConverter?
    private let decoder: AVAudioConverter
    /// Buffers handed to the player and not yet played, so the delay never builds up.
    private var queued = 0
    private var restarter: NSObjectProtocol?
    var muted = false

    init?(onPacket: @escaping (Data) -> Void) {
        var description = AudioStreamBasicDescription(mSampleRate: Self.rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.frames), mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false),
              let decoder = AVAudioConverter(from: opus, to: pcm) else { return nil }
        self.opus = opus
        self.pcm = pcm
        self.decoder = decoder
        self.onPacket = onPacket
    }

    func start() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP])
        // A call answered on the system's call screen has its session switched on by the system.
        if !CallRinger.answeredOnScreen { try? session.setActive(true) }
        #endif
        // The speaker side has to be wired up before echo cancelling goes on, or the Mac's output comes up
        // with no channels and the engine won't start.
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcm)
        _ = engine.outputNode
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, let encoder = AVAudioConverter(from: input, to: opus) else { return }
        encoder.bitRate = 24_000
        // Constant bitrate: packet sizes that follow speech can give away what's being said, even encrypted.
        encoder.bitRateStrategy = AVAudioBitRateStrategy_Constant
        encoder.downmix = true
        lock.withLock { self.encoder = encoder }
        engine.inputNode.installTap(onBus: 0, bufferSize: 960, format: input) { [weak self] buffer, _ in self?.capture(buffer) }
        // The system can stop the engine mid-call (a route change, say). Start it again.
        restarter = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                           queue: nil) { [weak self] _ in self?.resume() }
        resume()
    }

    private var startTries = 0

    private func resume() {
        lock.withLock { queued = 0 }
        guard (try? engine.start()) != nil else {
            // The system's call screen switches the session on a moment after the call is answered; try again.
            guard startTries < 20 else { return }
            startTries += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.resume() }
            return
        }
        player.play()
    }

    func stop() {
        if let restarter { NotificationCenter.default.removeObserver(restarter) }
        restarter = nil
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        #if os(iOS)
        if !CallRinger.answeredOnScreen { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        #endif
    }

    func setSpeaker(_ on: Bool) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        #endif
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let encoder = lock.withLock({ encoder }) else { return }
        if muted, let data = buffer.floatChannelData {
            for c in 0..<Int(buffer.format.channelCount) { data[c].update(repeating: 0, count: Int(buffer.frameLength)) }
        }
        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: opus, packetCapacity: 4, maximumPacketSize: max(encoder.maximumOutputPacketSize, 1500))
            var error: NSError?
            let status = encoder.convert(to: out, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if let descriptions = out.packetDescriptions {
                let bytes = out.data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(out.packetCount) where descriptions[i].mDataByteSize > 0 {
                    onPacket(Data(bytes: bytes + Int(descriptions[i].mStartOffset), count: Int(descriptions[i].mDataByteSize)))
                }
            }
            if status != .haveData { break }
        }
    }

    /// Decodes one packet and queues it to play. If too much is already waiting, it's dropped to keep up.
    func play(_ packet: Data) {
        guard lock.withLock({ queued < 6 }), let out = decode(packet) else { return }
        lock.withLock { queued += 1 }
        player.scheduleBuffer(out) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queued -= 1 }
        }
    }

    private func decode(_ packet: Data) -> AVAudioPCMBuffer? {
        let compressed = AVAudioCompressedBuffer(format: opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                          mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: Self.frames) else { return nil }
        var fed = false
        var error: NSError?
        let decoded: AVAudioConverterOutputStatus = lock.withLock {
            decoder.convert(to: out, error: &error) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return compressed
            }
        }
        return decoded != .error && out.frameLength > 0 ? out : nil
    }
}
