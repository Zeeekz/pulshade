import AudioToolbox
import Foundation
#if os(macOS)
import AppKit
#endif

/// The sound a new message makes. The tones are made here, not shipped as files, and written to the app's own
/// Library/Sounds folder: that is where the system looks for a custom notification sound, on a locked iPhone too
/// (the relay's wake-up push names the file).
enum MessageTone: String, Codable, CaseIterable, Identifiable {
    /// The system's own notification sound.
    case standard
    case pulse, chime, bubble, drop, knock, tick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Default"
        case .pulse: "Pulse"
        case .chime: "Chime"
        case .bubble: "Bubble"
        case .drop: "Drop"
        case .knock: "Knock"
        case .tick: "Tick"
        }
    }

    /// The name the relay knows it by (it only accepts these), nil for the system's default.
    var relayName: String? { self == .standard ? nil : rawValue }

    var fileName: String? { relayName.map { "tone-\($0).wav" } }

    // MARK: Making the sounds

    static let sampleRate = 44_100

    /// One note: it glides from `from` to `to` Hz, starts `at` seconds in and dies away with time constant `decay`.
    private struct Note {
        var from: Double
        var to: Double
        var at: Double
        var length: Double
        var level: Double
        var decay: Double
        /// A little of the note's octave and fifth above, which is what makes a chime ring instead of beep.
        var bright = 0.0
    }

    private var notes: [Note] {
        switch self {
        case .standard: []
        case .pulse: [Note(from: 660, to: 660, at: 0, length: 0.16, level: 0.8, decay: 0.05),
                      Note(from: 660, to: 660, at: 0.17, length: 0.16, level: 0.8, decay: 0.05)]
        case .chime: [Note(from: 880, to: 880, at: 0, length: 0.9, level: 0.7, decay: 0.22, bright: 0.45),
                      Note(from: 1_320, to: 1_320, at: 0.12, length: 0.9, level: 0.5, decay: 0.22, bright: 0.45)]
        case .bubble: [Note(from: 420, to: 980, at: 0, length: 0.2, level: 0.8, decay: 0.09)]
        case .drop: [Note(from: 980, to: 360, at: 0, length: 0.24, level: 0.8, decay: 0.1)]
        case .knock: [Note(from: 150, to: 110, at: 0, length: 0.14, level: 1.0, decay: 0.03),
                      Note(from: 150, to: 110, at: 0.16, length: 0.14, level: 0.9, decay: 0.03)]
        case .tick: [Note(from: 2_200, to: 1_900, at: 0, length: 0.06, level: 0.7, decay: 0.012)]
        }
    }

    /// 16-bit mono samples of the tone, the same every time.
    func samples() -> [Int16] {
        let notes = self.notes
        guard !notes.isEmpty else { return [] }
        let total = notes.map { $0.at + $0.length }.max() ?? 0
        let count = Int(total * Double(Self.sampleRate)) + 1
        var out = [Double](repeating: 0, count: count)
        for note in notes {
            let start = Int(note.at * Double(Self.sampleRate))
            let n = Int(note.length * Double(Self.sampleRate))
            var phase = 0.0
            for i in 0..<n where start + i < count {
                let t = Double(i) / Double(Self.sampleRate)
                let glide = note.length > 0 ? t / note.length : 0
                let freq = note.from + (note.to - note.from) * glide
                phase += 2 * .pi * freq / Double(Self.sampleRate)
                // A few milliseconds to arrive and to leave, so there's no click.
                let edge = min(1, t / 0.003) * min(1, (note.length - t) / 0.006)
                let body = sin(phase) + note.bright * (0.6 * sin(2 * phase) + 0.3 * sin(3 * phase))
                out[start + i] += body * exp(-t / note.decay) * note.level * edge
            }
        }
        let peak = max(out.map(abs).max() ?? 1, 0.0001)
        return out.map { Int16(max(-1, min(1, $0 / peak * 0.7)) * Double(Int16.max)) }
    }

    /// The tone as a WAV file's bytes.
    func wav() -> Data {
        let pcm = samples()
        let bytes = pcm.count * 2
        var out = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(Self.sampleRate)); put(UInt32(Self.sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        out.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for s in pcm { put(s) }
        return out
    }

    // MARK: On disk

    /// Where the system looks for a notification sound that isn't in the app bundle.
    static var folder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Sounds", isDirectory: true)
    }

    /// Writes the tones the system needs to find, when they're missing or different. Nothing in them is yours.
    static func install(into folder: URL = MessageTone.folder) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for tone in allCases {
            guard let name = tone.fileName else { continue }
            let url = folder.appendingPathComponent(name)
            let bytes = tone.wav()
            if (try? Data(contentsOf: url)) != bytes { try? bytes.write(to: url, options: .atomic) }
        }
    }

    nonisolated(unsafe) private static var preview: [MessageTone: SystemSoundID] = [:]

    /// Plays the tone once, so it can be heard before it's chosen. The default has no file of its own: it plays the
    /// system's.
    @MainActor func play() {
        guard fileName != nil else {
            #if os(macOS)
            NSSound.beep()
            #else
            AudioServicesPlaySystemSound(1007)
            #endif
            return
        }
        Self.install()
        if Self.preview[self] == nil, let name = fileName {
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(Self.folder.appendingPathComponent(name) as CFURL, &id) == kAudioServicesNoError else { return }
            Self.preview[self] = id
        }
        if let id = Self.preview[self] { AudioServicesPlaySystemSound(id) }
    }
}
