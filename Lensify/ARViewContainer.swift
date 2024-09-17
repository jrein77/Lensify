//
//  ARViewContainer.swift
//  Lensify
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI
import AVFoundation
import Vision
import Speech

extension Notification.Name {
    static let scrollToBottom = Notification.Name("scrollToBottom")
}

public struct ARViewContainer: UIViewRepresentable {
    @Binding var detectedSentences: [DetectedSentence]
    @Binding var audioTranscripts: [DetectedSentence]
    @Binding var visualMode: String
    @Binding var audioPower: CGFloat
    @Binding var showTextBox: Bool
    @Binding var iPadOrientation: UIDeviceOrientation
    @Binding var zoomFactor: CGFloat
        var onZoomChange: ((CGFloat) -> Void)?
    @State private var sessionId: String = UserDefaults.standard.string(forKey: "currentSessionId") ?? UUID().uuidString
    
    public func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: UIScreen.main.bounds)
        context.coordinator.setupCamera(view: view)
        
        // Add pinch gesture recognizer for zoom
        let pinchGesture = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handlePinchGesture(_:)))
        view.addGestureRecognizer(pinchGesture)
        
        return view
    }
    
    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.updateMode(visualMode: visualMode)
        context.coordinator.updateViewFrame(uiView)
        if UIDevice.current.userInterfaceIdiom == .pad {
            context.coordinator.updateiPadOrientation(iPadOrientation)
        }
        context.coordinator.updateZoom(zoomFactor)
    }
    

        public func makeCoordinator() -> Coordinator {
            Coordinator(parent: self, audioPower: $audioPower, showTextBox: $showTextBox, onZoomChange: { newZoom in
                self.onZoomChange?(newZoom)
            })
        }
    
    public class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, SFSpeechRecognizerDelegate {
        var parent: ARViewContainer
        var captureSession: AVCaptureSession?
        var previewLayer: AVCaptureVideoPreviewLayer?
        var visionRequests = [VNRequest]()
        let visionQueue = DispatchQueue(label: "com.example.visionQueue")
        private var lastProcessedTimestamp: TimeInterval = 0
        var currentZoomFactor: CGFloat = 1.0
        private let minZoomFactor: CGFloat = 1.0
        private let maxZoomFactor: CGFloat = 5.0
        private let processInterval: TimeInterval = 1.0
        var isRecording = false
        @Binding var audioPower: CGFloat
        @Binding var showTextBox: Bool
        private var lastTranscript: String = ""
        private var lastSuccessfulRecognitionTime: Date = Date()
        private let restartThreshold: TimeInterval = 10
        private var currentTranscript: String = ""
        private var isFinalTranscript: Bool = false
        private let textProcessingQueue = DispatchQueue(label: "com.example.textProcessingQueue")
        private var frameCounter = 0
        private let frameSkipInterval = 300
        private var previousDetectedText: String = ""
        private let textSimilarityThreshold: Double = 0.7
        private var currentSpeechRequest: SFSpeechAudioBufferRecognitionRequest?
        private var audioEngine: AVAudioEngine!
        private var speechRecognizer: SpeechRecognizer?
        private var fullTranscript: String = ""
        private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
        private var recognitionTask: SFSpeechRecognitionTask?
        private var latestTranscript: String = ""
        private var saveTimer: Timer?
        private let savingInterval: TimeInterval = 5 // Save every 5 seconds
        private var onZoomChange: ((CGFloat) -> Void)?

        init(parent: ARViewContainer, audioPower: Binding<CGFloat>, showTextBox: Binding<Bool>, onZoomChange: @escaping (CGFloat) -> Void) {
            self.parent = parent
            self._audioPower = audioPower
            self._showTextBox = showTextBox
            self.onZoomChange = onZoomChange
            self.speechRecognizer = SpeechRecognizer()
            super.init()
            setupVision()
            NotificationCenter.default.addObserver(self, selector: #selector(orientationChanged), name: UIDevice.orientationDidChangeNotification, object: nil)
        }
        
        @objc func orientationChanged() {
            if let view = self.previewLayer?.superlayer as? UIView {
                self.updateViewFrame(view)
            }
        }
        
        func updateiPadOrientation(_ orientation: UIDeviceOrientation) {
            if UIDevice.current.userInterfaceIdiom == .pad, let connection = self.previewLayer?.connection {
                let previewLayerConnection : AVCaptureConnection = connection
                
                if previewLayerConnection.isVideoOrientationSupported {
                    switch orientation {
                    case .portrait: previewLayerConnection.videoOrientation = .portrait
                    case .landscapeRight: previewLayerConnection.videoOrientation = .landscapeLeft
                    case .landscapeLeft: previewLayerConnection.videoOrientation = .landscapeRight
                    case .portraitUpsideDown: previewLayerConnection.videoOrientation = .portraitUpsideDown
                    default: previewLayerConnection.videoOrientation = .portrait
                    }
                }
            }
        }
        

        func setupCamera(view: UIView) {
            let captureSession = AVCaptureSession()
            guard let captureDevice = AVCaptureDevice.default(for: .video) else { return }
            guard let input = try? AVCaptureDeviceInput(device: captureDevice) else { return }
            
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            let output = AVCaptureVideoDataOutput()
            output.setSampleBufferDelegate(self, queue: self.visionQueue)
            if captureSession.canAddOutput(output) {
                captureSession.addOutput(output)
            }
            
            self.captureSession = captureSession
            
            DispatchQueue.main.async {
                let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
                previewLayer.frame = view.bounds
                previewLayer.videoGravity = .resizeAspectFill
                view.layer.addSublayer(previewLayer)
                
                self.previewLayer = previewLayer
                
                // Move captureSession.startRunning() to a background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    captureSession.startRunning()
                }
            }
        }
        
        private func startPeriodicSaving() {
            saveTimer = Timer.scheduledTimer(withTimeInterval: savingInterval, repeats: true) { [weak self] _ in
                self?.saveCurrentTranscript()
            }
        }
        
        private func stopPeriodicSaving() {
            saveTimer?.invalidate()
            saveTimer = nil
        }
        
        private func saveCurrentTranscript() {
            guard let currentTranscript = parent.audioTranscripts.last?.text, !currentTranscript.isEmpty else { return }
            
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
            
            do {
                var fullTranscript: String
                if fileManager.fileExists(atPath: fileURL.path) {
                    fullTranscript = try String(contentsOf: fileURL, encoding: .utf8)
                } else {
                    fullTranscript = ""
                }
                
                // Append the current transcript if it's not already in the file
                if !fullTranscript.contains(currentTranscript) {
                    fullTranscript += currentTranscript + " "
                    try fullTranscript.write(to: fileURL, atomically: true, encoding: .utf8)
                    print("Updated full transcript written to file: \(fullTranscript)")
                }
            } catch {
                print("Error writing transcript to file: \(error)")
            }
        }
        
        func setupVision() {
            let textRequest = VNRecognizeTextRequest { [weak self] request, error in
                guard let self = self else { return }
                self.processDetectedText(request: request, error: error)
            }
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            self.visionRequests = [textRequest]
        }
        
        func processDetectedText(request: VNRequest, error: Error?) {
            guard let observations = request.results as? [VNRecognizedTextObservation] else { return }
            
            let confidenceThreshold: Float = 0.85 // Adjust this value as needed
            
            let newText = observations.compactMap { observation -> String? in
                guard let candidate = observation.topCandidates(1).first,
                      candidate.confidence >= confidenceThreshold else {
                    return nil
                }
                return candidate.string
            }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            
            guard !newText.isEmpty else { return }
            
            let similarity = calculateTextSimilarity(newText, previousDetectedText)
            let similarityThreshold = 0.95 // Adjust this value as needed
            
            guard similarity < similarityThreshold else { return }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.parent.detectedSentences.append(DetectedSentence(speakerNumber: 0, text: newText))
                NotificationCenter.default.post(name: .scrollToBottom, object: nil)
                self.previousDetectedText = newText
            }
        }
        
        func preprocessImage(_ image: CIImage) -> CIImage {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(image, forKey: kCIInputImageKey)
            filter?.setValue(1.1, forKey: kCIInputContrastKey)
            filter?.setValue(0.1, forKey: kCIInputBrightnessKey)
            
            return filter?.outputImage ?? image
        }
        
        
        func startAudioRecording() {
            guard !isRecording else { return }
            isRecording = true
            
            // Save any remaining transcript before clearing
            saveCurrentTranscript()
            
            // Clear the UI transcript and current transcript
            DispatchQueue.main.async { [weak self] in
                self?.parent.audioTranscripts.removeAll()
                self?.currentTranscript = ""
                self?.isFinalTranscript = false
            }
            
            speechRecognizer = SpeechRecognizer()
            speechRecognizer?.startRecording { [weak self] transcribedText, isFinal in
                self?.handleRecognizedSpeech(text: transcribedText, isFinal: isFinal)
            }
            
            startPeriodicSaving()
        }
        
        
        func stopAudioRecording() {
            guard isRecording else { return }
            isRecording = false
            
            // Save any remaining transcript before stopping
            saveCurrentTranscript()
            
            stopPeriodicSaving()
            
            speechRecognizer?.stopRecording()
            speechRecognizer = nil
            
            // Notify that the audio recording has stopped
            NotificationCenter.default.post(name: NSNotification.Name("AudioRecordingStopped"), object: nil, userInfo: ["sessionId": sessionId])
        }
        
        private func startContinuousSpeechRecognition() throws {
            currentSpeechRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = currentSpeechRequest else {
                throw NSError(domain: "SpeechRecognizerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            let inputNode = audioEngine.inputNode
            
            inputNode.removeTap(onBus: 0)
            
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                self?.currentSpeechRequest?.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            // Start a timer to check for long periods of inactivity
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.checkAndRestartIfNeeded()
            }
        }
        
        func updateViewFrame(_ view: UIView) {
            DispatchQueue.main.async {
                self.previewLayer?.frame = view.bounds
                self.previewLayer?.connection?.videoOrientation = self.getCurrentVideoOrientation()
            }
        }
        
        private func getCurrentVideoOrientation() -> AVCaptureVideoOrientation {
            switch UIDevice.current.orientation {
            case .portrait: return .portrait
            case .portraitUpsideDown: return .portraitUpsideDown
            case .landscapeLeft: return .landscapeRight
            case .landscapeRight: return .landscapeLeft
            default: return .portrait
            }
        }
        
        @MainActor
        func updateMode(visualMode: String) {
            switch visualMode {
            case "Visual":
                setupVision()
                stopAudioRecording()
            case "Audio", "Multi":
                if !isRecording {
                    startAudioRecording()
                }
                if visualMode == "Multi" {
                    setupVision()
                }
            default:
                break
            }
        }
        
        public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            frameCounter += 1
            if frameCounter % frameSkipInterval != 0 {
                return
            }
            
            let currentTimestamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1000).seconds
            guard currentTimestamp - lastProcessedTimestamp >= processInterval else { return }
            lastProcessedTimestamp = currentTimestamp
            
            guard parent.visualMode == "Visual" || parent.visualMode == "Multi" else { return }
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            
                // Create a CIImage from the pixel buffer
            var ciImage = CIImage(cvPixelBuffer: pixelBuffer)
                
                // Preprocess the image
            ciImage = preprocessImage(ciImage)
            
            // Create a temporary UIImage
            let context = CIContext(options: nil)
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
            let uiImage = UIImage(cgImage: cgImage)
            
            // Perform text recognition on the UIImage
            guard let cgImage = uiImage.cgImage else { return }
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, orientation: .right, options: [:])
            
            let request = VNRecognizeTextRequest { [weak self] request, error in
                self?.processDetectedText(request: request, error: error)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            do {
                try requestHandler.perform([request])
            } catch {
                print("Failed to perform text recognition: \(error)")
            }
        }
        
        private func calculateTextSimilarity(_ text1: String, _ text2: String) -> Double {
            let set1 = Set(text1.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let set2 = Set(text2.lowercased().components(separatedBy: .whitespacesAndNewlines))
            let intersection = set1.intersection(set2)
            let union = set1.union(set2)
            return Double(intersection.count) / Double(union.count)
        }
        
        private func handleRecognizedSpeech(text: String, isFinal: Bool) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                print("Received speech: \(text), isFinal: \(isFinal)")
                
                self.currentTranscript = text
                self.isFinalTranscript = isFinal
                
                // Update UI transcript
                if self.parent.audioTranscripts.isEmpty {
                    self.parent.audioTranscripts.append(DetectedSentence(speakerNumber: 0, text: text))
                } else {
                    self.parent.audioTranscripts[0].text = text
                }
                
                print("Current UI transcript: \(self.parent.audioTranscripts[0].text)")
                
                NotificationCenter.default.post(name: .scrollToBottom, object: nil)
                
                if isFinal {
                    self.saveCurrentTranscript()
                    NotificationCenter.default.post(name: NSNotification.Name("FinalTranscriptionReceived"), object: nil)
                }
            }
        }
        
        private var sessionId: String {
            return parent.sessionId
        }
        
        private func checkAndRestartIfNeeded() {
            let currentTime = Date()
            if currentTime.timeIntervalSince(lastSuccessfulRecognitionTime) > restartThreshold {
                print("No successful recognition for a while. Restarting speech recognition...")
                restartSpeechRecognition()
            }
        }
        
        private func restartSpeechRecognition() {
            stopAudioRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startAudioRecording()
            }
        }
        
        private func startRecognition() throws {
            // Cancel the previous task if it's running.
            recognitionTask?.cancel()
            recognitionTask = nil
            
            // Configure the audio session for the app
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                throw NSError(domain: "SpeechRecognizerError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
            }
            
            recognitionRequest.shouldReportPartialResults = true
            
            // Configure the microphone input
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
                self.recognitionRequest?.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
        }
        
        
        private func restartRecognition() {
            do {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
                recognitionRequest = nil
                recognitionTask = nil
                try startRecognition()
            } catch {
                print("Failed to restart recognition: \(error)")
            }
        }
        
        private func updateTranscript(_ newText: String) {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                
                self.latestTranscript = newText
                if self.parent.audioTranscripts.isEmpty {
                    self.parent.audioTranscripts.append(DetectedSentence(speakerNumber: 0, text: newText))
                } else {
                    self.parent.audioTranscripts[0].text = newText
                }
                NotificationCenter.default.post(name: .scrollToBottom, object: nil)
            }
        }
        
        private func handleSpeechRecognitionError(_ error: Error) {
            print("Speech recognition error: \(error)")
            
            stopAudioRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startAudioRecording()
            }
        }
        
        deinit {
            stopAudioRecording()
        }
    }
}

public class SpeechRecognizer {
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    
    private var onSpeech: ((String, Bool) -> Void)?
    private var fullTranscript: String = ""
    private var restartTimer: Timer?
    private let restartInterval: TimeInterval = 10
    
    init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        setupRestartTimer()
    }
    
    func startRecording(to speech: @escaping (String, Bool) -> Void) {
        self.onSpeech = speech
        startContinuousRecognition()
    }
    
    private func setupRestartTimer() {
        restartTimer = Timer.scheduledTimer(withTimeInterval: restartInterval, repeats: true) { [weak self] _ in
            self?.restartRecognition()
        }
    }
    
    private func startContinuousRecognition() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            guard let self = self else { return }
            OperationQueue.main.addOperation {
                switch authStatus {
                case .authorized:
                    do {
                        try self.startRecognition()
                    } catch {
                        print("Recognition start error: \(error)")
                    }
                case .denied:
                    print("Speech recognition authorization denied")
                case .restricted:
                    print("Speech recognition not available on this device")
                case .notDetermined:
                    print("Speech recognition not yet authorized")
                @unknown default:
                    print("Unknown authorization status")
                }
            }
        }
    }
    
    private func startRecognition() throws {
        // Ensure previous task is canceled and audio engine is stopped
        stopRecording()
        
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        self.recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        
        guard let recognitionRequest = recognitionRequest else {
            throw NSError(domain: "SpeechRecognizerErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create recognition request"])
        }
        
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false
        
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            self?.recognitionRequest?.append(buffer)
        }
        
        audioEngine.prepare()
        
        do {
            try audioEngine.start()
        } catch {
            throw error
        }
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self, let result = result else { return }
            
            let transcribedString = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            
            self.onSpeech?(transcribedString, isFinal)
            
            if error != nil || isFinal {
                self.restartRecognition()
            }
        }
    }
    
    private func restartRecognition() {
        DispatchQueue.main.async { [weak self] in
            self?.stopRecording()
            self?.startContinuousRecognition()
        }
    }
    
    func stopRecording() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        
        recognitionRequest = nil
        recognitionTask = nil
    }
    
    deinit {
        restartTimer?.invalidate()
        stopRecording()
    }
}

extension ARViewContainer.Coordinator {
    func updateZoom(_ zoomFactor: CGFloat) {
        let newZoomFactor = min(max(zoomFactor, minZoomFactor), maxZoomFactor)
        
        guard let captureDevice = self.captureSession?.inputs.first as? AVCaptureDeviceInput else { return }
        
        do {
            try captureDevice.device.lockForConfiguration()
            captureDevice.device.videoZoomFactor = newZoomFactor
            captureDevice.device.unlockForConfiguration()
            self.currentZoomFactor = newZoomFactor
            self.onZoomChange?(newZoomFactor)
        } catch {
            print("Error setting zoom: \(error.localizedDescription)")
        }
    }
}

extension ARViewContainer.Coordinator {
    @objc func handlePinchGesture(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .changed {
            let newZoomFactor = currentZoomFactor * gesture.scale
            updateZoom(newZoomFactor)
            gesture.scale = 1.0
        }
    }
}
