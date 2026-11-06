import AudioToolbox
import Foundation

/// The sound of sending: two quiet taps, a hair apart, the second a touch higher, like a soft key pressed twice. Made
/// here rather than shipped as a file, and played as a system sound: on iPhone it follows the ring/silent switch and
/// the ringer volume, and it never takes over the audio a call or a voice note is using.
enum SendSound {
    static let sampleRate = 44_100
    static let seconds = 0.12
    /// How loud, as a share of full scale. Quiet on purpose.
    static let loudness = 0.30
    /// When the second tap lands.
    private static let gap = 0.05

    /// A short dull click: noise, softened and with its lowest part taken out, dying in about a millisecond.
    private static func click(decay: Double, bright: Double, count: Int, seed: UInt32) -> [Double] {
        var state = seed
        func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / Double(UInt32.max) * 2 - 1
        }
        let length = min(count, Int(0.010 * Double(sampleRate)))
        var soft = [Double](repeating: 0, count: length)
        var held = 0.0
        for n in 0..<length {
            held += bright * (next() * exp(-Double(n) / Double(sampleRate) / decay) - held)
            soft[n] = held
        }
        var low = 0.0
        return soft.map { v in low += 0.02 * (v - low); return v - low }
    }

    /// A small round tone that glides down a little as it fades.
    private static func tone(seconds: Double, from: Double, to: Double, glide: Double, rise: Double, fall: Double) -> [Double] {
        var phase = 0.0
        return (0..<Int(seconds * Double(sampleRate))).map { n in
            let t = Double(n) / Double(sampleRate)
            phase += 2 * .pi * (to + (from - to) * exp(-t / glide)) / Double(sampleRate)
            return (1 - exp(-t / rise)) * exp(-t / fall) * sin(phase)
        }
    }

    /// The sound as 16-bit mono PCM samples. The same every time: its noise comes from fixed seeds.
    static func samples() -> [Int16] {
        let count = Int(seconds * Double(sampleRate))
        var out = [Double](repeating: 0, count: count)
        func mix(_ part: [Double], gain: Double, at start: Double) {
            let offset = Int(start * Double(sampleRate))
            for (n, v) in part.enumerated() where offset + n < count { out[offset + n] += gain * v }
        }
        mix(click(decay: 0.0013, bright: 0.4, count: count, seed: 7), gain: 0.9, at: 0)
        mix(tone(seconds: 0.05, from: 420, to: 300, glide: 0.01, rise: 0.001, fall: 0.014), gain: 0.7, at: 0)
        mix(click(decay: 0.0011, bright: 0.55, count: count, seed: 11), gain: 0.8, at: gap)
        mix(tone(seconds: 0.06, from: 520, to: 380, glide: 0.01, rise: 0.001, fall: 0.016), gain: 0.45, at: gap)
        let peak = out.map(abs).max() ?? 1
        let fade = Double(Int(0.012 * Double(sampleRate)))
        return out.enumerated().map { n, v in
            let tail = min(1, Double(count - n) / fade)
            return Int16(v / peak * loudness * tail * Double(Int16.max))
        }
    }

    /// The sound as a WAV file's bytes.
    static func wav() -> Data {
        let pcm = samples()
        let bytes = pcm.count * 2
        var out = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        out.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + bytes))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        out.append(contentsOf: Array("data".utf8)); put(UInt32(bytes))
        for s in pcm { put(s) }
        return out
    }

    nonisolated(unsafe) private static var soundID: SystemSoundID?

    /// Plays it. The first time, the sound is written to the caches folder (it holds nothing of yours) and
    /// registered with the system.
    @MainActor static func play() {
        if soundID == nil {
            // On the Mac the caches folder is shared by every app, so this one keeps to its own.
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.pulshade", isDirectory: true)
            let url = dir.appendingPathComponent("send-taps-v6.wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard (try? wav().write(to: url, options: .atomic)) != nil else { return }
            }
            var id: SystemSoundID = 0
            guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return }
            soundID = id
        }
        if let soundID { AudioServicesPlaySystemSound(soundID) }
    }
}
