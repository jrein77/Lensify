//
//  AutoScrollView.swift
//  Lensify
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct AutoScrollView<Content: View>: View {
    let content: Content
    @Binding var detectedSentences: [DetectedSentence]
    @Binding var audioTranscripts: [DetectedSentence]
    let mode: String
    
    init(@ViewBuilder content: () -> Content, detectedSentences: Binding<[DetectedSentence]>, audioTranscripts: Binding<[DetectedSentence]>, mode: String) {
        self.content = content()
        self._detectedSentences = detectedSentences
        self._audioTranscripts = audioTranscripts
        self.mode = mode
    }
    
    var body: some View {
        ScrollViewReader { scrollView in
            ScrollView {
                content
            }
            .onChange(of: detectedSentences) { oldValue, newValue in
                if mode == "Visual" || mode == "Multi" {
                    scrollToBottom(scrollView: scrollView, id: "visual_\(newValue.count - 1)")
                }
            }
            .onChange(of: audioTranscripts) { oldValue, newValue in
                if mode == "Audio" || mode == "Multi" {
                    scrollToBottom(scrollView: scrollView, id: "audio_\(newValue.count - 1)")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("AudioTranscriptUpdated"))) { _ in
                // Trigger autoscroll for audio content here
                if mode == "Audio" || mode == "Multi" {
                    scrollToBottom(scrollView: scrollView, id: "audio_\(audioTranscripts.count - 1)")
                }
            }
        }
    }

    private func scrollToBottom(scrollView: ScrollViewProxy, id: String) {
        DispatchQueue.main.async {
            withAnimation {
                scrollView.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

