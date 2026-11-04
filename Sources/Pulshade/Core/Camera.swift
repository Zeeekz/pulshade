import Foundation
import AVFoundation

/// The camera for stories: a live preview and one photo at a time, front or back, with flash on iPhone.
/// Photos stay in memory until they're framed and posted, sealed like any other message.
@MainActor
@Observable
final class Camera: NSObject {
    let session = AVCaptureSession()
    let preview: AVCaptureVideoPreviewLayer
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "pulshade.camera")
    private(set) var front = false
    private(set) var running = false
    var flash = false
    /// Whether the camera in use has a flash.
    private(set) var hasFlash = false
    private var taken: ((PlatformImage) -> Void)?

    override init() {
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        super.init()
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
        guard running else { return }
        running = false
        let session = session
        queue.async { session.stopRunning() }
    }

    func flip() {
        front.toggle()
        if !configure() { front.toggle(); _ = configure() }
    }

    func capture(_ done: @escaping (PlatformImage) -> Void) {
        guard running else { return }
        taken = done
        let settings = AVCapturePhotoSettings()
        #if os(iOS)
        if flash && hasFlash && output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
        #endif
        output.capturePhoto(with: settings, delegate: self)
    }

    private func configure() -> Bool {
        #if os(iOS)
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: front ? .front : .back)
        #else
        let device = AVCaptureDevice.default(for: .video)
        #endif
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach(session.removeInput)
        if session.canAddInput(input) { session.addInput(input) }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        #if os(iOS)
        // The app is portrait only: take photos the right way up.
        for connection in [output.connection(with: .video), preview.connection].compactMap({ $0 })
            where connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        preview.connection?.automaticallyAdjustsVideoMirroring = true
        #endif
        session.commitConfiguration()
        hasFlash = device.hasFlash
        return !session.inputs.isEmpty
    }

    fileprivate func deliver(_ image: PlatformImage) {
        taken?(image)
        taken = nil
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let image = PlatformImage(data: data) else { return }
        Task { @MainActor in self.deliver(image) }
    }
}
