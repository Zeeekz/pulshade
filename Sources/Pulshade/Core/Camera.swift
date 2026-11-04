import Foundation
import AVFoundation
import CoreImage

/// The camera for stories: a live preview with a look applied, one photo at a time or a clip of up to 15
/// seconds, front or back, with flash on iPhone. Photos stay in memory and clips in a temporary file until
/// they're framed and posted, sealed like any other message.
@MainActor
@Observable
final class Camera: NSObject {
    @ObservationIgnored let session = AVCaptureSession()
    /// Shows the filtered frames. The look is baked in again when the photo or clip is posted.
    @ObservationIgnored let preview = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let movie = AVCaptureMovieFileOutput()
    @ObservationIgnored private let frames = AVCaptureVideoDataOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "pulshade.camera")
    @ObservationIgnored private let framer = FrameFilter()
    private(set) var front = false
    private(set) var running = false
    private(set) var recording = false
    /// When the clip being recorded began.
    private(set) var recordingStart: Date?
    var flash = false
    /// Whether the camera in use has a flash.
    private(set) var hasFlash = false
    @ObservationIgnored private var micAllowed = false
    @ObservationIgnored private var taken: ((PlatformImage) -> Void)?
    @ObservationIgnored private var recorded: ((URL?, ZoomTrack) -> Void)?
    @ObservationIgnored private var device: AVCaptureDevice?
    /// The zoom now, 1 or more.
    private(set) var zoom: CGFloat = 1
    /// The most this camera zooms in.
    private(set) var maxZoom: CGFloat = 1
    /// Zoom over a clip being recorded, for cameras that only zoom digitally (the Mac).
    @ObservationIgnored private var zoomTrack = ZoomTrack()

    var filter: StoryFilter = .none {
        didSet { framer.filter = filter }
    }

    override init() {
        super.init()
        preview.videoGravity = .resizeAspectFill
    }

    /// False when there's no camera, or Pulshade isn't allowed to use it.
    func start() async -> Bool {
        guard !running, await AVCaptureDevice.requestAccess(for: .video) else { return running }
        guard configure() else { return false }
        running = true
        let session = session
        queue.async { session.startRunning() }
        return true
    }

    func stop() {
        if recording { movie.stopRecording() }
        guard running else { return }
        running = false
        let session = session
        queue.async { session.stopRunning() }
    }

    func flip() {
        guard !recording else { return }
        front.toggle()
        if !configure() { front.toggle(); _ = configure() }
    }

    /// Asks for the microphone the first time you switch to video, so photos never prompt for it.
    func allowSound() async {
        guard !micAllowed else { return }
        micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        if micAllowed, running { _ = configure() }
    }

    func capture(_ done: @escaping (PlatformImage) -> Void) {
        guard running, !recording else { return }
        taken = done
        let settings = AVCapturePhotoSettings()
        #if os(iOS)
        if flash && hasFlash && output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        #endif
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Starts a clip; it stops by itself at 15 seconds. `done` gets the file, or nil if nothing was kept.
    func record(_ done: @escaping (URL?, ZoomTrack) -> Void) {
        guard running, !recording, !movie.isRecording else { return }
        recorded = done
        zoomTrack = ZoomTrack()
        #if os(macOS)
        zoomTrack.add(at: 0, zoom: zoom)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("story-rec-\(UUID().uuidString).mov")
        #if os(iOS)
        if flash && hasFlash, let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, device.hasTorch {
            try? device.lockForConfiguration()
            device.torchMode = .on
            device.unlockForConfiguration()
        }
        #endif
        recording = true
        recordingStart = Date()
        movie.startRecording(to: url, recordingDelegate: self)
    }

    /// Zooms in or out, smoothly, within what the camera can do. On the iPhone this is the camera's own zoom, so
    /// it's in the photo and the clip as shot; on the Mac it's cropped in digitally, in the preview, the photo and
    /// (once the clip is prepared) the clip.
    func setZoom(_ requested: CGFloat) {
        let z = ZoomMath.clamp(requested, max: maxZoom)
        guard z != zoom else { return }
        zoom = z
        #if os(iOS)
        if let device, (try? device.lockForConfiguration()) != nil {
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            device.ramp(toVideoZoomFactor: z, withRate: 12)
            device.unlockForConfiguration()
        }
        #else
        framer.zoom = z
        if let start = recordingStart { zoomTrack.add(at: Date().timeIntervalSince(start), zoom: z) }
        #endif
    }

    func finishRecording() {
        guard recording else { return }
        movie.stopRecording()
    }

    private func configure() -> Bool {
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        // Full HD where the camera has it.
        session.sessionPreset = [AVCaptureSession.Preset.hd1920x1080, .hd1280x720].first { session.canSetSessionPreset($0) } ?? .high
        session.inputs.forEach(session.removeInput)
        if session.canAddInput(input) { session.addInput(input) }
        if micAllowed, let mic = AVCaptureDevice.default(for: .audio), let audio = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(audio) {
            session.addInput(audio)
        }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        if !session.outputs.contains(movie), session.canAddOutput(movie) {
            session.addOutput(movie)
            movie.maxRecordedDuration = CMTime(seconds: StoryVideo.maxSeconds, preferredTimescale: 600)
        }
        if !session.outputs.contains(frames), session.canAddOutput(frames) {
            session.addOutput(frames)
            frames.alwaysDiscardsLateVideoFrames = true
            frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            framer.layer = preview
            frames.setSampleBufferDelegate(framer, queue: DispatchQueue(label: "pulshade.camera.frames"))
        }
        framer.filter = filter
        self.device = device
        zoom = 1
        framer.zoom = 1
        #if os(iOS)
        maxZoom = ZoomMath.clamp(device.activeFormat.videoMaxZoomFactor, max: device.activeFormat.videoMaxZoomFactor)
        #else
        maxZoom = ZoomMath.ceiling
        #endif
        #if os(iOS)
        // Photos come at the camera's best size whatever the video preset is.
        if let best = device.activeFormat.supportedMaxPhotoDimensions.last { output.maxPhotoDimensions = best }
        // The app is portrait only: take photos and clips the right way up, and mirror the selfie camera.
        for connection in [output.connection(with: .video), movie.connection(with: .video), frames.connection(with: .video)]
            .compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
        #else
        for connection in [movie.connection(with: .video), frames.connection(with: .video)].compactMap({ $0 })
            where connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        #endif
        session.commitConfiguration()
        hasFlash = device.hasFlash
        return !session.inputs.isEmpty
    }

    fileprivate func deliver(_ image: PlatformImage) {
        #if os(macOS)
        // No optical zoom here: crop the photo to what the preview showed.
        if zoom > 1.001, let cg = image.cgImageValue {
            let w = CGFloat(cg.width) / zoom, h = CGFloat(cg.height) / zoom
            let crop = CGRect(x: (CGFloat(cg.width) - w) / 2, y: (CGFloat(cg.height) - h) / 2, width: w, height: h).integral
            if let cropped = cg.cropping(to: crop) { taken?(PlatformImage.from(cgImage: cropped)); taken = nil; return }
        }
        #endif
        taken?(image)
        taken = nil
    }

    fileprivate func finished(_ url: URL?) {
        recording = false
        recordingStart = nil
        #if os(iOS)
        if let device = (session.inputs.first as? AVCaptureDeviceInput)?.device, device.hasTorch, device.torchMode == .on {
            try? device.lockForConfiguration()
            device.torchMode = .off
            device.unlockForConfiguration()
        }
        #endif
        recorded?(url, zoomTrack)
        recorded = nil
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = PlatformImage(data: data) else { return }
        Task { @MainActor in self.deliver(image) }
    }
}

extension Camera: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection],
                                error: Error?) {
        // Hitting the 15 second limit is reported as an error, but the clip is fine.
        let ok = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
        if !ok { try? FileManager.default.removeItem(at: url) }
        Task { @MainActor in self.finished(ok ? url : nil) }
    }
}

/// Colours each camera frame with the chosen look and puts it on the preview layer.
private final class FrameFilter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var current = StoryFilter.none
    private var zoomed: CGFloat = 1
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    nonisolated(unsafe) var layer: AVSampleBufferDisplayLayer?

    var filter: StoryFilter {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Digital zoom for the preview, where the camera can't zoom itself.
    var zoom: CGFloat {
        get { lock.withLock { zoomed } }
        set { lock.withLock { zoomed = newValue } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let layer else { return }
        let look = filter, zoom = zoom
        var shown = sampleBuffer
        if look != .none || zoom > 1.001, let source = CMSampleBufferGetImageBuffer(sampleBuffer),
           let colored = render(source, look, zoom), let wrapped = wrap(colored, like: sampleBuffer) {
            shown = wrapped
        }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(shown, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(shown)
    }

    private func render(_ source: CVPixelBuffer, _ look: StoryFilter, _ zoom: CGFloat) -> CVPixelBuffer? {
        let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if pool == nil || size != poolSize {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var made: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &made)
            pool = made
            poolSize = size
        }
        var out: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        var image = CIImage(cvPixelBuffer: source)
        let frame = image.extent
        if zoom > 1.001 {
            let c = CGPoint(x: frame.midX, y: frame.midY)
            image = image.transformed(by: CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: c.x * (1 - zoom), ty: c.y * (1 - zoom)))
        }
        StoryFilter.context.render(look.apply(image).cropped(to: frame), to: out)
        return out
    }

    private func wrap(_ buffer: CVPixelBuffer, like original: CMSampleBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(original),
                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(original),
                                        decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &out)
        return out
    }
}
