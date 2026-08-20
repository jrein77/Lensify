//
//  ContentViewModel.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import Combine
import SwiftUI
import UIKit

struct DetectedSentence: Identifiable, Equatable {
    let id: UUID
    let speakerNumber: Int
    var text: String

    init(id: UUID = UUID(), speakerNumber: Int, text: String) {
        self.id = id
        self.speakerNumber = speakerNumber
        self.text = text
    }
}

/// The single owner of capture state.
///
/// The camera and the recognizers live here rather than inside a SwiftUI view,
/// so redrawing the interface no longer tears down and rebuilds the pipeline.
final class ContentViewModel: ObservableObject {

    // Interface state
    @Published var showTextBox = false
    @Published var isRenamingDocument = false
    @Published var docName = "Untitled"
    @Published var statusMessage: String?

    // Capture state
    @Published var visualMode: String = "Visual" {
        didSet {
            guard oldValue != visualMode else { return }
            applyMode()
            refreshSnapshot()
            scheduleSave()
        }
    }
    @Published var detectedSentences: [DetectedSentence] = []
    @Published var audioTranscripts: [DetectedSentence] = []
    /// True once older captured lines have scrolled out of memory and live only in the file.
    @Published private(set) var hasOmittedContent = false

    let scanner = TextScanner()
    private let transcriber = SpeechTranscriber()

    private var hasStarted = false
    private var audioActive = false
    private var saveWorkItem: DispatchWorkItem?
    private var document: Document
    private let audioLineId = UUID()

    /// Everything read off the camera this session, including lines no longer on screen.
    private var visualTranscript = ""
    /// Everything the recognizer has committed this session.
    private var audioTranscript = ""
    /// The two above, joined for the current mode.
    private var contentSnapshot = ""

    private let maximumVisibleLines = 120
    private let maximumStoredCharacters = 400_000
    private let liveAudioWindow = 1_200

    init() {
        let now = Date()
        document = Document(id: UUID().uuidString,
                            displayName: "Untitled",
                            createdAt: now,
                            updatedAt: now,
                            size: 0,
                            sessionId: SessionStore.shared.sessionId,
                            content: "",
                            visualMode: "Visual")

        wireScanner()
        wireTranscriber()
        observeLifecycle()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        statusMessage = nil
        scanner.start()
        applyMode()
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(handleForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func handleBackground() {
        guard hasStarted else { return }
        scanner.stop()
        stopAudio()
        saveNow()
    }

    @objc private func handleForeground() {
        guard hasStarted else { return }
        // Permissions may have been granted while the app was away.
        statusMessage = nil
        scanner.start()
        applyMode()
    }

    private func applyMode() {
        let wantsVisual = visualMode == "Visual" || visualMode == "Multi"
        let wantsAudio = visualMode == "Audio" || visualMode == "Multi"

        scanner.setRecognitionEnabled(wantsVisual)

        if wantsAudio {
            guard !audioActive else { return }
            audioActive = true
            transcriber.start()
        } else {
            stopAudio()
        }
    }

    private func stopAudio() {
        guard audioActive else { return }
        audioActive = false
        transcriber.stop()
    }

    // MARK: - Wiring

    private func wireScanner() {
        scanner.onText = { [weak self] lines in
            self?.appendDetected(lines)
        }
        scanner.onUnavailable = { [weak self] message in
            self?.statusMessage = message
        }
    }

    private func wireTranscriber() {
        transcriber.onTranscript = { [weak self] text in
            self?.updateLiveTranscript(text)
        }
        transcriber.onSegmentFinalized = { [weak self] segment in
            guard let self else { return }
            SessionStore.shared.appendTranscript(segment)
            self.audioTranscript += self.audioTranscript.isEmpty ? segment : " " + segment
            self.trimStoredText()
            self.refreshSnapshot()
            self.scheduleSave()
        }
        transcriber.onUnavailable = { [weak self] message in
            self?.statusMessage = message
        }
    }

    // MARK: - Capture results

    private func appendDetected(_ lines: [String]) {
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty else { return }

        detectedSentences.append(DetectedSentence(speakerNumber: 0, text: text))
        if detectedSentences.count > maximumVisibleLines {
            detectedSentences.removeFirst(detectedSentences.count - maximumVisibleLines)
            hasOmittedContent = true
        }

        visualTranscript += visualTranscript.isEmpty ? text : "\n" + text
        trimStoredText()
        refreshSnapshot()
        scheduleSave()
    }

    private func updateLiveTranscript(_ text: String) {
        // The card shows a trailing window; the whole thing is on disk.
        let window = text.count > liveAudioWindow
            ? String(text.suffix(liveAudioWindow))
            : text

        if audioTranscripts.isEmpty {
            audioTranscripts = [DetectedSentence(id: audioLineId, speakerNumber: 0, text: window)]
        } else if audioTranscripts[0].text != window {
            audioTranscripts[0].text = window
        }
    }

    private func trimStoredText() {
        if visualTranscript.count > maximumStoredCharacters {
            visualTranscript = String(visualTranscript.suffix(maximumStoredCharacters))
            hasOmittedContent = true
        }
        if audioTranscript.count > maximumStoredCharacters {
            audioTranscript = String(audioTranscript.suffix(maximumStoredCharacters))
            hasOmittedContent = true
        }
    }

    // MARK: - Document

    /// The text that gets saved and exported for the current mode.
    ///
    /// Kept as a snapshot rather than rebuilt on demand, because the share
    /// button asks for it on every redraw and redraws happen constantly while
    /// text is coming in.
    func documentContent() -> String {
        contentSnapshot
    }

    private func refreshSnapshot() {
        var parts: [String] = []
        if visualMode == "Visual" || visualMode == "Multi", !visualTranscript.isEmpty {
            parts.append(visualTranscript)
        }
        if visualMode == "Audio" || visualMode == "Multi", !audioTranscript.isEmpty {
            parts.append(audioTranscript)
        }
        contentSnapshot = parts.joined(separator: "\n\n")
    }

    /// Coalesces the flood of updates a live capture produces into one write
    /// every couple of seconds.
    func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        let content = documentContent()
        document.displayName = docName
        document.content = content
        document.size = Int64(content.utf8.count)
        document.updatedAt = Date()
        document.visualMode = visualMode

        DocumentStore.save(document)
        NotificationCenter.default.post(name: .documentUpdated, object: nil)
    }

    func resetContent() {
        detectedSentences.removeAll()
        audioTranscripts.removeAll()
        visualTranscript = ""
        audioTranscript = ""
        contentSnapshot = ""
        hasOmittedContent = false
        docName = "Untitled"
        showTextBox = false
        statusMessage = nil

        transcriber.reset()
        scanner.resetHistory()
        SessionStore.shared.clearTranscript()

        let sessionId = SessionStore.shared.startNewSession()
        let now = Date()
        document = Document(id: UUID().uuidString,
                            displayName: docName,
                            createdAt: now,
                            updatedAt: now,
                            size: 0,
                            sessionId: sessionId,
                            content: "",
                            visualMode: visualMode)
        saveNow()
    }
}

extension Notification.Name {
    static let documentUpdated = Notification.Name("DocumentUpdated")
    static let allDataDeleted = Notification.Name("AllDataDeleted")
}
