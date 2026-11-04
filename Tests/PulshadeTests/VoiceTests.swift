import Testing
import Foundation
import AVFoundation
@testable import Pulshade

struct VoiceTests {
    /// Two seconds of a tone, the way a Mac or iPhone microphone hands it over.
    private func tone(seconds: Double, rate: Double, channels: AVAudioChannelCount) throws -> [AVAudioPCMBuffer] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let chunk: AVAudioFrameCount = 2048
        var buffers: [AVAudioPCMBuffer] = []
        var frame = 0
        while Double(frame) < seconds * rate {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk))
            buffer.frameLength = chunk
            for c in 0..<Int(channels) {
                for i in 0..<Int(chunk) {
                    buffer.floatChannelData![c][i] = 0.4 * sin(2 * .pi * 440 * Float(frame + i) / Float(rate))
                }
            }
            buffers.append(buffer)
            frame += Int(chunk)
        }
        return buffers
    }

    @Test(arguments: [(48_000.0, AVAudioChannelCount(1)), (44_100.0, AVAudioChannelCount(2))])
    func notesAreEncodedInMemoryAndPlay(rate: Double, channels: AVAudioChannelCount) throws {
        let buffers = try tone(seconds: 2, rate: rate, channels: channels)
        let stream = try #require(AACStream(input: buffers[0].format))
        for b in buffers { stream.append(b) }
        let (seconds, level) = stream.progress()
        #expect(abs(seconds - 2) < 0.1)
        #expect(level > 100, "a loud tone reads as loud")
        let audio = stream.finish()
        #expect(audio.starts(with: Array("caff".utf8)), "a Core Audio file")
        #expect(audio.count < 2 * 32_000 / 8 * 2, "about 32 kbit/s")
        // Played exactly as a received note is: from the bytes, with no hint about the format.
        let player = try AVAudioPlayer(data: audio)
        #expect(abs(player.duration - 2) < 0.05, "duration \(player.duration), bytes \(audio.count)")
        #expect(player.prepareToPlay())
    }
}
