//
//  TextCard.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

struct TextCard: View {
    @ObservedObject var viewModel: ContentViewModel

    @State private var isEditingDocName = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerView
            contentView
        }
        .background(Color.black.opacity(0.7))
        .cornerRadius(25)
        .shadow(radius: 10)
        .onTapGesture {
            if isEditingDocName {
                finishEditingDocName()
            }
            dismissKeyboard()
        }
        .onDisappear {
            viewModel.saveNow()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showTextBox = false
                    dismissKeyboard()
                }
            }) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Circle())
            }

            Spacer()

            Group {
                if isEditingDocName {
                    TextField("", text: $viewModel.docName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .focused($isFocused)
                        .onSubmit(finishEditingDocName)
                } else {
                    Text(viewModel.docName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .onTapGesture {
                            isEditingDocName = true
                            viewModel.isRenamingDocument = true
                            isFocused = true
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.3), value: isEditingDocName)

            HStack(spacing: 5) {
                if viewModel.visualMode == "Audio" || viewModel.visualMode == "Multi" {
                    PulsatingDot(color: .green)
                }
                if viewModel.visualMode == "Visual" || viewModel.visualMode == "Multi" {
                    PulsatingDot(color: .blue)
                }

                // The PDF is rendered when the user actually picks a
                // destination, not on every keystroke as it used to be.
                ShareLink(item: CapturedTextDocument(title: viewModel.docName,
                                                     body: viewModel.documentContent()),
                          preview: SharePreview(viewModel.docName)) {
                    Text("Save")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(5)
                        .background(Color.black.opacity(0.7))
                        .clipShape(Capsule())
                }
            }

            Menu {
                Button("Visual") { withAnimation { viewModel.visualMode = "Visual" } }
                Button("Audio") { withAnimation { viewModel.visualMode = "Audio" } }
                Button("Multi") { withAnimation { viewModel.visualMode = "Multi" } }
            } label: {
                Text(viewModel.visualMode)
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(5)
                    .background(Color.black.opacity(0.7))
                    .clipShape(Capsule())
            }
        }
        .padding(10)
        .frame(height: 50)
    }

    // MARK: - Content

    private var contentView: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if viewModel.visualMode == "Visual" || viewModel.visualMode == "Multi" {
                    visualContent
                        .frame(height: viewModel.visualMode == "Multi" ? (geometry.size.height - 46) / 2 : geometry.size.height - 40)
                }

                if viewModel.visualMode == "Multi" {
                    Divider()
                        .background(Color.white)
                        .frame(height: 1)
                }

                if viewModel.visualMode == "Audio" || viewModel.visualMode == "Multi" {
                    audioContent
                        .frame(height: viewModel.visualMode == "Multi" ? (geometry.size.height - 46) / 2 : geometry.size.height - 40)
                }
            }
        }
    }

    private var visualContent: some View {
        AutoScrollView(trigger: "visual-\(viewModel.detectedSentences.count)") {
            LazyVStack(spacing: 0) {
                if viewModel.hasOmittedContent {
                    Text("Some content is omitted, but is saved to file storage")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(.vertical, 5)
                }

                ForEach(viewModel.detectedSentences) { sentence in
                    Text(sentence.text)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var audioContent: some View {
        // Partial results arrive several times a second, so this one scrolls
        // without animating.
        AutoScrollView(trigger: "audio-\(viewModel.audioTranscripts.first?.text.count ?? 0)",
                       animated: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(viewModel.audioTranscripts) { transcript in
                    Text(transcript.text)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Actions

    private func finishEditingDocName() {
        if viewModel.docName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            viewModel.docName = "Untitled"
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            isEditingDocName = false
            viewModel.isRenamingDocument = false
        }
        isFocused = false
        viewModel.saveNow()
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isFocused = false
    }
}

struct PulsatingDot: View {
    let color: Color
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(isAnimating ? 1.2 : 0.8)
            .opacity(isAnimating ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                isAnimating = true
            }
    }
}
