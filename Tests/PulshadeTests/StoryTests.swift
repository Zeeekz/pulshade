import Testing
import Foundation
@testable import Pulshade

struct StoryTests {
    @Test func audiencesIncludeTheRightPeople() {
        #expect(StoryAudience.everyone.includes("a"))
        #expect(StoryAudience.only(["a"]).includes("a") && !StoryAudience.only(["a"]).includes("b"))
        #expect(!StoryAudience.except(["a"]).includes("a") && StoryAudience.except(["a"]).includes("b"))
    }

    @Test func storiesSavedBeforeLifetimesLastADay() throws {
        let old = #"{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","author":"me","style":{"text":{"_0":"hi","palette":0}},"date":0,"seen":false}"#
        let story = try JSONDecoder().decode(Story.self, from: Data(old.utf8))
        #expect(story.lifetime == nil && story.audience == nil && story.shownTo == .everyone)
        #expect(story.expires == story.date.addingTimeInterval(86_400))
    }

    @Test func aStoryFromAnOlderAppStillDecodes() throws {
        let payload = Payload.story(id: UUID(), style: .text("hi", palette: 0), date: Date())
        let decoded = try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(payload))
        guard case let .story(_, _, _, lasts) = decoded else { Issue.record("not a story"); return }
        #expect(lasts == nil)
    }
}

// MARK: - Filters and video

import AVFoundation
import CoreImage
import ImageIO

struct StoryMediaTests {
    /// A colourful gradient photo, as JPEG.
    static func photo() -> Data {
        let (w, h) = (240, 400)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1), CGColor(red: 0.2, green: 0.8, blue: 0.3, alpha: 1),
                      CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: w, y: h), options: [])
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    /// Average RGB bytes of an image, on a coarse grid.
    static func pixels(_ data: Data) -> [Double] {
        let image = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }!
        return pixels(image)
    }

    static func pixels(_ image: CGImage) -> [Double] {
        let (w, h) = (24, 40)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<(w * h)).flatMap { i in (0..<3).map { Double(p[i * 4 + $0]) } }
    }

    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
    }

    /// Writes a moving test clip (a sweeping colour field) of the given length and shape.
    static func clipFile(seconds: Double, width: Int = 640, height: Int = 360, fps: Int = 15, sound: Bool = false) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for n in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            let b = buffer!
            CVPixelBufferLockBaseAddress(b, [])
            let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(b)
            // One row, copied down: the colour sweeps across and moves from frame to frame.
            for x in 0..<width {
                let o = x * 4
                base[o] = UInt8((x + n * 7) % 256)
                base[o + 1] = UInt8((x / 2 + n * 3) % 256)
                base[o + 2] = UInt8(255 - (x + n * 5) % 256)
                base[o + 3] = 255
            }
            for y in 1..<height { memcpy(base + y * stride, base, width * 4) }
            CVPixelBufferUnlockBaseAddress(b, [])
            adaptor.append(b, withPresentationTime: CMTime(value: Int64(n), timescale: Int32(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StoryVideoError.unreadable }
        return url
    }

    /// The same clip, held in memory as the app does; the file the test writer needs is gone again at once.
    static func clip(seconds: Double, width: Int = 640, height: Int = 360, fps: Int = 15, sound: Bool = false) async throws -> MemoryClip {
        let url = try await clipFile(seconds: seconds, width: width, height: height, fps: fps, sound: sound)
        defer { try? FileManager.default.removeItem(at: url) }
        return MemoryClip(try Data(contentsOf: url))
    }

    /// Camera-like frames, one picture at a time, with times that start well into the clock as a camera's do.
    static func cameraFrame(_ n: Int, start: CMTime, width: Int, height: Int, fps: Int32) -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &buffer)
        let b = buffer!
        CVPixelBufferLockBaseAddress(b, [])
        let base = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(b)
        for x in 0..<width {
            base[x * 4] = UInt8((x + n * 7) % 256); base[x * 4 + 1] = UInt8((x / 2 + n * 3) % 256)
            base[x * 4 + 2] = UInt8(255 - (x + n * 5) % 256); base[x * 4 + 3] = 255
        }
        for y in 1..<height { memcpy(base + y * stride, base, width * 4) }
        CVPixelBufferUnlockBaseAddress(b, [])
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: b, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: fps),
                                        presentationTimeStamp: start + CMTime(value: Int64(n), timescale: fps), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: b, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out!
    }

    @Test func everyLookChangesThePhotoAndOriginalDoesNot() throws {
        let photo = Self.photo()
        let plain = try #require(StoryFilter.none.bake(into: photo))
        let reference = Self.pixels(photo)
        #expect(Self.difference(Self.pixels(plain), reference) < 3)
        // Face blur only changes a picture with a face in it, which this plain test photo hasn't.
        for look in StoryFilter.allCases where look != .none && look != .faceBlur {
            let out = try #require(look.bake(into: photo))
            #expect(Self.difference(Self.pixels(out), Self.pixels(plain)) > 3, "\(look.label) should change the picture")
        }
    }

    @Test func monoAndNoirDropTheColour() throws {
        for look in [StoryFilter.mono, .noir] {
            let p = Self.pixels(try #require(look.bake(into: Self.photo())))
            let spread = stride(from: 0, to: p.count, by: 3).map { max(abs(p[$0] - p[$0 + 1]), abs(p[$0 + 1] - p[$0 + 2])) }.max() ?? 0
            #expect(spread < 10)
        }
    }

    @Test func looksCycleWithNoneFirst() {
        #expect(StoryFilter.allCases.first == StoryFilter.none)
        #expect(StoryFilter.allCases.count >= 7 && StoryFilter.allCases.count <= 10)
        #expect(StoryFilter.none.shifted(by: -1) == StoryFilter.allCases.last)
        #expect(StoryFilter.allCases.last?.shifted(by: 1) == StoryFilter.none)
    }

    @Test func aLongClipIsCutToFifteenSecondsPortraitAndSmall() async throws {
        let source = try await Self.clip(seconds: 20)
        let data = try await StoryVideo.export(from: source, filter: .none)
        #expect(data.count <= StoryVideo.maxBytes)
        let asset = MemoryClip(data).makeAsset()
        let seconds = try await asset.load(.duration).seconds
        #expect(seconds > 14 && seconds <= 15.2)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 720 && Int(size.height) == 1280, "a small source stays 720p")
        #expect(try await asset.load(.commonMetadata).isEmpty)
    }

    @Test func aFullHDClipIsKeptFullHDAndSmall() async throws {
        let source = try await Self.clip(seconds: 4, width: 1920, height: 1080, fps: 30)
        let data = try await StoryVideo.export(from: source, filter: .none)
        #expect(data.count <= StoryVideo.maxBytes)
        let asset = MemoryClip(data).makeAsset()
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 1080 && Int(size.height) == 1920)
        let fps = try await track.load(.nominalFrameRate)
        #expect(fps >= 29 && fps <= 31)
        let codec = try await track.load(.formatDescriptions).first.map { CMFormatDescriptionGetMediaSubType($0) }
        #expect(codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_H264)
        // It is a tall clip that fits the picture: the duration is kept.
        #expect(try await asset.load(.duration).seconds > 3.5)
    }

    @Test func zoomRecordedOnTheMacIsBakedIntoTheClip() async throws {
        let source = try await Self.clip(seconds: 2)
        func frame(_ zoom: ZoomTrack) async throws -> [Double] {
            let data = try await StoryVideo.export(from: source, filter: .none, zoom: zoom)
            return Self.pixels(try #require(await StoryVideo.poster(of: MemoryClip(data))))
        }
        var zoomed = ZoomTrack.none
        zoomed.add(at: 0, zoom: 3)
        let plain = try await frame(.none), closer = try await frame(zoomed)
        #expect(Self.difference(plain, closer) > 6)
    }

    @Test func aLookIsBakedIntoTheVideoFrames() async throws {
        let source = try await Self.clip(seconds: 2)
        func frame(_ look: StoryFilter) async throws -> [Double] {
            let data = try await StoryVideo.export(from: source, filter: look)
            let still = try #require(await StoryVideo.poster(of: MemoryClip(data)))
            return Self.pixels(still)
        }
        let plain = try await frame(.none), mono = try await frame(.mono)
        #expect(Self.difference(plain, mono) > 8)
        let grey = stride(from: 0, to: mono.count, by: 3).map { max(abs(mono[$0] - mono[$0 + 1]), abs(mono[$0 + 1] - mono[$0 + 2])) }.max() ?? 0
        #expect(grey < 14)
    }

    @Test func aTightBudgetStillFitsOrFailsCleanly() async throws {
        let source = try await Self.clip(seconds: 3)
        let data = try await StoryVideo.export(from: source, filter: .none, maxBytes: 400_000)
        #expect(data.count <= 400_000)
    }

    @Test func aRecordedClipIsBuiltInMemoryAndPlays() async throws {
        let start = CMTime(seconds: 5000, preferredTimescale: 600)
        let writer = try #require(ClipWriter(size: CGSize(width: 640, height: 360), audio: nil, start: start))
        for n in 0..<90 {
            while !writer.ready { try await Task.sleep(for: .milliseconds(2)) }
            writer.append(picture: Self.cameraFrame(n, start: start, width: 640, height: 360, fps: 30))
        }
        let clip: MemoryClip = try #require(await withCheckedContinuation { done in writer.finish { done.resume(returning: $0) } })
        #expect(!clip.bytes.isEmpty)
        let asset = clip.makeAsset()
        #expect(try await asset.load(.isPlayable))
        let seconds = try await asset.load(.duration).seconds
        #expect(seconds > 2.8 && seconds < 3.2)
        // It can be read frame by frame, which is what editing and exporting do, with no file behind it.
        let exported = try await StoryVideo.export(from: clip, filter: .none)
        #expect(!exported.isEmpty && exported.count <= StoryVideo.maxBytes)
        #expect(try await MemoryClip(exported).makeAsset().load(.duration).seconds > 2.8)
    }

    @Test func aPauseInTheFramesIsHeldNotLost() async throws {
        // The camera was flipped: no frames for two thirds of a second, then they carry on.
        let start = CMTime(seconds: 100, preferredTimescale: 600)
        let writer = try #require(ClipWriter(size: CGSize(width: 640, height: 360), audio: nil, start: start))
        for n in Array(0..<30) + Array(50..<80) {
            while !writer.ready { try await Task.sleep(for: .milliseconds(2)) }
            writer.append(picture: Self.cameraFrame(n, start: start, width: 640, height: 360, fps: 30))
        }
        let clip: MemoryClip = try #require(await withCheckedContinuation { done in writer.finish { done.resume(returning: $0) } })
        #expect(try await clip.makeAsset().load(.duration).seconds > 2.5)
    }

    @Test func aVideoStoryRoundTripsOnTheWire() throws {
        let clip = Data((0..<5000).map { UInt8($0 % 251) })
        let id = UUID()
        let payload = Payload.story(id: id, style: .video(clip, caption: "hey"), date: Date(timeIntervalSince1970: 100), lasts: 3600)
        let decoded = try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(payload))
        guard case let .story(gotID, style, _, lasts) = decoded else { Issue.record("not a story"); return }
        #expect(gotID == id && style == .video(clip, caption: "hey") && lasts == 3600)
    }

    @Test func aClipTravelsInPiecesThatEachFitOneMessage() throws {
        let clip = Data((0..<StoryVideo.maxBytes).map { UInt8($0 % 253) })
        let pieces = StoryClipPieces.split(clip)
        #expect(pieces.count <= StoryClipPieces.maxPieces)
        #expect(pieces.allSatisfy { $0.count <= StoryClipPieces.size })
        #expect(pieces.reduce(Data(), +) == clip)
        // A piece is base64 inside JSON, then base64 again inside the sealed message, and padded to a bucket.
        let json = try JSONEncoder.pulshade.encode(Payload.storyPart(id: UUID(), index: 0, of: 4, bytes: pieces[0]))
        #expect(json.count * 4 / 3 + 4096 < 2_097_152)
        let decoded = try JSONDecoder.pulshade.decode(Payload.self, from: json)
        guard case let .storyPart(_, index, of, bytes) = decoded else { Issue.record("not a part"); return }
        #expect(index == 0 && of == 4 && bytes == pieces[0])
    }

    @Test func zoomStaysWithinWhatTheCameraCanDo() {
        #expect(ZoomMath.clamp(0.4, max: 5) == 1)
        #expect(ZoomMath.clamp(3, max: 5) == 3)
        #expect(ZoomMath.clamp(9, max: 5) == 5)
        #expect(ZoomMath.clamp(50, max: 120) == ZoomMath.ceiling)
        #expect(ZoomMath.clamp(.nan, max: 5) == 1)
        #expect(ZoomMath.clamp(2, max: 0.5) == 1)
    }

    @Test func anUltraWideLensLetsZoomGoBelowOne() {
        #expect(ZoomMath.clamp(0.3, min: 0.5, max: 5) == 0.5)
        #expect(ZoomMath.clamp(0.7, min: 0.5, max: 5) == 0.7)
        #expect(ZoomMath.clamp(0.7, max: 5) == 1, "no wide lens, no zooming out")
        #expect(ZoomMath.zoom(start: 1, drag: 300, min: 0.5, max: 10) == 0.5)
    }

    @Test func aTapOnThePictureFindsThePlaceOnTheSensor() {
        let size = CGSize(width: 900, height: 1600)  // exactly the camera's 9:16
        let middle = Camera.devicePoint(for: CGPoint(x: 450, y: 800), in: size, mirrored: false)
        #expect(abs(middle.x - 0.5) < 0.001 && abs(middle.y - 0.5) < 0.001)
        // The sensor is turned a quarter: the top of the picture is the right edge of the sensor.
        let topLeft = Camera.devicePoint(for: .zero, in: size, mirrored: false)
        #expect(topLeft == CGPoint(x: 0, y: 1))
        let selfie = Camera.devicePoint(for: .zero, in: size, mirrored: true)
        #expect(selfie == CGPoint(x: 0, y: 0))
        // A taller screen crops the sides off the frame, so the screen's edge is inside the frame.
        let tall = Camera.devicePoint(for: .zero, in: CGSize(width: 400, height: 1000), mirrored: false)
        #expect(tall.y < 1 && tall.y > 0.5)
    }

    @Test func draggingUpZoomsInAndDownZoomsOut() {
        #expect(ZoomMath.zoom(start: 1, drag: -ZoomMath.pointsPerDoubling, max: 10) == 2)
        #expect(ZoomMath.zoom(start: 2, drag: ZoomMath.pointsPerDoubling, max: 10) == 1)
        #expect(ZoomMath.zoom(start: 1, drag: 300, max: 10) == 1, "never out past the widest")
        #expect(ZoomMath.zoom(start: 1, drag: -2000, max: 4) == 4, "never in past the device's limit")
        #expect(ZoomMath.zoom(start: 3, drag: 0, max: 10) == 3)
        #expect(ZoomMath.label(2.34) == "2.3×")
    }

    @Test func aPressBecomesAClipOnlyWhenItLasts() {
        #expect(ShutterTiming.isTap(duration: 0.1, travel: 2))
        #expect(!ShutterTiming.isTap(duration: 0.1, travel: 30), "a drag isn't a tap")
        #expect(!ShutterTiming.isTap(duration: ShutterTiming.holdAfter + 0.01, travel: 0), "a hold isn't a tap")
        #expect(!ShutterTiming.isHold(after: 0.1))
        #expect(ShutterTiming.isHold(after: ShutterTiming.holdAfter))
    }

    @Test func zoomOverTimeIsInterpolated() {
        var track = ZoomTrack.none
        #expect(track.value(at: 3) == 1)
        track.add(at: 0, zoom: 1)
        track.add(at: 2, zoom: 3)
        #expect(track.value(at: -1) == 1 && track.value(at: 1) == 2 && track.value(at: 5) == 3)
    }

    @Test func photoAndTextStoriesFromBeforeVideoStillDecode() throws {
        let photo = #"{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","author":"me","style":{"image":{"_0":"AQID","caption":"old"}},"date":0,"seen":true}"#
        let story = try JSONDecoder().decode(Story.self, from: Data(photo.utf8))
        #expect(story.style == .image(Data([1, 2, 3]), caption: "old"))
        let text = try JSONDecoder.pulshade.decode(StoryStyle.self, from: JSONEncoder.pulshade.encode(StoryStyle.text("hi", palette: 2)))
        #expect(text == .text("hi", palette: 2))
    }
}
