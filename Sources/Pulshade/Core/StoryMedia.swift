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
    case unreadable, tooLarge, timedOut, failed(String)
    var errorDescription: String? {
        switch self {
        case .timedOut: "Preparing that video took too long. Try a shorter one, or try again."
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
    /// Where the bytes are handed over, apart from the queue that takes the requests.
    static let sender = DispatchQueue(label: "pulshade.clip.sender", qos: .userInitiated, attributes: .concurrent)
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
        guard let wanted = request.dataRequest else { request.finishLoading(); return true }
        // AVFoundation often asks for "everything to the end" and then reads only the start it needs, cancelling the
        // rest. Answering that in one go on this queue held everything up (and copied a whole big video) before it
        // could say it had enough. So the bytes go out in pieces from another queue, stopping when it cancels.
        let start = Int(wanted.requestedOffset)
        let end = wanted.requestsAllDataToEndOfResource ? bytes.count : min(bytes.count, start + wanted.requestedLength)
        let bytes = bytes
        Self.sender.async {
            var offset = start
            while offset < end {
                if request.isCancelled { return }
                let next = min(end, offset + 512_000)
                wanted.respond(with: bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + next)))
                offset = next
            }
            if !request.isCancelled { request.finishLoading() }
        }
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
/// Where a picture or video sits in the story's frame. `zoom` is relative to the size that just fills the frame, so
/// 1 fills it (and cuts off what spills over), and less than that shrinks it until it all shows (with a blurred copy
/// of itself behind the rest). The move is in fractions of the frame's width and height, down and to the right.
struct StoryFraming: Equatable, Sendable {
    var zoom: CGFloat = 1
    var dx: CGFloat = 0
    var dy: CGFloat = 0

    static let fill = StoryFraming()
    static let mostZoom: CGFloat = 4

    /// The size where the whole picture shows: the zoom (against filling) at which the longer side just fits.
    static func fitZoom(source: CGSize, frame: CGSize) -> CGFloat {
        guard source.width > 0, source.height > 0 else { return 1 }
        let fill = max(frame.width / source.width, frame.height / source.height)
        let fit = min(frame.width / source.width, frame.height / source.height)
        return min(1, fit / fill)
    }

    static func fit(source: CGSize, frame: CGSize) -> StoryFraming {
        StoryFraming(zoom: fitZoom(source: source, frame: frame))
    }

    /// How far it may still move along each side, in fractions of the frame. Shrunk, it stays inside; grown, it stays
    /// covering.
    func spare(source: CGSize, frame: CGSize) -> (x: CGFloat, y: CGFloat) {
        guard source.width > 0, source.height > 0 else { return (0, 0) }
        let scale = max(frame.width / source.width, frame.height / source.height) * zoom
        return (abs(source.width * scale - frame.width) / 2 / frame.width,
                abs(source.height * scale - frame.height) / 2 / frame.height)
    }

    func clamped(source: CGSize, frame: CGSize) -> StoryFraming {
        let low = Self.fitZoom(source: source, frame: frame)
        var out = self
        out.zoom = min(max(zoom.isFinite ? zoom : 1, low), Self.mostZoom)
        let room = out.spare(source: source, frame: frame)
        out.dx = min(max(dx.isFinite ? dx : 0, -room.x), room.x)
        out.dy = min(max(dy.isFinite ? dy : 0, -room.y), room.y)
        return out
    }
}

/// The framing the picture is read through, changed from the editor while the preview plays and read by the frame
/// renderer on its own thread.
final class FramingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: StoryFraming
    init(_ value: StoryFraming = .fill) { current = value }
    var value: StoryFraming {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// The part of a picked clip that becomes stories: from `start` to `end`, in seconds. It is at least a second long
/// (or the whole clip, if that is shorter) and at most five minutes, which go up as stories of 15 seconds each.
struct StoryTrim: Equatable, Sendable {
    var start: Double = 0
    var end: Double = 0
    static let shortest: Double = 1

    var length: Double { max(end - start, 0) }

    /// All of a clip, up to five minutes.
    static func whole(_ duration: Double) -> StoryTrim {
        StoryTrim(start: 0, end: min(max(duration.isFinite ? duration : 0, 0), StoryVideo.longestSeconds))
    }

    private static func shortest(in duration: Double) -> Double { min(shortest, max(duration, 0)) }

    /// With the start moved to `time`, kept short of the end and within five minutes of it.
    func movingStart(to time: Double, duration: Double) -> StoryTrim {
        let low = max(0, end - StoryVideo.longestSeconds), high = end - Self.shortest(in: duration)
        return StoryTrim(start: min(max(time.isFinite ? time : start, low), max(high, low)), end: end)
    }

    /// With the end moved to `time`, kept past the start, within the clip and within five minutes of the start.
    func movingEnd(to time: Double, duration: Double) -> StoryTrim {
        let low = start + Self.shortest(in: duration), high = min(duration, start + StoryVideo.longestSeconds)
        return StoryTrim(start: start, end: min(max(time.isFinite ? time : end, min(low, high)), high))
    }

    /// Moved along whole, keeping its length, within the clip.
    func sliding(by seconds: Double, duration: Double) -> StoryTrim {
        let shift = min(max(seconds.isFinite ? seconds : 0, -start), max(duration - end, 0))
        return StoryTrim(start: start + shift, end: end + shift)
    }

    /// Where each story cut from it starts, and how long it is.
    var parts: [(start: Double, seconds: Double)] {
        (0..<StoryVideo.parts(of: length)).map { i in
            let from = start + Double(i) * StoryVideo.maxSeconds
            return (from, min(StoryVideo.maxSeconds, end - from))
        }
    }
}

enum StoryVideo {
    static let maxSeconds: Double = 15
    /// The longest video that can be turned into stories: it is cut into parts of `maxSeconds`, like Instagram does.
    static let longestSeconds: Double = 300
    /// What the parts of one video may add up to, since every contact gets every part: more parts, smaller parts.
    static let totalBudget = 24_000_000

    /// How many stories a video of this length becomes.
    static func parts(of seconds: Double) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        // A sliver left over (a quarter of a second or less) is dropped rather than posted as a story of its own.
        return max(1, Int(((min(seconds, longestSeconds) - 0.25) / maxSeconds).rounded(.up)))
    }

    /// The size each part may be, when a video comes in `parts`.
    static func budget(parts: Int) -> Int { min(maxBytes, max(1_200_000, totalBudget / max(parts, 1))) }

    /// The whole length of a clip, up to `longestSeconds`.
    static func fullDuration(of clip: MemoryClip) async -> Double {
        let seconds = (try? await clip.makeAsset().load(.duration).seconds) ?? 0
        return seconds.isFinite ? min(max(seconds, 0), longestSeconds) : 0
    }
    /// What goes in a story, in bytes. It travels in pieces, each its own relay message, and the receiver joins them:
    /// two of `StoryClipPieces.framedSize` to an app that reads frames (4 MiB on the wire), four of
    /// `StoryClipPieces.size` to an older one (12 MiB, see there). At 15 seconds this leaves about 1.9 Mbit/s,
    /// plenty for 1080p HEVC.
    static let maxBytes = 3_800_000
    /// Full HD, for clips shot at that size or more; smaller sources are kept at 720p rather than blown up.
    static let hdSize = CGSize(width: 1080, height: 1920)
    static let size = CGSize(width: 720, height: 1280)
    static let fps: Int32 = 30
    /// How long an export may take before it's given up on. A 15-second clip takes well under half a minute.
    static let exportTimeout: TimeInterval = 120

    /// Set from the watchdog's queue and read from the export's.
    final class Stuck: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }

    /// The look to bake into every frame, scaled to fill the story's 9:16 frame and centred.
    static func composition(for asset: AVAsset, filter: StoryFilter, size: CGSize = StoryVideo.size,
                            zoom: ZoomTrack = .none, text: CIImage? = nil, framing: FramingBox? = nil) -> AVMutableVideoComposition {
        // The words are drawn once at full HD and fitted to this clip's size, then laid over every frame.
        let words = text.map { $0.transformed(by: CGAffineTransform(scaleX: size.width / $0.extent.width, y: size.width / $0.extent.width)) }
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let e = source.extent
            let frame = CGRect(origin: .zero, size: size)
            let fillScale = max(size.width / e.width, size.height / e.height)
            let placed = framing?.value ?? .fill
            let scale = fillScale * placed.zoom
            let w = e.width * scale, h = e.height * scale
            let moved = CGAffineTransform(translationX: (size.width - w) / 2 + placed.dx * size.width,
                                          y: (size.height - h) / 2 - placed.dy * size.height)
            let flat = source.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            var image = flat.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: moved)
            // Smaller than the frame, or moved off an edge: a soft, darkened copy of the picture fills what's left.
            if !image.extent.contains(frame.insetBy(dx: 0.5, dy: 0.5)) {
                // Blurred at a quarter of the size and scaled back up: it looks the same, and costs a sixteenth,
                // which keeps the live preview smooth.
                let q: CGFloat = 0.25
                let back = flat.transformed(by: CGAffineTransform(scaleX: fillScale * q, y: fillScale * q))
                    .transformed(by: CGAffineTransform(translationX: (size.width - e.width * fillScale) / 2 * q,
                                                       y: (size.height - e.height * fillScale) / 2 * q))
                    .clampedToExtent()
                    .applyingGaussianBlur(sigma: size.width / 14 * q)
                    .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q))
                    .cropped(to: frame)
                let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.3)).cropped(to: frame)
                image = image.composited(over: dim.composited(over: back))
            }
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

    /// The picture's size as it is shown (rotation applied), or nil if it can't be read.
    static func uprightSize(of clip: MemoryClip) async -> CGSize? {
        let asset = clip.makeAsset()
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let upright = natural.applying(transform)
        let size = CGSize(width: abs(upright.width), height: abs(upright.height))
        return size.width > 0 && size.height > 0 ? size : nil
    }

    /// How long the clip plays in a story, capped.
    static func duration(of clip: MemoryClip) async -> Double {
        let seconds = (try? await clip.makeAsset().load(.duration).seconds) ?? 0
        return seconds.isFinite ? min(max(seconds, 0), maxSeconds) : 0
    }

    /// Re-encodes a recording or picked clip with the look baked in: first 15 seconds, portrait 720p, bitrate
    /// chosen to fit `maxBytes`, no location or device metadata. Returns the file's bytes.
    static func export(from clip: MemoryClip, filter: StoryFilter, zoom: ZoomTrack = .none, maxBytes: Int = StoryVideo.maxBytes,
                       maxSeconds: Double = StoryVideo.maxSeconds, size: CGSize? = nil, text: CIImage? = nil,
                       from start: Double = 0, framing: StoryFraming = .fill) async throws -> Data {
        let asset = clip.makeAsset()
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let total = try? await asset.load(.duration), total.seconds.isFinite, total.seconds > 0 else { throw StoryVideoError.unreadable }
        let seconds = min(total.seconds - start, maxSeconds)
        guard seconds > 0.05 else { throw StoryVideoError.unreadable }
        // Full HD when the clip is at least that sharp; otherwise it isn't blown up.
        let upright = (try? await track.load(.naturalSize, .preferredTransform)).map { $0.0.applying($0.1) } ?? .zero
        let fixedSize = size != nil
        // A small budget (one part of a long video) is spent on 720p: full HD would be too thin.
        let size = size ?? (max(abs(upright.width), abs(upright.height)) >= 1700 && maxBytes >= 2_500_000 ? hdSize : StoryVideo.size)
        // If the phone's encoder refuses the first settings (HEVC at full HD on some hardware, say), the same clip is
        // tried with H.264, then at 720p, rather than giving up.
        var configs: [(size: CGSize, hevc: Bool)] = [(size, true), (size, false)]
        if !fixedSize, size != StoryVideo.size { configs.append((StoryVideo.size, false)) }
        var config = 0
        // Each retry spends less of the budget, in case the encoder overshoots on busy footage.
        for share in [0.85, 0.65, 0.45] {
            try Task.checkCancellation()
            // A very short clip would otherwise ask for a bitrate no encoder takes (and a huge one). The
            // budget still decides the rate; this only stops it running away on the first fraction of a second.
            let wanted = Double(maxBytes) * share * 8 / max(seconds, 0.5)
            var data: Data?
            while data == nil {
                try Task.checkCancellation()
                let (size, hevc) = configs[config]
                let ceiling = size.width >= 1_000 || size.height >= 1_000 ? 16_000_000.0 : 8_000_000.0
                do {
                    data = try await transcode(asset, seconds: seconds, filter: filter, zoom: zoom, size: size, text: text,
                                               bitsPerSecond: max(Int(min(wanted, ceiling)) - 48_000, 150_000), allowHEVC: hevc, from: start, framing: FramingBox(framing))
                } catch StoryVideoError.failed(let why) {
                    config += 1
                    if config >= configs.count { throw StoryVideoError.failed(why) }
                }
            }
            if let data, data.count <= maxBytes { return data }
        }
        throw StoryVideoError.tooLarge
    }

    /// The error with its domain and code (and the one under it), so a failure says which part gave up.
    private static func describe(_ error: Error?, _ stage: String) -> String {
        guard let error = error as NSError? else { return "\(stage) failed" }
        var text = "\(error.localizedDescription) [\(stage) \(error.domain) \(error.code)"
        if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError { text += ", \(under.domain) \(under.code)" }
        return text + "]"
    }

    private static func transcode(_ asset: AVURLAsset, seconds: Double, filter: StoryFilter, zoom: ZoomTrack, size: CGSize,
                                  text: CIImage? = nil, bitsPerSecond: Int, allowHEVC: Bool = true, from start: Double = 0, framing: FramingBox? = nil) async throws -> Data {
        let begin = CMTime(seconds: start, preferredTimescale: 600)
        let range = CMTimeRange(start: begin, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let readerVideo = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerVideo.videoComposition = composition(for: asset, filter: filter, size: size, zoom: zoom, text: text, framing: framing)
        guard reader.canAdd(readerVideo) else { throw StoryVideoError.unreadable }
        reader.add(readerVideo)

        // The finished clip is handed over in pieces and joined in memory: it never exists as a file.
        let sink = SegmentSink()
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        writer.initialSegmentStartTime = begin
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
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: allowHEVC && writer.canApply(outputSettings: settings(.hevc), forMediaType: .video)
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
            throw StoryVideoError.failed(Self.describe(reader.error ?? writer.error, "start"))
        }
        writer.startSession(atSourceTime: begin)
        // A clip that has not finished in this long is stuck: stopping the reader and writer lets the wait end, so the
        // person gets a message and can try again instead of a spinner that never stops.
        let stuck = Stuck()
        nonisolated(unsafe) let watchedReader = reader
        nonisolated(unsafe) let watchedWriter = writer
        let watchdog = DispatchWorkItem {
            stuck.set()
            watchedReader.cancelReading()
            watchedWriter.cancelWriting()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + exportTimeout, execute: watchdog)
        defer { watchdog.cancel() }
        // Pull the samples ourselves rather than waiting for the writer to call back. A writer can stop asking
        // for one track while it waits on another (a clip with sound can do this at its first frames), and a
        // callback that never comes would leave the export waiting for ever, past even the watchdog. Polling
        // the same readiness flag always gets to the end, and gives up when the watchdog or the writer does.
        // Each track gets a thread of its own: reading one track can wait on the other being read, and on the
        // shared pool several exports at once filled it with readers waiting, so the other track never ran.
        await withTaskGroup(of: Void.self) { group in
            for (output, input) in pumps {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "pulshade.story.export.\(input.mediaType.rawValue)")
                        nonisolated(unsafe) let output = output
                        nonisolated(unsafe) let input = input
                        queue.async {
                            while !stuck.isSet, watchedWriter.status == .writing {
                                guard input.isReadyForMoreMediaData else {
                                    usleep(5_000)
                                    continue
                                }
                                guard let buffer = output.copyNextSampleBuffer() else { break }
                                if !input.append(buffer) { break }
                            }
                            input.markAsFinished()
                            done.resume()
                        }
                    }
                }
            }
        }
        if stuck.isSet { throw StoryVideoError.timedOut }
        if reader.status == .failed { writer.cancelWriting(); throw StoryVideoError.failed(Self.describe(reader.error, "read")) }
        await writer.finishWriting()
        guard writer.status == .completed else { throw StoryVideoError.failed(Self.describe(writer.error, "write")) }
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

// MARK: - Videos in chats

/// A video sent in a chat: up to 30 seconds, kept in its own shape (not cut to a story's), small enough to send.
enum ChatVideo {
    static let maxSeconds: Double = 30
    /// About 1.3 Mbit/s at full length: three framed pieces.
    static let maxBytes = 5_000_000
    static let posterSide: CGFloat = 480

    /// The clip made ready to send, with a still from it and its length. Nil if it can't be read.
    static func prepare(_ clip: MemoryClip, zoom: ZoomTrack = .none) async -> (clip: Data, poster: Data?, seconds: Double)? {
        let asset = clip.makeAsset()
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let upright = natural.applying(transform)
        let (w, h) = (abs(upright.width), abs(upright.height))
        guard w > 0, h > 0 else { return nil }
        // The long side at 1280 at most, never blown up, and even numbers (the encoder needs them).
        let scale = min(1, 1280 / max(w, h))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * scale / 2).rounded() * 2) }
        guard let made = try? await StoryVideo.export(from: clip, filter: .none, zoom: zoom, maxBytes: maxBytes, maxSeconds: maxSeconds,
                                                      size: CGSize(width: even(w), height: even(h))) else { return nil }
        let ready = MemoryClip(made)
        let seconds = min((try? await ready.makeAsset().load(.duration).seconds) ?? 0, maxSeconds)
        let poster = await StoryVideo.poster(of: ready).flatMap { cleanJPEG(PlatformImage.from(cgImage: $0), maxSide: posterSide) }
        return (made, poster, seconds.isFinite ? max(seconds, 0) : 0)
    }
}

// MARK: - Sending a clip in pieces

/// A clip is cut into pieces that each fit one relay message, and sent as separate messages.
enum StoryClipPieces {
    /// For an app from before frames: base64 three times over takes this to 2.4 MB, sent as 3 MiB.
    static let size = 1_000_000
    /// For an app that reads frames: the piece travels raw and fills the 2 MiB padding bucket, with room left for
    /// everything wrapped round it (the ratchet header with a post-quantum key, the envelope's own fields).
    static let framedSize = 2_080_000
    /// The most pieces one clip may come in: a chat video cut the older way takes six.
    static let maxPieces = 8

    static func split(_ clip: Data, framed: Bool = false) -> [Data] {
        let size = framed ? framedSize : size
        return stride(from: 0, to: clip.count, by: size).map { clip.subdata(in: $0..<min($0 + size, clip.count)) }
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
