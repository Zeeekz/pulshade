import Testing
import Foundation
import AVFoundation
@testable import Pulshade

/// How a video is placed in the story's 9:16 frame: filled (and cut off), or fitted whole with a soft copy behind.
struct StoryFramingTests {
    static let frame = CGSize(width: 720, height: 1280)

    /// A 2-second landscape clip, grey, with a green stripe down its left edge and a blue one down its right.
    static func wideClip() async throws -> MemoryClip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wide-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h, fps) = (320, 180, 10)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for n in 0..<(2 * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
            let b = buffer!
            CVPixelBufferLockBaseAddress(b, [])
            let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(b)
            for y in 0..<h { for x in 0..<w {
                let o = y * stride + x * 4
                let left = x < 24, right = x >= w - 24
                base[o] = right ? 230 : 110       // blue
                base[o + 1] = left ? 230 : 110    // green
                base[o + 2] = 110                 // red
                base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StoryVideoError.unreadable }
        return MemoryClip(try Data(contentsOf: url))
    }

    /// The colour at a place in the exported clip's first picture, with x and y as fractions of it.
    static func colour(of clip: MemoryClip, x: Double, y: Double) async -> (r: Int, g: Int, b: Int) {
        guard let image = await StoryVideo.poster(of: clip) else { return (-1, -1, -1) }
        let (w, h) = (72, 128)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = (Int(y * Double(h - 1)) * w + Int(x * Double(w - 1))) * 4
        return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))
    }

    @Test func fillingCutsOffTheEdgesAndFittingKeepsThem() async throws {
        let source = try await Self.wideClip()
        let size = CGSize(width: 320, height: 180)
        let filled = try await StoryVideo.export(from: source, filter: .none)
        let fitted = try await StoryVideo.export(from: source, filter: .none, framing: .fit(source: size, frame: Self.frame))
        let cut = await Self.colour(of: MemoryClip(filled), x: 0.02, y: 0.5)
        let kept = await Self.colour(of: MemoryClip(fitted), x: 0.02, y: 0.5)
        #expect(cut.g < 160, "filling cuts the left edge off: \(cut)")
        #expect(kept.g > 190 && kept.g > kept.r + 60, "fitting keeps the green stripe at the left edge: \(kept)")
        let right = await Self.colour(of: MemoryClip(fitted), x: 0.98, y: 0.5)
        #expect(right.b > 190 && right.b > right.r + 60, "and the blue one at the right: \(right)")
    }

    @Test func fittedVideoLeavesASoftCopyAboveAndBelow() async throws {
        let source = try await Self.wideClip()
        let fitted = try await StoryVideo.export(from: source, filter: .none, framing: .fit(source: CGSize(width: 320, height: 180), frame: Self.frame))
        let top = await Self.colour(of: MemoryClip(fitted), x: 0.5, y: 0.04)
        #expect(top.r > 0 || top.g > 0 || top.b > 0, "the bars are filled, not empty: \(top)")
        #expect(top.r > 40 && top.g > 40, "a dimmed copy of the picture, not black: \(top)")
    }

    @Test func framingStaysWithinWhatItCanReach() {
        let source = CGSize(width: 1920, height: 1080), frame = StoryFramingTests.frame
        let low = StoryFraming.fitZoom(source: source, frame: frame)
        #expect(low < 0.4, "a wide picture shrinks a lot to fit a tall frame: \(low)")
        let wild = StoryFraming(zoom: 99, dx: 5, dy: -5).clamped(source: source, frame: frame)
        #expect(wild.zoom == StoryFraming.mostZoom)
        let reach = wild.spare(source: source, frame: frame)
        #expect(abs(wild.dx) <= reach.x + 0.0001 && abs(wild.dy) <= reach.y + 0.0001, "it can't be moved off the picture")
        let tiny = StoryFraming(zoom: 0.01, dx: 0.5, dy: 0.5).clamped(source: source, frame: frame)
        #expect(tiny.zoom == low)
        let room = tiny.spare(source: source, frame: frame)
        #expect(abs(tiny.dx) <= room.x + 0.0001 && abs(tiny.dy) <= room.y + 0.0001)
        #expect(StoryFraming.fitZoom(source: CGSize(width: 720, height: 1280), frame: frame) == 1, "a picture of the frame's own shape needs no fitting")
        #expect(StoryFraming(zoom: .nan, dx: .infinity, dy: .nan).clamped(source: source, frame: frame).zoom.isFinite)
    }
}
