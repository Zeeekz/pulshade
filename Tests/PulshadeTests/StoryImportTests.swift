import Testing
import Foundation
import AVFoundation
import CoreImage
@testable import Pulshade

/// Clips from the camera roll differ from ones the app records: they can be stored sideways with a rotation
/// instruction, and they carry sound. These are the shapes the story editor has to cope with.
struct StoryImportTests {
    /// A 2-second clip written as landscape frames with a 90° rotation, as the library keeps a portrait recording:
    /// the left half of the encoded pictures is red, the right half blue.
    static func rotatedClip() async throws -> MemoryClip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rot-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h, fps) = (640, 360, 15)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
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
            for y in 0..<h {
                for x in 0..<w {
                    let red = x < w / 2
                    let o = y * stride + x * 4
                    base[o] = red ? 230 : 20
                    base[o + 1] = 20
                    base[o + 2] = red ? 20 : 230
                    base[o + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StoryVideoError.unreadable }
        return MemoryClip(try Data(contentsOf: url))
    }

    private static func pixels(_ image: CGImage?) -> [Double] {
        let image = image!
        let (w, h) = (24, 40)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(w * h)).flatMap { i in (0..<3).map { Double(p[i * 4 + $0]) } }
    }

    /// The source is held sideways. The story is always portrait, so the exported picture must be turned upright
    /// first: the red and blue halves then sit above and below one another, not left and right.
    @Test func aRotatedLibraryClipIsExportedUpright() async throws {
        let source = try await Self.rotatedClip()
        let exported = try await StoryVideo.export(from: source, filter: .none)
        let poster = await StoryVideo.poster(of: MemoryClip(exported))
        let p = Self.pixels(poster)
        func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * 24 + x) * 3
            return (p[i], p[i + 1], p[i + 2])
        }
        let top = rgb(12, 8), bottom = rgb(12, 32)
        let left = rgb(4, 20), right = rgb(20, 20)
        #expect(abs(top.r - bottom.r) > 60 || abs(top.b - bottom.b) > 60,
                "the picture was not turned upright: top \(top) bottom \(bottom)")
        #expect(abs(left.r - right.r) < 30 && abs(left.b - right.b) < 30,
                "the picture is still split left and right: left \(left) right \(right)")
    }

    /// A real library-style clip with a picture and sound track. macOS ships one; when it isn't there, there is
    /// nothing to read and the test has nothing to say.
    @Test func aLibraryClipWithSoundExports() async throws {
        let path = "/System/Library/PrivateFrameworks/SiriSetup.framework/Versions/A/Resources/Speak to Siri - 480 x 250 (Dark).mp4"
        guard FileManager.default.fileExists(atPath: path) else { return }
        let source = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let exported = try await StoryVideo.export(from: MemoryClip(source), filter: .none)
        let asset = MemoryClip(exported).makeAsset()
        #expect(try await asset.load(.duration).seconds > 0.5, "the clip is cut and exported")
        #expect(!(try await asset.loadTracks(withMediaType: .audio)).isEmpty, "the sound survives the export")
    }
}
