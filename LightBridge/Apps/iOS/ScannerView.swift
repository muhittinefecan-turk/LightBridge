import SwiftUI
import AVFoundation
import LightBridgeCore
/// QR modu: AVCaptureMetadataOutput (bir karede birden çok QR'ı da döndürür → 2×2 çoklu kod).
struct ScannerView: UIViewRepresentable {
    var lockFocus: Bool
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.videoGravity = .resizeAspectFill

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return v
        }
        session.addInput(input)

        try? dev.lockForConfiguration()
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        dev.unlockForConfiguration()

        let out = AVCaptureMetadataOutput()
        if session.canAddOutput(out) {
            session.addOutput(out)
            out.setMetadataObjectsDelegate(context.coordinator, queue: context.coordinator.queue)
        }
        session.commitConfiguration()

        if out.availableMetadataObjectTypes.contains(.qr) {
            out.metadataObjectTypes = [.qr]
        }

        v.previewLayer.session = session
        context.coordinator.session = session
        context.coordinator.device = dev

        // Kamera izni kontrolü ve oturumu başlatma
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
                }
            }
        default:
            break
        }

        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setLocked(lockFocus)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode) }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        let queue = DispatchQueue(label: "com.lightbridge.scanner.metadata", qos: .userInteractive)
        var session: AVCaptureSession?
        var device: AVCaptureDevice?
        private var locked = false

        init(_ cb: @escaping (String) -> Void) { onCode = cb }

        func setLocked(_ l: Bool) {
            guard l != locked, let dev = device else { return }
            locked = l
            try? dev.lockForConfiguration()
            if l {
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
            } else {
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            }
            dev.unlockForConfiguration()
        }

        func metadataOutput(_ o: AVCaptureMetadataOutput, didOutput objs: [AVMetadataObject], from c: AVCaptureConnection) {
            for case let m as AVMetadataMachineReadableCodeObject in objs {
                if let s = m.stringValue {
                    DispatchQueue.main.async { self.onCode(s) }
                }
            }
        }

        deinit { session?.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
            if let conn = previewLayer.connection, conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
    }
}

/// Matris modu: ham video kareleri (YUV, parlaklık düzlemi) → LBMatrix.decode.
struct MatrixScannerView: UIViewRepresentable {
    var lockFocus: Bool
    var onFrame: (Data?) -> Void

    func makeUIView(context: Context) -> ScannerView.PreviewView {
        let v = ScannerView.PreviewView()
        v.previewLayer.videoGravity = .resizeAspectFill

        let session = AVCaptureSession()
        session.beginConfiguration()
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }

        guard let dev = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return v
        }
        session.addInput(input)

        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.setSampleBufferDelegate(context.coordinator, queue: context.coordinator.queue)

        if session.canAddOutput(out) {
            session.addOutput(out)
        }
        session.commitConfiguration()

        v.previewLayer.session = session
        context.coordinator.session = session
        context.coordinator.device = dev

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
                }
            }
        default:
            break
        }

        return v
    }

    func updateUIView(_ uiView: ScannerView.PreviewView, context: Context) {
        context.coordinator.setLocked(lockFocus)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onFrame) }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let onFrame: (Data?) -> Void
        let queue = DispatchQueue(label: "lb.matrix.decode", qos: .userInteractive)
        var session: AVCaptureSession?
        var device: AVCaptureDevice?
        private var locked = false

        init(_ cb: @escaping (Data?) -> Void) { onFrame = cb }

        func setLocked(_ l: Bool) {
            guard l != locked, let dev = device else { return }
            locked = l
            try? dev.lockForConfiguration()
            if l {
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
            } else {
                if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            }
            dev.unlockForConfiguration()
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return }
            let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let rb = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let side = Int(Double(min(w, h)) * 0.8)
            let x0 = (w - side) / 2, y0 = (h - side) / 2
            let ptr = base.assumingMemoryBound(to: UInt8.self).advanced(by: y0 * rb + x0)
            let data = LBMatrix.decode(luma: ptr, width: side, height: side, rowBytes: rb, specs: MatrixSpec.presets)
            DispatchQueue.main.async { self.onFrame(data) }
        }

        deinit { session?.stopRunning() }
    }
}
