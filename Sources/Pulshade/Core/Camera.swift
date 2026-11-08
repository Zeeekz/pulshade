import Foundation
import AVFoundation
import CoreImage
import UniformTypeIdentifiers

/// The camera for stories: a live preview with a look applied, one photo at a time or a clip of up to 15
/// seconds, front or back, with flash on iPhone. The back camera zooms out to the ultra wide lens where the iPhone
/// has one, taps focus, and the camera can be flipped halfway through a clip. Photos stay in memory and clips in a
/// temporary file until they're framed and posted, sealed like any other message.
@MainActor
@Observable
final class Camera: NSObject {
    @ObservationIgnored let session = AVCaptureSession()
    /// Shows the filtered frames. The look is baked in again when the photo or clip is posted.
    @ObservationIgnored let preview = AVSampleBufferDisplayLayer()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private let sound = AVCaptureAudioDataOutput()
    @ObservationIgnored private let frames = AVCaptureVideoDataOutput()
    @ObservationIgnored private let queue = DispatchQueue(label: "pulshade.camera")
    /// Colours the frames for the preview and, while a clip is being made, writes them to it.
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
    @ObservationIgnored private var taken: ((PlatformImage?) -> Void)?
    @ObservationIgnored private var recorded: ((MemoryClip?, ZoomTrack) -> Void)?
    @ObservationIgnored private var device: AVCaptureDevice?
    /// The zoom now as the person sees it: 1 is the main lens, below 1 is the ultra wide one.
    private(set) var zoom: CGFloat = 1
    /// The most this camera zooms in, and the least (0.5 with an ultra wide lens).
    private(set) var maxZoom: CGFloat = 1
    private(set) var minZoom: CGFloat = 1
    /// The lenses to jump between, such as 0.5, 1 and 3. Empty where there's only one.
    private(set) var lensStops: [CGFloat] = []
    /// What the camera's own zoom factor is at "1×". 2 on an iPhone whose factor 1 is the ultra wide lens.
    @ObservationIgnored private var baseFactor: CGFloat = 1
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
        // A microphone already allowed goes in with the first setup, so nothing has to be set up again.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized { micAllowed = true }
        // A stop still under way finishes first.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in queue.async { done.resume() } }
        guard !running, configure() else { return running }
        running = true
        // Waits for the session to be running: setting it up again while it's still starting throws, and
        // that took the whole app down.
        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { session.startRunning(); done.resume() }
        }
        return true
    }

    func stop() {
        if recording { framer.endClip() }
        guard running else { return }
        running = false
        let session = session
        queue.async { session.stopRunning() }
    }

    /// Switches between the front and back camera, also while a clip is being recorded: the clip carries on from the
    /// other camera after a moment's pause on the last picture.
    func flip() {
        guard running else { return }
        front.toggle()
        if !configure() { front.toggle(); _ = configure() }
        if recording { setTorch(flash && hasFlash) }
    }

    /// Asks for the microphone the first time you switch to video, so photos never prompt for it.
    func allowSound() async {
        guard !micAllowed else { return }
        micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        if micAllowed, running { _ = configure() }
    }

    func capture(_ done: @escaping (PlatformImage?) -> Void) {
        guard running, !recording else { done(nil); return }
        taken = done
        let settings = AVCapturePhotoSettings()
        #if os(iOS)
        if flash && hasFlash && output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        #endif
        output.capturePhoto(with: settings, delegate: self)
    }

    /// How long a clip may run before it stops by itself: a story's 15 seconds unless the chat camera says more.
    var clipLimit = StoryVideo.maxSeconds

    /// Starts a clip; it stops by itself at `clipLimit` seconds. `done` gets the clip, or nil if nothing was kept. The clip is
    /// built in memory and never written to a file.
    func record(_ done: @escaping (MemoryClip?, ZoomTrack) -> Void) {
        guard running, !recording else { done(nil, ZoomTrack()); return }
        recorded = done
        zoomTrack = ZoomTrack()
        #if os(macOS)
        zoomTrack.add(at: 0, zoom: zoom)
        #endif
        setTorch(flash && hasFlash)
        recording = true
        recordingStart = Date()
        let audio = micAllowed ? sound.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) as? [String: Any] : nil
        framer.startClip(audio: audio, limit: clipLimit) { [weak self] clip in
            Task { @MainActor in self?.finished(clip) }
        }
    }

    /// Zooms in or out, smoothly, within what the camera can do. On the iPhone this is the camera's own zoom, so
    /// it's in the photo and the clip as shot; on the Mac it's cropped in digitally, in the preview, the photo and
    /// (once the clip is prepared) the clip.
    func setZoom(_ requested: CGFloat) {
        let z = ZoomMath.clamp(requested, min: minZoom, max: maxZoom)
        guard z != zoom else { return }
        zoom = z
        #if os(iOS)
        if let device, (try? device.lockForConfiguration()) != nil {
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            device.ramp(toVideoZoomFactor: min(max(z * baseFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor), withRate: 12)
            device.unlockForConfiguration()
        }
        #else
        framer.zoom = z
        if let start = recordingStart { zoomTrack.add(at: Date().timeIntervalSince(start), zoom: z) }
        #endif
    }

    /// Focuses and sets the exposure on a tap. `point` is where the picture was touched, `size` the size of the
    /// picture on screen.
    func focus(at point: CGPoint, in size: CGSize) {
        #if os(iOS)
        guard let device, size.width > 0, size.height > 0 else { return }
        let target = Self.devicePoint(for: point, in: size, mirrored: front)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusPointOfInterest = target
            device.focusMode = .continuousAutoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = target
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        #endif
    }

    /// Where a touch on the picture is on the sensor, which is turned a quarter and, on the selfie camera, mirrored.
    /// The picture fills the screen, so the edges of a 9:16 frame can be cropped off.
    nonisolated static func devicePoint(for point: CGPoint, in size: CGSize, mirrored: Bool) -> CGPoint {
        var u = point.x / size.width, v = point.y / size.height
        let frameAspect: CGFloat = 9.0 / 16.0
        let viewAspect = size.width / size.height
        if viewAspect < frameAspect { u = 0.5 + (u - 0.5) * viewAspect / frameAspect }
        else { v = 0.5 + (v - 0.5) * frameAspect / viewAspect }
        u = min(max(u, 0), 1); v = min(max(v, 0), 1)
        return CGPoint(x: v, y: mirrored ? u : 1 - u)
    }

    func finishRecording() {
        guard recording else { return }
        framer.endClip()
    }

    private func setTorch(_ on: Bool) {
        #if os(iOS)
        guard let device, device.hasTorch, device.torchMode != (on ? .on : .off), (try? device.lockForConfiguration()) != nil else { return }
        device.torchMode = on ? .on : .off
        device.unlockForConfiguration()
        #endif
    }

    private func configure() -> Bool {
        #if os(iOS)
        // On the back, the lens that spans them all, so zooming out reaches the ultra wide one.
        let device: AVCaptureDevice? = front
            ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            : [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
                .lazy.compactMap { AVCaptureDevice.default($0, for: .video, position: .back) }.first
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
        if micAllowed, !session.outputs.contains(sound), session.canAddOutput(sound) {
            session.addOutput(sound)
            sound.setSampleBufferDelegate(framer, queue: framer.queue)
        }
        if !session.outputs.contains(frames), session.canAddOutput(frames) {
            session.addOutput(frames)
            frames.alwaysDiscardsLateVideoFrames = true
            frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            framer.layer = preview
            frames.setSampleBufferDelegate(framer, queue: framer.queue)
        }
        framer.filter = filter
        self.device = device
        zoom = 1
        framer.zoom = 1
        #if os(iOS)
        // Factor 1 is the ultra wide lens when there is one; "1×" is where the main lens takes over.
        baseFactor = 1
        if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera,
           let first = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            baseFactor = CGFloat(first.doubleValue)
        }
        minZoom = max(device.minAvailableVideoZoomFactor / baseFactor, 0.5)
        maxZoom = ZoomMath.clamp(device.activeFormat.videoMaxZoomFactor / baseFactor, max: device.activeFormat.videoMaxZoomFactor / baseFactor)
        if (try? device.lockForConfiguration()) != nil {
            if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
            device.videoZoomFactor = min(max(baseFactor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        }
        var stops: [CGFloat] = []
        if minZoom < 0.9 { stops.append((minZoom * 10).rounded() / 10) }
        stops.append(1)
        for factor in device.virtualDeviceSwitchOverVideoZoomFactors {
            let shown = (CGFloat(factor.doubleValue) / baseFactor).rounded()
            if shown > 1.05, shown <= maxZoom { stops.append(shown) }
        }
        lensStops = stops.count > 1 ? stops : []
        #else
        minZoom = 1
        maxZoom = ZoomMath.ceiling
        #endif
        #if os(iOS)
        // Photos come at the camera's best size whatever the video preset is.
        if let best = device.activeFormat.supportedMaxPhotoDimensions.last { output.maxPhotoDimensions = best }
        // The app is portrait only: take photos and clips the right way up, and mirror the selfie camera.
        for connection in [output.connection(with: .video), frames.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = front
            }
        }
        #else
        for connection in [frames.connection(with: .video)].compactMap({ $0 })
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

    fileprivate func finished(_ clip: MemoryClip?) {
        recording = false
        recordingStart = nil
        setTorch(false)
        recorded?(clip, zoomTrack)
        recorded = nil
    }

    /// The photo didn't come: tell the caller so it can clear its "taking" state instead of waiting forever.
    fileprivate func failedCapture() {
        taken?(nil)
        taken = nil
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = PlatformImage(data: data) else {
            Task { @MainActor in self.failedCapture() }
            return
        }
        Task { @MainActor in self.deliver(image) }
    }
}

/// Colours each camera frame with the chosen look and puts it on the preview layer. While a clip is being made it
/// also writes the camera's own frames and sound to the clip (the look is put on when it's posted), which is why
/// the camera can change halfway through.
private final class FrameFilter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                                  @unchecked Sendable {
    /// Frames and sound arrive here one at a time, so the clip is only ever touched from here.
    let queue = DispatchQueue(label: "pulshade.camera.frames")
    private let lock = NSLock()
    private var current = StoryFilter.none
    private var zoomed: CGFloat = 1
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    nonisolated(unsafe) var layer: AVSampleBufferDisplayLayer?
    // The clip (queue only), and what's needed to start it on the first frame.
    private var clip: ClipWriter?
    private var wanted: (audio: [String: Any]?, ended: (MemoryClip?) -> Void)?

    var filter: StoryFilter {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    /// Digital zoom for the preview, where the camera can't zoom itself.
    var zoom: CGFloat {
        get { lock.withLock { zoomed } }
        set { lock.withLock { zoomed = newValue } }
    }

    /// Begins a clip with the next frame. `ended` gets the clip once it's finished, or nil if nothing was kept.
    func startClip(audio: [String: Any]?, limit: Double, ended: @escaping (MemoryClip?) -> Void) {
        queue.async { self.wanted = (audio, ended); self.limit = limit }
    }
    /// How long the clip being made may run (queue only).
    private var limit = StoryVideo.maxSeconds

    /// Finishes the clip; harmless when there isn't one.
    func endClip() {
        queue.async { self.closeClip() }
    }

    private func closeClip() {
        if let clip {
            self.clip = nil
            let ended = wanted?.ended
            wanted = nil
            clip.finish { made in ended?(made) }
        } else if let wanted {
            // Stopped before a single frame came in.
            self.wanted = nil
            wanted.ended(nil)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            clip?.append(sound: sampleBuffer)
            return
        }
        if clip == nil, let wanted, let source = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let size = CGSize(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
            if let made = ClipWriter(size: size, audio: wanted.audio, start: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), limit: limit) { clip = made }
            else { self.wanted = nil; wanted.ended(nil) }
        }
        if let clip {
            clip.append(picture: sampleBuffer)
            if clip.full { closeClip() }
        }
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

/// A clip being built from the camera's frames and sound, entirely in memory: the writer hands over its output in
/// pieces and they are joined into one fragmented MP4. Both start together at the first frame, and it's full at 15
/// seconds. When the camera is flipped there are no frames for a moment: the clip holds the last picture while the
/// sound carries on.
final class ClipWriter {
    private let writer: AVAssetWriter
    private let picture: AVAssetWriterInput
    private let voice: AVAssetWriterInput?
    private let size: CGSize
    private let start: CMTime
    private let sink = SegmentSink()
    private var began = false
    private(set) var full = false
    private let limit: Double

    init?(size: CGSize, audio: [String: Any]?, start: CMTime, limit: Double = StoryVideo.maxSeconds) {
        self.limit = limit
        let writer = AVAssetWriter(contentType: UTType.mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 1)
        writer.initialSegmentStartTime = start
        writer.delegate = sink
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        picture.expectsMediaDataInRealTime = true
        guard writer.canAdd(picture) else { return nil }
        writer.add(picture)
        var voice: AVAssetWriterInput?
        if let audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audio)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); voice = input }
        }
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: start)
        self.writer = writer; self.picture = picture; self.voice = voice; self.size = size; self.start = start
    }

    /// Whether the writer can take another picture now.
    var ready: Bool { picture.isReadyForMoreMediaData }

    func append(picture buffer: CMSampleBuffer) {
        guard writer.status == .writing, let source = CMSampleBufferGetImageBuffer(buffer),
              CGFloat(CVPixelBufferGetWidth(source)) == size.width, CGFloat(CVPixelBufferGetHeight(source)) == size.height,
              picture.isReadyForMoreMediaData else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard time >= start else { return }
        picture.append(buffer)
        began = true
        if (time - start).seconds >= limit { full = true }
    }

    func append(sound buffer: CMSampleBuffer) {
        guard began, let voice, writer.status == .writing, voice.isReadyForMoreMediaData,
              CMSampleBufferGetPresentationTimeStamp(buffer) >= start else { return }
        voice.append(buffer)
    }

    func finish(_ done: @escaping (MemoryClip?) -> Void) {
        guard began, writer.status == .writing else {
            writer.cancelWriting()
            done(nil)
            return
        }
        picture.markAsFinished()
        voice?.markAsFinished()
        let writer = writer, sink = sink
        writer.finishWriting {
            done(writer.status == .completed ? MemoryClip(sink.bytes) : nil)
        }
    }
}
