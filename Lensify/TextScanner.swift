//
//  TextScanner.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import AVFoundation
import UIKit
import Vision

/// Camera capture plus live text recognition.
///
/// Frames are recognized straight from the camera's pixel buffer on a serial
/// queue that drops anything it cannot keep up with, so recognition throttles
/// itself instead of queueing work. Only lines that have not been seen recently
/// are handed back, which is what keeps the card from filling with the same
/// sentence over and over.
final class TextScanner: NSObject {

    /// New lines of text, delivered on the main queue.
    var onText: (([String]) -> Void)?
    /// Permission and hardware problems, delivered on the main queue.
    var onUnavailable: ((String) -> Void)?

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "io.spectaclesystems.lensify.camera")
    private let visionQueue = DispatchQueue(label: "io.spectaclesystems.lensify.vision", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()

    private var device: AVCaptureDevice?
    private var isConfigured = false
    private var configurationFailed = false

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewObservation: NSKeyValueObservation?
    private var captureObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    private let stateLock = NSLock()
    private var _recognitionEnabled = false
    private var _zoomFactor: CGFloat = 1

    // Vision-queue state.
    private var lastRecognitionAt: CFTimeInterval = 0
    private var recentKeys: [String] = []
    private var recentLookup: Set<String> = []

    private let minimumInterval: CFTimeInterval = 0.4
    private let minimumConfidence: Float = 0.4
    private let recentLimit = 80
    private let maximumZoom: CGFloat = 5

    private lazy var textRequest: VNRecognizeTextRequest = {
        let request = VNRecognizeTextRequest { [weak self] request, error in
            self?.handleRecognition(request: request, error: error)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        // Ignore specks of text that are too small to read reliably; this also
        // cuts a lot of work out of every frame.
        request.minimumTextHeight = 0.015
        return request
    }()

    // MARK: - Lifecycle

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.onUnavailable?("Camera access is turned off in Settings.")
                }
                return
            }
            self.sessionQueue.async {
                self.configureIfNeeded()
                guard self.isConfigured, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    var isRecognitionEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _recognitionEnabled
    }

    func setRecognitionEnabled(_ enabled: Bool) {
        stateLock.lock()
        let changed = _recognitionEnabled != enabled
        _recognitionEnabled = enabled
        stateLock.unlock()

        guard changed, enabled else { return }
        // Forget what was on screen last time so the first frame of a new
        // session is not silently swallowed as a duplicate.
        visionQueue.async { [weak self] in
            self?.recentKeys.removeAll(keepingCapacity: true)
            self?.recentLookup.removeAll(keepingCapacity: true)
        }
    }

    /// Clears the duplicate history, e.g. when the user starts a new document.
    func resetHistory() {
        visionQueue.async { [weak self] in
            self?.recentKeys.removeAll(keepingCapacity: true)
            self?.recentLookup.removeAll(keepingCapacity: true)
        }
    }

    // MARK: - Configuration

    private func configureIfNeeded() {
        guard !isConfigured, !configurationFailed else { return }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            configurationFailed = true
            DispatchQueue.main.async { self.onUnavailable?("No camera is available on this device.") }
            return
        }

        session.beginConfiguration()
        // 1080p gives Vision enough detail to read small print; the frame rate
        // costs nothing extra because late frames are discarded.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            configurationFailed = true
            DispatchQueue.main.async { self.onUnavailable?("The camera could not be opened.") }
            return
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: visionQueue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        // Portrait until the rotation coordinator says otherwise, so the very
        // first frames are still the right way up for Vision.
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        self.device = device
        configureDevice(device)
        isConfigured = true

        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.previewLayer else { return }
            self.makeRotationCoordinator(device: device, previewLayer: layer)
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .none
            }
            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = true
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
        } catch {
            print("TextScanner: could not configure the camera - \(error)")
        }
    }

    // MARK: - Rotation

    /// Called by the preview view once its layer exists. Keeps both the preview
    /// and the buffers Vision sees level with the horizon, which is what makes
    /// recognition work in landscape.
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill

        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            DispatchQueue.main.async {
                self.makeRotationCoordinator(device: device, previewLayer: layer)
            }
        }
    }

    private func makeRotationCoordinator(device: AVCaptureDevice, previewLayer: AVCaptureVideoPreviewLayer) {
        guard rotationCoordinator?.device !== device || previewObservation == nil else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        previewObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        }
        captureObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                  options: [.initial, .new]) { [weak self] coordinator, _ in
            self?.applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        }
    }

    private func applyPreviewRotation(_ angle: CGFloat) {
        DispatchQueue.main.async { [weak self] in
            guard let connection = self?.previewLayer?.connection,
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let connection = self?.output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Zoom

    var zoomFactor: CGFloat {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _zoomFactor
    }

    func setZoom(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }

            let limit = min(device.activeFormat.videoMaxZoomFactor, self.maximumZoom)
            let clamped = max(1, min(factor, limit))
            guard abs(clamped - device.videoZoomFactor) > 0.005 else { return }

            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                return
            }

            self.stateLock.lock()
            self._zoomFactor = clamped
            self.stateLock.unlock()
        }
    }
}

// MARK: - Frame handling

extension TextScanner: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isRecognitionEnabled else { return }

        let now = CACurrentMediaTime()
        guard now - lastRecognitionAt >= minimumInterval else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastRecognitionAt = now

        // The buffer is already rotated level with the horizon by the capture
        // connection, so Vision needs no further orientation hint.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([textRequest])
        } catch {
            print("TextScanner: text recognition failed - \(error)")
        }
    }

    private func handleRecognition(request: VNRequest, error: Error?) {
        if let error {
            print("TextScanner: recognition error - \(error)")
            return
        }
        guard let observations = request.results as? [VNRecognizedTextObservation] else { return }

        let candidates: [(box: CGRect, text: String)] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 2, text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return (observation.boundingBox, text)
        }
        guard !candidates.isEmpty else { return }

        // Reading order: top to bottom, then left to right within a line.
        let ordered = candidates.sorted { first, second in
            if abs(first.box.midY - second.box.midY) > 0.02 {
                return first.box.midY > second.box.midY
            }
            return first.box.minX < second.box.minX
        }

        var fresh: [String] = []
        for candidate in ordered {
            let key = normalizedKey(candidate.text)
            guard key.count >= 3, !recentLookup.contains(key) else { continue }
            // Skip fragments of something already captured this session.
            guard !recentKeys.contains(where: { $0.contains(key) }) else { continue }

            recentKeys.append(key)
            recentLookup.insert(key)
            fresh.append(candidate.text)
        }

        if recentKeys.count > recentLimit {
            let excess = recentKeys.count - recentLimit
            for key in recentKeys.prefix(excess) { recentLookup.remove(key) }
            recentKeys.removeFirst(excess)
        }

        guard !fresh.isEmpty else { return }
        DispatchQueue.main.async { self.onText?(fresh) }
    }

    private func normalizedKey(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
