import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import Vision
import UniformTypeIdentifiers

/// The looks a story photo or video can be given. Each one is a Core Image recipe, so the same code colours the
/// live preview, a still photo and every frame of an exported clip.
enum StoryFilter: String, CaseIterable, Identifiable, Codable {
    case none, mono, noir, chrome, fade, instant, vivid, warm, cool, faceBlur

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Original"
        case .mono: "Mono"
        case .noir: "Noir"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .vivid: "Vivid"
        case .warm: "Warm"
        case .cool: "Cool"
        case .faceBlur: "Face blur"
        }
    }

    /// The next look to the left (-1) or right (+1), wrapping around.
    func shifted(by d: Int) -> StoryFilter {
        let all = Self.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[((i + d) % all.count + all.count) % all.count]
    }

    func apply(_ image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .vivid:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.9])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.1])
        case .warm:
            return Self.tint(image, red: 1.12, green: 1.0, blue: 0.85)
        case .cool:
            return Self.tint(image, red: 0.88, green: 1.0, blue: 1.12)
        case .faceBlur:
            return Self.blurFaces(in: image)
        }
    }

    /// Blurs every face found in this frame, with a soft edge so it doesn't show as a box. Runs on each frame
    /// of the preview and of an exported clip, and entirely on this device.
    static func blurFaces(in image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return image }
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        guard (try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return image }
        var result = image
        for face in faces {
            let box = face.boundingBox
            let rect = CGRect(x: extent.minX + box.minX * extent.width, y: extent.minY + box.minY * extent.height,
                              width: box.width * extent.width, height: box.height * extent.height)
            // A little more than the box: hair, ears and chin.
            let radius = max(rect.width, rect.height) * 0.75
            let blurred = image.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(rect.width, rect.height) / 7,
                                                            kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY)])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(rect.width, rect.height) / 9])
                .cropped(to: extent)
            let mask = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: rect.midX, y: rect.midY),
                "inputRadius0": radius * 0.8, "inputRadius1": radius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])?.outputImage?.cropped(to: extent)
            guard let mask else { continue }
            result = blurred.applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: mask,
            ])
        }
        return result.cropped(to: extent)
    }

    private static func tint(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
        ])
    }

    /// One shared context: making them is expensive, and the GPU work queues up on it.
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// A photo (any image file data) with this look baked in, as a clean JPEG: no location or camera details
    /// survive. `none` still re-encodes, so what's sent never carries the original's metadata.
    /// With `text`, the story's words (drawn over the whole 9:16 frame) are laid over the finished picture; a photo
    /// of another shape is cropped to the frame first, which is what the story would show of it anyway.
    func bake(into data: Data, maxSide: CGFloat = 1600, text: CIImage? = nil) -> Data? {
        let options: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard var image = CIImage(data: data, options: options) else { return nil }
        let longest = max(image.extent.width, image.extent.height)
        if longest > maxSide {
            let s = maxSide / longest
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        if text != nil {
            let e = image.extent
            let frame = StoryVideo.size.width / StoryVideo.size.height
            let w = min(e.width, e.height * frame), h = w / frame
            image = image.cropped(to: CGRect(x: e.minX + (e.width - w) / 2, y: e.minY + (e.height - h) / 2, width: w, height: h))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let extent = image.extent
        var out = apply(image).cropped(to: extent)
        if let text {
            let s = extent.width / text.extent.width
            out = text.transformed(by: CGAffineTransform(scaleX: s, y: s)).composited(over: out).cropped(to: extent)
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return Self.context.jpegRepresentation(of: out, colorSpace: space,
                                               options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82])
    }
}

// MARK: - Video

enum StoryVideoError: Error, LocalizedError {
    case unreadable, tooLarge, failed(String)
    var errorDescription: String? {
        switch self {
        case .unreadable: "That video can't be read."
        case .tooLarge: "That video is too large to send, even compressed."
        case let .failed(why): "The video couldn't be prepared: \(why)"
        }
    }
}

// MARK: - Clips in memory

/// A video clip that only ever exists in memory: recorded, picked, edited, received or played, it is never written
/// to a file of ours. AVFoundation is given the bytes through a custom address, so it can play, read and export
/// them as if they were a file. Gone when the last reference goes, and nothing to wipe.
final class MemoryClip: Identifiable, @unchecked Sendable {
    let id = UUID()
    let bytes: Data

    init(_ bytes: Data) { self.bytes = bytes }

    /// A fresh asset over the bytes. It keeps its loader alive for as long as it lives.
    func makeAsset() -> AVURLAsset {
        let loader = ClipLoader(bytes)
        let asset = AVURLAsset(url: URL(string: "pulshade-clip://clip/\(id.uuidString).mp4")!)
        asset.resourceLoader.setDelegate(loader, queue: ClipLoader.queue)
        objc_setAssociatedObject(asset, &ClipLoader.key, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return asset
    }
}

/// Answers AVFoundation's requests for a clip's bytes from memory.
final class ClipLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    nonisolated(unsafe) static var key: UInt8 = 0
    static let queue = DispatchQueue(label: "pulshade.clip.loader", qos: .userInitiated)
    private let bytes: Data
    /// QuickTime files (the library's videos) and MP4 files are told apart by the first bytes.
    private let type: String

    init(_ bytes: Data) {
        self.bytes = bytes
        type = bytes.count > 12 && bytes[bytes.startIndex + 8..<bytes.startIndex + 12] == Data("qt  ".utf8)
            ? "com.apple.quicktime-movie" : "public.mpeg-4"
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        if let info = request.contentInformationRequest {
            info.contentType = type
            info.contentLength = Int64(bytes.count)
            info.isByteRangeAccessSupported = true
        }
        if let wanted = request.dataRequest {
            var offset = Int(wanted.requestedOffset)
            let end = wanted.requestsAllDataToEndOfResource ? bytes.count : min(bytes.count, offset + wanted.requestedLength)
            while offset < end {
                let next = min(end, offset + 1_000_000)
                wanted.respond(with: bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + next)))
                offset = next
            }
        }
        request.finishLoading()
        return true
    }
}

/// Collects a video writer's output as it is handed over in pieces: first the header, then the segments. Joined, they
/// are one fragmented MP4 file that any player opens.
final class SegmentSink: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var header = Data()
    private var segments: [Data] = []

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        lock.withLock {
            if segmentType == .initialization { header = segmentData } else { segments.append(segmentData) }
        }
    }

    var bytes: Data {
        lock.withLock { segments.reduce(into: header) { $0.append($1) } }
    }
}

/// Short, small story clips: at most 15 seconds, portrait 720p H.264, small enough for one encrypted message.
enum StoryVideo {
    static let maxSeconds: Double = 15
    /// What goes in a story, in bytes: four pieces of `StoryClipPieces.size`. Each piece is its own relay message
    /// (a clip is wrapped in base64 twice on its way, so a piece grows by about 80%, which keeps it inside the
    /// 2 MiB padding bucket and far under the relay's 4 MiB), and the receiver joins them. At 15 seconds this
    /// leaves about 1.9 Mbit/s, plenty for 1080p HEVC.
    static let maxBytes = 3_800_000
    /// Full HD, for clips shot at that size or more; smaller sources are kept at 720p rather than blown up.
    static let hdSize = CGSize(width: 1080, height: 1920)
    static let size = CGSize(width: 720, height: 1280)
    static let fps: Int32 = 30

    /// The look to bake into every frame, scaled to fill the story's 9:16 frame and centred.
    static func composition(for asset: AVAsset, filter: StoryFilter, size: CGSize = StoryVideo.size,
                            zoom: ZoomTrack = .none, text: CIImage? = nil) -> AVMutableVideoComposition {
        // The words are drawn once at full HD and fitted to this clip's size, then laid over every frame.
        let words = text.map { $0.transformed(by: CGAffineTransform(scaleX: size.width / $0.extent.width, y: size.width / $0.extent.width)) }
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let e = source.extent
            let scale = max(size.width / e.width, size.height / e.height)
            var image = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let w = e.width * scale, h = e.height * scale
            image = image.transformed(by: CGAffineTransform(translationX: (size.width - w) / 2, y: (size.height - h) / 2))
            let frame = CGRect(origin: .zero, size: size)
            // Digital zoom recorded where the camera couldn't zoom for real (the Mac).
            let z = zoom.value(at: request.compositionTime.seconds)
            if z > 1.001 {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                // Scale about the centre of the frame.
                image = image.transformed(by: CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: c.x * (1 - z), ty: c.y * (1 - z)))
            }
            var finished = filter.apply(image.cropped(to: frame)).cropped(to: frame)
            if let words { finished = words.composited(over: finished).cropped(to: frame) }
            request.finish(with: finished, context: StoryFilter.context)
        }
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: fps)
        return composition
    }

    /// How long the clip plays in a story, capped.
    static func duration(of clip: MemoryClip) async -> Double {
        let seconds = (try? await clip.makeAsset().load(.duration).seconds) ?? 0
        return seconds.isFinite ? min(max(seconds, 0), maxSeconds) : 0
    }

    /// Re-encodes a recording or picked clip with the look baked in: first 15 seconds, portrait 720p, bitrate
    /// chosen to fit `maxBytes`, no location or device metadata. Returns the file's bytes.
    static func export(from clip: MemoryClip, filter: StoryFilter, zoom: ZoomTrack = .none, maxBytes: Int = StoryVideo.maxBytes,
                       maxSeconds: Double = StoryVideo.maxSeconds, size: CGSize? = nil, text: CIImage? = nil) async throws -> Data {
        let asset = clip.makeAsset()
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let total = try? await asset.load(.duration), total.seconds.isFinite, total.seconds > 0 else { throw StoryVideoError.unreadable }
        let seconds = min(total.seconds, maxSeconds)
        // Full HD when the clip is at least that sharp; otherwise it isn't blown up.
        let upright = (try? await track.load(.naturalSize, .preferredTransform)).map { $0.0.applying($0.1) } ?? .zero
        let size = size ?? (max(abs(upright.width), abs(upright.height)) >= 1700 ? hdSize : StoryVideo.size)
        // Each retry spends less of the budget, in case the encoder overshoots on busy footage.
        for share in [0.85, 0.65, 0.45] {
            let data = try await transcode(asset, seconds: seconds, filter: filter, zoom: zoom, size: size, text: text,
                                           bitsPerSecond: Int(Double(maxBytes) * share * 8 / seconds) - 48_000)
            if data.count <= maxBytes { return data }
        }
        throw StoryVideoError.tooLarge
    }

    private static func transcode(_ asset: AVURLAsset, seconds: Double, filter: StoryFilter, zoom: ZoomTrack, size: CGSize,
                                  text: CIImage? = nil, bitsPerSecond: Int) async throws -> Data {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let readerVideo = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerVideo.videoComposition = composition(for: asset, filter: filter, size: size, zoom: zoom, text: text)
        guard reader.canAdd(readerVideo) else { throw StoryVideoError.unreadable }
        reader.add(readerVideo)

        // The finished clip is handed over in pieces and joined in memory: it never exists as a file.
        let sink = SegmentSink()
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = sink
        // HEVC gives the same picture in about half the bits; H.264 is the fallback where it can't be encoded.
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: max(bitsPerSecond, 150_000),
                AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2,
                AVVideoExpectedSourceFrameRateKey: Int(fps),
            ]
            if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            return [AVVideoCodecKey: codec, AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                    AVVideoCompressionPropertiesKey: compression]
        }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: writer.canApply(outputSettings: settings(.hevc), forMediaType: .video)
                                       ? settings(.hevc) : settings(.h264))
        video.expectsMediaDataInRealTime = false
        writer.add(video)

        var pumps: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(readerVideo, video)]
        if let track = try await asset.loadTracks(withMediaType: .audio).first {
            let readerAudio = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ])
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ])
            audio.expectsMediaDataInRealTime = false
            if reader.canAdd(readerAudio), writer.canAdd(audio) {
                reader.add(readerAudio)
                writer.add(audio)
                pumps.append((readerAudio, audio))
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            throw StoryVideoError.failed((reader.error ?? writer.error)?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)
        await withTaskGroup(of: Void.self) { group in
            for (output, input) in pumps {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "pulshade.story.export.\(input.mediaType.rawValue)")
                        nonisolated(unsafe) let output = output
                        nonisolated(unsafe) let input = input
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let buffer = output.copyNextSampleBuffer() {
                                    if !input.append(buffer) { input.markAsFinished(); done.resume(); return }
                                } else {
                                    input.markAsFinished()
                                    done.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        if reader.status == .failed { writer.cancelWriting(); throw StoryVideoError.failed(reader.error?.localizedDescription ?? "read") }
        await writer.finishWriting()
        guard writer.status == .completed else { throw StoryVideoError.failed(writer.error?.localizedDescription ?? "write") }
        return sink.bytes
    }

    /// A still from the first moment of a clip, for posters and thumbnails.
    static func poster(of clip: MemoryClip) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: clip.makeAsset())
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        return try? await generator.image(at: .zero).image
    }
}

// MARK: - Sending a clip in pieces

/// A clip is cut into pieces that each fit one relay message, and sent as separate messages.
enum StoryClipPieces {
    static let size = 1_000_000
    static let maxPieces = 5

    static func split(_ clip: Data) -> [Data] {
        stride(from: 0, to: clip.count, by: size).map { clip.subdata(in: $0..<min($0 + size, clip.count)) }
    }
}

// MARK: - Zoom

enum ZoomMath {
    /// How far a finger dragged while holding the shutter changes the zoom: every 140 points is a doubling,
    /// up to zooms in, down zooms out.
    static let pointsPerDoubling: CGFloat = 140
    /// The most a story camera zooms in, even where the camera could go further: past this it's all noise.
    static let ceiling: CGFloat = 10

    /// `lo` is below 1 on an iPhone with a wide lens, where zooming out goes to 0.5×.
    static func clamp(_ zoom: CGFloat, min lo: CGFloat = 1, max hi: CGFloat) -> CGFloat {
        let floor = lo.isFinite ? min(lo, 1) : 1
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, floor), max(1, min(hi, ceiling)))
    }

    static func zoom(start: CGFloat, drag dy: CGFloat, min lo: CGFloat = 1, max hi: CGFloat) -> CGFloat {
        clamp(start * pow(2, -dy / pointsPerDoubling), min: lo, max: hi)
    }

    static func label(_ zoom: CGFloat) -> String { String(format: "%.1f×", Double(zoom)) }
}

/// Clips used to be written to the temporary folder. They stay in memory now (see `MemoryClip`); this overwrites and
/// deletes whatever an older version, a crash or a system file hand-over left there. Runs when Pulshade starts.
enum TempFiles {
    /// Whether a file in the temporary folder is one Pulshade made: only these exact names, since the Mac's
    /// temporary folder is shared with other apps.
    static func isOurs(_ name: String) -> Bool {
        name.range(of: "^story-((rec|pick|play)-)?[0-9A-Fa-f-]{36}\\.(mov|mp4)$", options: .regularExpression) != nil
    }

    static func sweep() {
        let files = FileManager.default
        let stale = ((try? files.contentsOfDirectory(at: files.temporaryDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { isOurs($0.lastPathComponent) }
        guard !stale.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in stale { Vault.scrub(item: url) }
        }
    }
}

/// How the shutter tells a tap (photo) from a hold (video).
enum ShutterTiming {
    /// Held at least this long, it's a video.
    static let holdAfter: TimeInterval = 0.3
    /// A press that moves further than this is a drag, not a tap.
    static let tapTravel: CGFloat = 12

    static func isHold(after seconds: TimeInterval) -> Bool { seconds >= holdAfter }
    static func isTap(duration: TimeInterval, travel: CGFloat) -> Bool { duration < holdAfter && travel < tapTravel }
}

/// The zoom over the length of a clip, for cameras that can't zoom for real: it's applied to the frames when the
/// clip is prepared. Empty means no zoom.
struct ZoomTrack: Equatable {
    struct Key: Equatable { var time: Double; var zoom: CGFloat }
    private(set) var keys: [Key] = []

    static let none = ZoomTrack()

    mutating func add(at time: Double, zoom: CGFloat) {
        if let last = keys.last, time <= last.time { keys[keys.count - 1].zoom = zoom; return }
        keys.append(Key(time: time, zoom: zoom))
    }

    func value(at time: Double) -> CGFloat {
        guard let first = keys.first, let last = keys.last else { return 1 }
        if time <= first.time { return first.zoom }
        if time >= last.time { return last.zoom }
        for (a, b) in zip(keys, keys.dropFirst()) where time <= b.time {
            let t = CGFloat((time - a.time) / max(b.time - a.time, 0.0001))
            return a.zoom + (b.zoom - a.zoom) * t
        }
        return last.zoom
    }
}
