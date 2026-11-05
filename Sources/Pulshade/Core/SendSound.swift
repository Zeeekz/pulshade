import AudioToolbox
import Foundation

/// The sound of sending: a short, chunky "tok", like a solid block set down. Made here rather than shipped as a file,
/// and played as a system sound: on iPhone it follows the ring/silent switch and the ringer volume, and it never takes
/// over the audio a call or a voice note is using.
enum SendSound {
    static let sampleRate = 44_100
    static let seconds = 0.09
    /// How loud, as a share of full scale.
    static let loudness = 0.55

    /// The thump under it: low, starting a little higher and settling.
    private static let body = 75.0
    /// Where the grit sits: three bands of noise, the lowest loudest.
    private static let grit: [(freq: Double, level: Double)] = [(300, 1.0), (650, 0.7), (1_300, 0.35)]
    /// How clumpy the noise is: near 1 it comes in small chunks, which sounds like something solid landing, not hiss.
    private static let crunch = 0.9

    /// The sound as 16-bit mono PCM samples. The same every time: its noise comes from a fixed seed.
    static func samples() -> [Int16] {
        let count = Int(seconds * Double(sampleRate))
        var seed: UInt32 = 5
        func next() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(seed) / Double(UInt32.max) * 2 - 1
        }
        // Grain: each value held for a few samples, with a little fresh noise over it.
        var noise = [Double](repeating: 0, count: count)
        var hold = 0.0
        for n in 0..<count {
            if n % 6 == 0 { hold = next() }
            noise[n] = hold * crunch + next() * (1 - crunch)
        }
        var gritty = [Double](repeating: 0, count: count)
        for band in grit {
            // A state-variable band-pass around the band's frequency.
            let k = 2 * sin(.pi * band.freq / Double(sampleRate))
            var low = 0.0, mid = 0.0
            for n in 0..<count {
                low += k * mid
                let high = noise[n] - low - 0.55 * mid
                mid += k * high
                gritty[n] += band.level * mid
            }
        }
        var out = [Double](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / Double(sampleRate)
            // Half a millisecond to arrive, so the front is solid without a click; gone in a few hundredths.
            let envelope = exp(-t / 0.014) * (1 - exp(-t / 0.0005))
            let thump = exp(-t / 0.018) * sin(2 * .pi * body * (1 + 0.6 * exp(-t / 0.004)) * t)
            out[n] = gritty[n] * envelope + 0.9 * thump * (1 - exp(-t / 0.0007))
        }
        let peak = out.map(abs).max() ?? 1
        let fade = Double(Int(0.005 * Double(sampleRate)))
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
            let url = dir.appendingPathComponent("send-place-v4.wav")
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
