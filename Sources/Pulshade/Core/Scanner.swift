import Foundation
import AVFoundation
import Vision
import SwiftUI

/// Reads QR codes from the Mac's camera. Frames are looked at in memory and never saved.
@MainActor
@Observable
final class QRScanner: NSObject {
    private(set) var running = false
    private(set) var found: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "pulshade.scanner")

    func start() async -> Bool {
        guard !running, await AVCaptureDevice.requestAccess(for: .video),
              let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        found = nil
        running = true
        let session = session
        queue.async { session.startRunning() }
        return true
    }

    func stop() {
        guard running else { return }
        running = false
        let session = session
        queue.async {
            session.stopRunning()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
        }
    }

    fileprivate func detected(_ text: String) {
        guard running, found == nil else { return }
        found = text
        stop()
    }
}

extension QRScanner: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels).perform([request])
        guard let text = request.results?.compactMap(\.payloadStringValue).first else { return }
        Task { @MainActor in self.detected(text) }
    }
}

/// Live camera preview for the scanner.
struct CameraPreview: View {
    let session: AVCaptureSession

    var body: some View {
        LayerView(layer: {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            return layer
        }())
    }
}
