// Camera -> display + Vision + follow controller + (optional) video to laptop.
//
// Latency/cost choices:
//  - 640x480 (4:3) at 30 fps: enough pixels for a person at 4 m, cheap for Vision.
//  - alwaysDiscardsLateVideoFrames: never queue stale frames.
//  - Video stabilization OFF (it adds frames of delay).
//  - The same CVPixelBuffer goes to the display layer, Vision and the JPEG
//    encoder without being copied.

import AVFoundation
import UIKit

final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "droneboyfriendtracker.camera.session")
    private let videoQueue = DispatchQueue(label: "droneboyfriendtracker.camera", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var lastWidth = 0, lastHeight = 0
    private let follow: FollowController
    private let link: DroneLink
    private let video = VideoSender()
    private let layerLock = NSLock()
    private weak var displayLayerUnsafe: AVSampleBufferDisplayLayer?

    var onError: ((String) -> Void)?

    init(follow: FollowController, link: DroneLink) {
        self.follow = follow
        self.link = link
        super.init()
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        layerLock.lock(); displayLayerUnsafe = layer; layerLock.unlock()
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.onError?("Camera access denied. Enable it in Settings > DroneBoyfriendTracker.") }
                return
            }
            self.sessionQueue.async {
                if self.session.inputs.isEmpty { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func configure() {
        let dev: AVCaptureDevice?
        if follow.front {
            dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        } else {
            dev = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
        guard let dev, let input = try? AVCaptureDeviceInput(device: dev) else {
            DispatchQueue.main.async { self.onError?("Camera not available") }
            return
        }
        device = dev

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video) {
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false  // geometry needs the true (unmirrored) image
            }
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
        }
        do {
            try dev.lockForConfiguration()
            dev.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            dev.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            dev.unlockForConfiguration()
        } catch {}
        session.commitConfiguration()

        // Keep the buffers upright relative to gravity (landscape either way round).
        let rc = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        rotationCoordinator = rc
        applyRotation(rc.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = rc.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async { self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(angle) else { return }
        conn.videoRotationAngle = angle
    }

    // MARK: - per frame (camera queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        display(sampleBuffer)

        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        if w != lastWidth || h != lastHeight, let dev = device {
            lastWidth = w
            lastHeight = h
            follow.setIntrinsics(CameraIntrinsics(width: w, height: h, horizontalFOVDegrees: Double(dev.activeFormat.videoFieldOfView)))
        }

        let now = ProcessInfo.processInfo.systemUptime
        let boxes = follow.tracker.detect(pixelBuffer)
        follow.onVision(boxes, time: now)

        let telem = link.latestTelemetry
        video.submit(pixelBuffer,
                     box: follow.currentTargetBox,
                     tracking: follow.currentSetpoint().flags & FollowFlags.tracking != 0,
                     enabled: telem?.videoOn ?? false,
                     laptopIP: telem?.laptopIP)
    }

    private func display(_ sampleBuffer: CMSampleBuffer) {
        layerLock.lock()
        let layer = displayLayerUnsafe
        layerLock.unlock()
        guard let layer else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sampleBuffer)
    }
}

/// UIView backed by an AVSampleBufferDisplayLayer (zero-copy video display).
final class SampleBufferUIView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
