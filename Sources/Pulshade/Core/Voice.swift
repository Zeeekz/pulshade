import Foundation
import AVFoundation

/// Records a voice note without ever writing it to disk: the microphone's audio is encoded to AAC as it
/// arrives and kept in memory, so there's no file to clean up or recover afterwards.
@MainActor
@Observable
final class VoiceRecorder {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [UInt8] = []

    static let maxDuration: TimeInterval = 120

    private var engine: AVAudioEngine?
    private var stream: AACStream?
    private var timer: Timer?

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func start() async -> Bool {
        guard !isRecording, await Self.requestPermission() else { return false }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode.outputFormat(forBus: 0)
        guard input.sampleRate > 0, let stream = AACStream(input: input) else { return false }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: input) { buffer, _ in stream.append(buffer) }
        do { try engine.start() } catch {
            engine.inputNode.removeTap(onBus: 0)
            return false
        }
        self.engine = engine
        self.stream = stream
        levels = []
        elapsed = 0
        isRecording = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        return true
    }

    private func sample() {
        guard let stream, isRecording else { return }
        let (seconds, level) = stream.progress()
        elapsed = seconds
        levels.append(level)
        if seconds >= Self.maxDuration { stopEngine() }
    }

    /// Stops and hands back the note, or nil if it was too short to keep.
    func finish() -> VoiceNote? {
        stopEngine()
        let audio = stream?.finish()
        let duration = elapsed
        cleanUp()
        guard let audio, !audio.isEmpty, duration >= 0.5 else { return nil }
        return VoiceNote(audio: audio, duration: duration, levels: Self.downsample(levels, to: 48))
    }

    func cancel() {
        stopEngine()
        cleanUp()
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        timer?.invalidate()
        timer = nil
    }

    private func cleanUp() {
        stream = nil
        isRecording = false
    }

    static func downsample(_ levels: [UInt8], to count: Int) -> [UInt8] {
        guard levels.count > count else { return levels + Array(repeating: 0, count: max(0, count - levels.count)) }
        let size = Double(levels.count) / Double(count)
        return (0..<count).map { i in
            let slice = levels[Int(Double(i) * size)..<min(levels.count, Int(Double(i + 1) * size))]
            return slice.max() ?? 0
        }
    }
}

/// Encodes microphone audio to AAC in memory and wraps it in a Core Audio file, whose packet table
/// gives players the exact length. The tap calls `append` on the audio thread; everything else reads
/// under the same lock.
final class AACStream: @unchecked Sendable {
    static let sampleRate: Double = 22_050

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let output: AVAudioFormat
    private var packets: [Data] = []
    private var frames: Double = 0
    private var inputRate: Double
    private var lastLevel: Float = 0

    init?(input: AVAudioFormat) {
        var description = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                                      mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                                      mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let output = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.bitRate = 32_000
        converter.downmix = true
        self.output = output
        self.converter = converter
        inputRate = input.sampleRate
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        frames += Double(buffer.frameLength)
        lastLevel = Self.level(of: buffer)
        encode(buffer)
    }

    /// Seconds recorded so far, and the latest loudness as 0...255.
    func progress() -> (TimeInterval, UInt8) {
        lock.lock()
        defer { lock.unlock() }
        return (frames / inputRate, UInt8(max(0, min(1, lastLevel)) * 255))
    }

    /// Flushes what the encoder still holds and returns the whole note.
    func finish() -> Data {
        lock.lock()
        defer { lock.unlock() }
        encode(nil)
        return caf()
    }

    private func encode(_ buffer: AVAudioPCMBuffer?) {
        var fed = false
        while true {
            let packets = AVAudioCompressedBuffer(format: output, packetCapacity: 16,
                                                  maximumPacketSize: max(converter.maximumOutputPacketSize, 1536))
            var error: NSError?
            let status = converter.convert(to: packets, error: &error) { _, inputStatus in
                if fed {
                    inputStatus.pointee = buffer == nil ? .endOfStream : .noDataNow
                    return nil
                }
                fed = true
                guard let buffer else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            collect(packets)
            if status != .haveData { break }
        }
    }

    private func collect(_ buffer: AVAudioCompressedBuffer) {
        guard let descriptions = buffer.packetDescriptions else { return }
        let bytes = buffer.data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<Int(buffer.packetCount) {
            let d = descriptions[i]
            guard d.mDataByteSize > 0 else { continue }
            packets.append(Data(bytes: bytes + Int(d.mStartOffset), count: Int(d.mDataByteSize)))
        }
    }

    /// A CAF file: format, the encoder's setup bytes, a table of every packet's size, then the packets.
    private func caf() -> Data {
        guard !packets.isEmpty else { return Data() }
        // Apple's AAC encoder starts with 2112 frames of priming; what's left over pads the last packet.
        let priming: Int32 = 2112
        let valid = Int64((frames * Self.sampleRate / inputRate).rounded())
        let total = Int64(packets.count) * 1024
        let remainder = Int32(max(0, total - valid - Int64(priming)))
        var out = Data("caff".utf8) + be(UInt16(1)) + be(UInt16(0))
        func chunk(_ type: String, _ body: Data) { out += Data(type.utf8) + be(Int64(body.count)) + body }
        chunk("desc", be(Self.sampleRate.bitPattern) + be(kAudioFormatMPEG4AAC) + be(UInt32(0)) + be(UInt32(0))
            + be(UInt32(1024)) + be(UInt32(1)) + be(UInt32(0)))
        if let cookie = converter.magicCookie { chunk("kuki", cookie) }
        var table = be(Int64(packets.count)) + be(min(valid, total - Int64(priming))) + be(priming) + be(remainder)
        for p in packets { table += Self.varint(p.count) }
        chunk("pakt", table)
        chunk("data", be(UInt32(0)) + packets.reduce(into: Data()) { $0 += $1 })
        return out
    }

    private func be<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    /// CAF's packet sizes: seven bits a byte, most significant first, the high bit meaning "more follows".
    static func varint(_ value: Int) -> Data {
        var groups = [UInt8(value & 0x7F)]
        var rest = value >> 7
        while rest > 0 {
            groups.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
            rest >>= 7
        }
        return Data(groups)
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return (db + 50) / 50
    }
}

/// Plays a note straight from memory.
@MainActor
@Observable
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = VoicePlayer()

    private(set) var playing: UUID?
    private(set) var progress: Double = 0
    /// How fast notes play: 1x, 1.5x or 2x. It stays where you left it, like Telegram's.
    private(set) var rate: Float = 1
    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Steps 1x, then 1.5x, then 2x, then back to 1x; a note already playing speeds up straight away.
    func cycleRate() {
        rate = rate < 1.25 ? 1.5 : (rate < 1.75 ? 2 : 1)
        player?.rate = rate
    }

    func toggle(_ note: VoiceNote, id: UUID) {
        if playing == id {
            stop()
            return
        }
        stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let player = try? AVAudioPlayer(data: note.audio) else { return }
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.play()
        self.player = player
        playing = id
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        timer?.invalidate()
        timer = nil
        playing = nil
        progress = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

/// Removes what an audio file says about itself: creation and modification times, and any tags
/// (encoder, device, title). Tag boxes are blanked into padding rather than cut out, so every
/// offset inside the file stays valid and it still plays.
enum MP4Scrub {
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf"]
    private static let tags: Set<String> = ["udta", "meta"]
    private static let timed: Set<String> = ["mvhd", "tkhd", "mdhd"]

    static func clean(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        walk(&bytes, from: 0, to: bytes.count)
        return Data(bytes)
    }

    private static func walk(_ b: inout [UInt8], from start: Int, to end: Int) {
        var i = start
        while i + 8 <= end {
            var size = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            var header = 8
            if size == 1, i + 16 <= end {
                size = (8..<16).reduce(0) { $0 << 8 | Int(b[i + $1]) }
                header = 16
            } else if size == 0 {
                size = end - i
            }
            guard size >= header, i + size <= end else { return }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            if tags.contains(type) {
                b.replaceSubrange((i + 4)..<(i + 8), with: Array("free".utf8))
                for j in (i + header)..<(i + size) { b[j] = 0 }
            } else if timed.contains(type), i + header + 4 <= i + size {
                // Version 1 stores the two times as 64-bit numbers, version 0 as 32-bit.
                let width = b[i + header] == 1 ? 8 : 4
                let first = i + header + 4
                if first + width * 2 <= i + size { for j in first..<(first + width * 2) { b[j] = 0 } }
            } else if containers.contains(type) {
                walk(&b, from: i + header, to: i + size)
            }
            i += size
        }
    }
}
