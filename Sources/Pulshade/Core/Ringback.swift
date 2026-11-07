import AVFoundation
import Foundation

/// What you hear while you're calling someone and they haven't answered yet: a soft chord that swells and fades into
/// a wash of reverb, then a pause, over and over. Made here, not shipped as a file, the way the message tones are.
enum Ringback {
    static let sampleRate = 48_000.0
    /// One round, tail included, so it loops without a seam.
    static let cycle = 4.2
    /// How long the reverb is let ring on past the chord. It's folded back onto the start of the next round.
    private static let tail = 2.5
    /// The loudest it gets, out of 1. Quiet on purpose: it plays on the loudspeaker.
    static let level = 0.28

    /// One round of the sound, mono.
    static func samples() -> [Float] {
        let rate = sampleRate
        let total = Int((cycle + tail) * rate)
        var x = [Double](repeating: 0, count: total)

        // The chord: D, A, E and the A above, each as two sines a hair apart so it shimmers.
        let padLength = 2.6
        let count = Int(padLength * rate)
        var pad = [Double](repeating: 0, count: count)
        for (freq, amp) in [(293.66, 0.5), (440.0, 0.5), (659.25, 0.5), (880.0, 0.25)] {
            for detune in [-0.7, 0.7] {
                let step = 2 * Double.pi * (freq + detune) / rate
                for i in 0..<count { pad[i] += sin(step * Double(i)) * amp }
            }
        }
        // Rounded off, then swelled in over 0.9 s and out over 1.4 s.
        let a = exp(-2 * Double.pi * 2_400 / rate)
        var held = 0.0
        for i in 0..<count {
            held = (1 - a) * pad[i] + a * held
            let t = Double(i) / rate
            x[i] = held * min(1, t / 0.9) * min(1, (padLength - t) / 1.4)
        }

        let wet = reverb(x)
        var loop = [Double](repeating: 0, count: Int(cycle * rate))
        for i in 0..<loop.count { loop[i] = wet[i] }
        // What rang on past the end comes round again at the start.
        for i in loop.count..<total where i - loop.count < loop.count { loop[i - loop.count] += wet[i] }

        let mean = loop.reduce(0, +) / Double(loop.count)
        for i in loop.indices { loop[i] -= mean }
        let peak = max(loop.map(abs).max() ?? 1, 0.0001)
        return loop.map { Float($0 / peak * level) }
    }

    /// A small room: four echoes in parallel, then two smearing stages, mixed in at 40%.
    private static func reverb(_ x: [Double]) -> [Double] {
        let rate = sampleRate
        var mixed = [Double](repeating: 0, count: x.count)
        for (seconds, gain) in [(0.0297, 0.78), (0.0371, 0.76), (0.0411, 0.74), (0.0437, 0.72)] {
            let k = Int(seconds * rate)
            var c = [Double](repeating: 0, count: x.count)
            for i in x.indices { c[i] = x[i] + (i >= k ? c[i - k] * gain : 0) }
            for i in x.indices { mixed[i] += c[i] / 4 }
        }
        for (seconds, gain) in [(0.005, 0.7), (0.0017, 0.7)] {
            let k = Int(seconds * rate)
            var out = [Double](repeating: 0, count: x.count)
            for i in x.indices { out[i] = -gain * mixed[i] + (i >= k ? mixed[i - k] + gain * out[i - k] : 0) }
            mixed = out
        }
        let wet = 0.4
        return x.indices.map { x[$0] * (1 - wet) + mixed[$0] * wet * 2.2 }
    }

    /// The same sound as a WAV file's bytes: for listening to it outside a call, and tests.
    static func wav() -> Data {
        let pcm = samples().map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var out = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        let rate = UInt32(sampleRate)
        out.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count * 2))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(rate); put(rate * 2); put(UInt16(2)); put(UInt16(16))
        out.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count * 2))
        for s in pcm { put(s) }
        return out
    }

    nonisolated(unsafe) private static var cached: [Float]?
    private static let cacheLock = NSLock()

    /// A buffer of one round in the call's audio format, made once.
    static func buffer(in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let data = cacheLock.withLock { () -> [Float] in
            if let cached { return cached }
            let made = samples()
            cached = made
            return made
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(data.count)
        data.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: data.count) }
        return buffer
    }
}
