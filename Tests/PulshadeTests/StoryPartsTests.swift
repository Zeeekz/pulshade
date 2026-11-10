import Testing
import Foundation
import AVFoundation
@testable import Pulshade

/// A video longer than one story is cut into parts of 15 seconds, like Instagram does.
struct StoryPartsTests {
    @Test func aVideoBecomesOnePartPerFifteenSeconds() {
        #expect(StoryVideo.parts(of: 3) == 1)
        #expect(StoryVideo.parts(of: 15) == 1)
        #expect(StoryVideo.parts(of: 15.5) == 2)
        #expect(StoryVideo.parts(of: 15.2) == 1, "a sliver left over is not a story of its own")
        #expect(StoryVideo.parts(of: 61) == 5)
        #expect(StoryVideo.parts(of: 300) == 20)
        #expect(StoryVideo.parts(of: 3_000) == 20, "past five minutes the rest is left out")
        #expect(StoryVideo.parts(of: .nan) == 1)
    }

    @Test func manyPartsGetSmallerPartsSoTheTotalStaysBounded() {
        #expect(StoryVideo.budget(parts: 1) == StoryVideo.maxBytes)
        #expect(StoryVideo.budget(parts: 20) * 20 <= StoryVideo.totalBudget)
        #expect(StoryVideo.budget(parts: 20) >= 1_200_000)
        #expect(StoryVideo.budget(parts: 4) >= StoryVideo.budget(parts: 20))
    }

    /// A clip whose red grows by 6 every second, `seconds` long.
    static func rampClip(seconds: Int) async throws -> MemoryClip {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ramp-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let (w, h, fps) = (180, 320, 10)
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
        for n in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &buffer)
            let b = buffer!
            CVPixelBufferLockBaseAddress(b, [])
            let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(b)
            let red = UInt8(min(255, (n / fps) * 6))
            for y in 0..<h { for x in 0..<w {
                let o = y * stride + x * 4
                base[o] = 20; base[o + 1] = 20; base[o + 2] = red; base[o + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StoryVideoError.unreadable }
        return MemoryClip(try Data(contentsOf: url))
    }

    private static func red(of clip: MemoryClip) async -> Double {
        guard let image = await StoryVideo.poster(of: clip) else { return -1 }
        let ctx = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        return Double(ctx.data!.assumingMemoryBound(to: UInt8.self)[0])
    }

    @Test func laterPartsStartWhereTheEarlierOnesStop() async throws {
        let source = try await Self.rampClip(seconds: 40)
        let first = try await StoryVideo.export(from: source, filter: .none)
        let second = try await StoryVideo.export(from: source, filter: .none, from: 15)
        let third = try await StoryVideo.export(from: source, filter: .none, from: 30)
        let lengths = try await [first, second, third].asyncMap { try await MemoryClip($0).makeAsset().load(.duration).seconds }
        #expect(abs(lengths[0] - 15) < 0.6 && abs(lengths[1] - 15) < 0.6, "full parts are 15 seconds: \(lengths)")
        #expect(abs(lengths[2] - 10) < 0.6, "the last part is what is left: \(lengths)")
        let reds = await [first, second, third].asyncMap { await Self.red(of: MemoryClip($0)) }
        #expect(abs(reds[0] - 0) < 25, "part 1 starts at the start: \(reds)")
        #expect(abs(reds[1] - 90) < 25, "part 2 starts at 15 s: \(reds)")
        #expect(abs(reds[2] - 180) < 25, "part 3 starts at 30 s: \(reds)")
    }

    @Test func trimmingKeepsAPartBetweenASecondAndFiveMinutes() {
        let duration = 400.0
        let whole = StoryTrim.whole(duration)
        #expect(whole.start == 0 && whole.end == StoryVideo.longestSeconds)
        #expect(StoryTrim.whole(.nan).length == 0)
        let later = whole.movingStart(to: 299.9, duration: duration)
        #expect(abs(later.length - StoryTrim.shortest) < 0.0001, "the start stops a second short of the end")
        let pulled = StoryTrim(start: 150, end: 160).movingEnd(to: 900, duration: duration)
        #expect(pulled.end == duration, "the end stops at the clip's end")
        let far = StoryTrim(start: 0, end: 60).movingEnd(to: 380, duration: duration)
        #expect(far.length == StoryVideo.longestSeconds, "and at five minutes")
        let slid = StoryTrim(start: 10, end: 40).sliding(by: 1000, duration: duration)
        #expect(slid.end == duration && slid.length == 30, "sliding keeps the length: \(slid)")
        #expect(StoryTrim(start: 10, end: 40).sliding(by: -1000, duration: duration).start == 0)
        let tiny = StoryTrim(start: 0, end: 0.6).movingEnd(to: 0.1, duration: 0.6)
        #expect(tiny.end == 0.6, "a clip shorter than a second is kept whole")
    }

    @Test func aTrimmedPartIsCutIntoStoriesFromItsStart() {
        let parts = StoryTrim(start: 3, end: 34).parts
        #expect(parts.count == 3)
        #expect(parts.map(\.start) == [3, 18, 33])
        #expect(parts.map(\.seconds) == [15, 15, 1])
        #expect(StoryTrim(start: 2, end: 17.1).parts.map(\.seconds) == [15], "a sliver at the end is dropped")
    }

    @Test func aTrimmedClipExportsOnlyTheKeptPart() async throws {
        let source = try await Self.rampClip(seconds: 20)
        let piece = try #require(StoryTrim(start: 10, end: 14).parts.first)
        let data = try await StoryVideo.export(from: source, filter: .none, maxSeconds: piece.seconds, from: piece.start)
        let length = try await MemoryClip(data).makeAsset().load(.duration).seconds
        #expect(abs(length - 4) < 0.6, "four seconds kept: \(length)")
        let red = await Self.red(of: MemoryClip(data))
        #expect(abs(red - 60) < 25, "starting ten seconds in: \(red)")
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await transform(e)) }
        return out
    }
}
