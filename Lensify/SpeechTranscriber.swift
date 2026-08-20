//
//  SpeechTranscriber.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import AVFoundation
import Speech

/// Continuous speech-to-text for the audio and multi modes.
///
/// The audio engine is started once and left alone for the whole recording;
/// only the recognition *request* is rotated, because that is the piece with a
/// roughly one-minute server limit. Rotation waits for a pause in speech
/// whenever it can, so sentences are not cut in half.
final class SpeechTranscriber: NSObject {

    /// Committed text plus the in-flight partial. Delivered on the main queue.
    var onTranscript: ((String) -> Void)?
    /// A segment the recognizer has committed to. Safe to persist, never repeated.
    var onSegmentFinalized: ((String) -> Void)?
    /// Microphone level, 0...1, delivered on the main queue about ten times a
    /// second. Levels are always measured internally to find pauses in speech;
    /// this is only reported when someone is listening.
    var onAudioLevel: ((CGFloat) -> Void)?
    /// Permission problems and hard failures, delivered on the main queue.
    var onUnavailable: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "io.spectaclesystems.lensify.speech")

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var rotationTimer: DispatchSourceTimer?

    private var isRunning = false
    private var shouldBeRunning = false
    private var isTapInstalled = false
    private var wasRunningBeforeInterruption = false
    private var preferOnDevice = false
    private var consecutiveFailures = 0

    private var segmentToken = 0
    private var segmentStartedAt = CFAbsoluteTimeGetCurrent()
    private var committed = ""
    private var partial = ""

    /// Written from the audio tap thread, read from `queue`.
    private let audioLock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var lastLoudAt = CFAbsoluteTimeGetCurrent()
    private var lastLevelSentAt: CFTimeInterval = 0
    private var lastTranscriptSentAt: CFTimeInterval = 0

    private let softSegmentLimit: CFAbsoluteTime = 45
    private let hardSegmentLimit: CFAbsoluteTime = 55
    private let silenceBeforeRotate: CFAbsoluteTime = 0.6

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        rotationTimer?.cancel()
        task?.cancel()
        engine.stop()
    }

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in self?.shouldBeRunning = true }

        requestAuthorization { [weak self] granted, message in
            guard let self else { return }
            guard granted else {
                self.queue.async { self.shouldBeRunning = false }
                DispatchQueue.main.async { self.onUnavailable?(message ?? "Speech recognition is unavailable.") }
                return
            }
            self.queue.async {
                // A stop() may have arrived while the prompt was up.
                guard self.shouldBeRunning else { return }
                self.beginRecording()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldBeRunning = false
            self.tearDown(deactivateSession: true)
        }
    }

    /// Drops everything captured so far. Used when a new document is started.
    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            self.committed = ""
            self.partial = ""
            self.publish(force: true)
        }
    }

    // MARK: - Authorization

    private func requestAuthorization(completion: @escaping (Bool, String?) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                completion(false, "Speech recognition permission is turned off in Settings.")
                return
            }
            AVAudioApplication.requestRecordPermission { granted in
                completion(granted, granted ? nil : "Microphone access is turned off in Settings.")
            }
        }
    }

    // MARK: - Engine lifecycle

    private func beginRecording() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else {
            report("Speech recognition is not available right now.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            report("Could not start the microphone: \(error.localizedDescription)")
            return
        }

        guard installTap() else {
            report("The microphone is not producing audio.")
            return
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            removeTap()
            report("Could not start the audio engine: \(error.localizedDescription)")
            return
        }

        isRunning = true
        consecutiveFailures = 0
        lastLoudAt = CFAbsoluteTimeGetCurrent()
        startSegment()
        startRotationTimer()
    }

    private func tearDown(deactivateSession: Bool) {
        rotationTimer?.cancel()
        rotationTimer = nil

        // Invalidating the token makes every in-flight callback a no-op.
        segmentToken += 1
        setActiveRequest(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil

        removeTap()
        if engine.isRunning { engine.stop() }

        let wasRunning = isRunning
        isRunning = false
        commitPartial()

        if wasRunning && deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        if let onAudioLevel {
            DispatchQueue.main.async { onAudioLevel(0) }
        }
    }

    private func installTap() -> Bool {
        guard !isTapInstalled else { return true }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        // A zero sample rate means the session is not really live yet; installing
        // a tap with that format throws an unrecoverable exception.
        guard format.sampleRate > 0, format.channelCount > 0 else { return false }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        isTapInstalled = true
        return true
    }

    private func removeTap() {
        guard isTapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        isTapInstalled = false
    }

    // MARK: - Segments

    private func startSegment() {
        segmentToken += 1
        let token = segmentToken
        segmentStartedAt = CFAbsoluteTimeGetCurrent()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if preferOnDevice, recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }

        self.request = request
        setActiveRequest(request)

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            self?.queue.async { self?.handle(result: result, error: error, token: token) }
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, token: Int) {
        guard token == segmentToken else { return }

        if let result {
            consecutiveFailures = 0
            partial = result.bestTranscription.formattedString
            publish(force: result.isFinal)

            if result.isFinal {
                commitPartial()
                if isRunning { startSegment() }
                return
            }
        }

        guard error != nil else { return }

        // A rotation we asked for arrives here too; either way the segment is
        // over, so bank what we have and open a new one.
        commitPartial()
        guard isRunning else { return }

        consecutiveFailures += 1
        // Repeated failures usually mean the network is gone. On-device
        // recognition is less accurate but it keeps working.
        if consecutiveFailures >= 3, recognizer?.supportsOnDeviceRecognition == true {
            preferOnDevice = true
        }
        if consecutiveFailures >= 8 {
            shouldBeRunning = false
            tearDown(deactivateSession: true)
            report("Speech recognition kept failing and was stopped.")
            return
        }

        let delay = min(2.0, 0.25 * Double(consecutiveFailures))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isRunning, self.segmentToken == token else { return }
            self.startSegment()
        }
    }

    private func startRotationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.rotateIfNeeded() }
        rotationTimer = timer
        timer.resume()
    }

    private func rotateIfNeeded() {
        guard isRunning else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let age = now - segmentStartedAt
        let quietFor = now - loudTimestamp()

        guard age > hardSegmentLimit || (age > softSegmentLimit && quietFor > silenceBeforeRotate) else { return }
        rotateSegment()
    }

    /// Hands the microphone over to a fresh request without leaving a gap.
    ///
    /// The partial we already have is banked first, the replacement request is
    /// opened, and only then is the old one closed out. Anything the old task
    /// reports afterwards carries a stale token and is ignored.
    private func rotateSegment() {
        let retiringRequest = request
        let retiringTask = task

        commitPartial()
        startSegment()

        retiringRequest?.endAudio()
        retiringTask?.finish()
    }

    private func commitPartial() {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard !text.isEmpty else { return }

        committed += committed.isEmpty ? text : " " + text
        DispatchQueue.main.async { self.onSegmentFinalized?(text) }
        publish(force: true)
    }

    private var fullText: String {
        guard !partial.isEmpty else { return committed }
        return committed.isEmpty ? partial : committed + " " + partial
    }

    private func publish(force: Bool) {
        let now = CACurrentMediaTime()
        // Five updates a second reads as live without redrawing the card on
        // every partial result.
        guard force || now - lastTranscriptSentAt > 0.2 else { return }
        lastTranscriptSentAt = now

        let text = fullText
        DispatchQueue.main.async { self.onTranscript?(text) }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.onUnavailable?(message) }
    }

    // MARK: - Audio tap

    private func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        audioLock.lock()
        activeRequest = request
        audioLock.unlock()
    }

    private func loudTimestamp() -> CFAbsoluteTime {
        audioLock.lock()
        defer { audioLock.unlock() }
        return lastLoudAt
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        audioLock.lock()
        let request = activeRequest
        audioLock.unlock()
        request?.append(buffer)

        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for index in 0..<frames {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(frames))
        let decibels = 20 * log10f(max(rms, 1e-7))
        let level = CGFloat(max(0, min(1, (decibels + 50) / 50)))

        audioLock.lock()
        if level > 0.12 { lastLoudAt = CFAbsoluteTimeGetCurrent() }
        audioLock.unlock()

        guard let onAudioLevel else { return }
        let now = CACurrentMediaTime()
        guard now - lastLevelSentAt > 0.1 else { return }
        lastLevelSentAt = now
        DispatchQueue.main.async { onAudioLevel(level) }
    }

    // MARK: - Interruptions

    @objc private func handleInterruption(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: value) else { return }

        switch type {
        case .began:
            queue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.wasRunningBeforeInterruption = true
                self.tearDown(deactivateSession: false)
            }
        case .ended:
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            queue.async { [weak self] in
                guard let self, self.wasRunningBeforeInterruption else { return }
                self.wasRunningBeforeInterruption = false
                guard options.contains(.shouldResume), self.shouldBeRunning else { return }
                self.beginRecording()
            }
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        queue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.tearDown(deactivateSession: false)
            guard self.shouldBeRunning else { return }
            self.beginRecording()
        }
    }
}
