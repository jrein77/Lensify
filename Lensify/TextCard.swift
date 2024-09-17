//
//  TextCard.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct DocumentMetadata: Codable {
    let id: String
    var displayName: String
    let sessionId: String
}

struct TextCard: View {
    @Binding var docName: String
    @Binding var visualMode: String
    @Binding var detectedSentences: [DetectedSentence]
    @Binding var audioTranscripts: [DetectedSentence]
    @Binding var audioPower: CGFloat
    @Binding var showTextBox: Bool
    @Binding var documents: [Document]
    @Binding var isRenamingDocument: Bool
    
    @State private var isEditingDocName = false
    @State private var documentID: String = UUID().uuidString
    @State private var sessionId: String = UserDefaults.standard.string(forKey: "currentSessionId") ?? UUID().uuidString
    @State private var cardOffset: CGFloat = 0
    @State private var pdfDocument: PDFDocument = PDFDocument()
    
    @FocusState private var isFocused: Bool
    
    private let fileWritingQueue = DispatchQueue(label: "com.example.fileWritingQueue", qos: .background)
    @State private var scrollViewHeight: CGFloat = 0
    private let maxScrollViewHeight: CGFloat = 200
    private let maxVisibleEntries = 1
    private let fileOperationQueue = DispatchQueue(label: "com.yourapp.fileOperations", qos: .background)
    
    enum ExportOption {
        case pdf
    }
    
    init(docName: Binding<String>, visualMode: Binding<String>, detectedSentences: Binding<[DetectedSentence]>, audioTranscripts: Binding<[DetectedSentence]>, audioPower: Binding<CGFloat>, showTextBox: Binding<Bool>, documents: Binding<[Document]>, isRenamingDocument: Binding<Bool>) {
        _docName = docName
        _visualMode = visualMode
        _detectedSentences = detectedSentences
        _audioTranscripts = audioTranscripts
        _audioPower = audioPower
        _showTextBox = showTextBox
        _documents = documents
        _isRenamingDocument = isRenamingDocument
        
        let storedSessionId = UserDefaults.standard.string(forKey: "currentSessionId") ?? UUID().uuidString
        _sessionId = State(initialValue: storedSessionId)
        print("TextCard initialized with sessionId: \(storedSessionId)")
        
        createEmptyTranscriptFileIfNeeded()
    }
    
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
            updateDocument()
        }
        .onDisappear(perform: updateDocumentDisplayName)
        .onChange(of: detectedSentences) { oldValue, newValue in
            updateDocument()
            updatePDFDocument()
        }
        
        .onChange(of: audioTranscripts) { oldValue, newValue in
            updateDocument()
            updatePDFDocument()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FinalTranscriptionReceived"))) { _ in
            self.updatePDFDocument()
        }
        .onAppear {
            let currentSessionId = UserDefaults.standard.string(forKey: "currentSessionId") ?? UUID().uuidString
            if sessionId != currentSessionId {
                sessionId = currentSessionId
                print("TextCard updated sessionId: \(sessionId)")
                createEmptyTranscriptFileIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AllDataDeleted")), perform: { _ in resetCard() })
    }
    
    private var headerView: some View {
        HStack {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showTextBox = false
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
                    TextField("", text: $docName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)
                        .focused($isFocused)
                        .onSubmit(finishEditingDocName)
                        .onChange(of: docName) { oldValue, newValue in
                            updateDocument()
                        }
                } else {
                    Text(docName)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .onTapGesture {
                            isEditingDocName = true
                            isRenamingDocument = true
                            isFocused = true
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.3), value: isEditingDocName)
            
            HStack(spacing: 5) {
                // Audio indicator
                if visualMode == "Audio" || visualMode == "Multi" {
                    PulsatingDot(color: .green)
                }
                // Visual indicator
                if visualMode == "Visual" || visualMode == "Multi" {
                    PulsatingDot(color: .blue)
                }
                
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // iPad-specific save button
                    Button(action: {
                        shareDocumentIPad()
                    }) {
                        Text("Save")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                    }
                } else {
                    // Existing iPhone save button
                    Button(action: {
                        let pdfData = generatePDFData()
                        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(docName).pdf")
                        do {
                            try pdfData.write(to: tempURL)
                            let activityViewController = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
                            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                               let rootViewController = windowScene.windows.first?.rootViewController {
                                rootViewController.present(activityViewController, animated: true, completion: nil)
                            }
                        } catch {
                            print("Error saving PDF: \(error)")
                        }
                    }) {
                        Text("Save")
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(5)
                            .background(Color.black.opacity(0.7))
                            .clipShape(Capsule())
                    }
                }
            }
            
            Menu {
                Button("Visual") { withAnimation { visualMode = "Visual" } }
                Button("Audio") { withAnimation { visualMode = "Audio" } }
                Button("Multi") { withAnimation { visualMode = "Multi" } }
            } label: {
                Text(visualMode)
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
    
    private var contentView: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if visualMode == "Visual" || visualMode == "Multi" {
                    visualContent
                        .frame(height: visualMode == "Multi" ? (geometry.size.height - 46) / 2 : geometry.size.height - 40)
                }
                
                if visualMode == "Multi" {
                    Divider()
                        .background(Color.white)
                        .frame(height: 1)
                }
                
                if visualMode == "Audio" || visualMode == "Multi" {
                    audioContent
                        .frame(height: visualMode == "Multi" ? (geometry.size.height - 46) / 2 : geometry.size.height - 40)
                }
            }
        }
    }
    
    private var visualContent: some View {
        AutoScrollView(content: {
            LazyVStack(spacing: 0) {
                if detectedSentences.count > 1 {
                    Text("Some content is omitted, but is saved to file storage")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.gray)
                        .padding(.vertical, 5)
                }
                
                ForEach(Array(detectedSentences.enumerated()), id: \.element.id) { index, sentence in
                    Text(sentence.text)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("visual_\(index)")
                }
            }
        }, detectedSentences: $detectedSentences, audioTranscripts: $audioTranscripts, mode: visualMode)
    }

    private var audioContent: some View {
        AutoScrollView(content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(audioTranscripts, id: \.id) { transcript in
                    Text(transcript.text)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }, detectedSentences: $detectedSentences, audioTranscripts: $audioTranscripts, mode: visualMode)
    }
    
    private func resetCard() {
        docName = "Untitled"
        detectedSentences.removeAll()
        audioTranscripts.removeAll()
        
        let currentDate = Date()
        let newDocument = Document(
            id: UUID().uuidString,
            displayName: docName,
            createdAt: currentDate,
            updatedAt: currentDate,
            size: 0,
            sessionId: sessionId,
            content: "",
            visualMode: visualMode
        )
        documents = [newDocument]
        saveDocument(newDocument)
        
        updateDocument()
    }
    
    
    
    private func finishEditingDocName() {
        if docName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            docName = "Untitled"
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            isEditingDocName = false
            isRenamingDocument = false
        }
        isFocused = false
        updateDocument()
    }
    
    // Add this method to handle iPad sharing
    private func shareDocumentIPad() {
        let pdfData = generatePDFData()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(docName).pdf")
        do {
            try pdfData.write(to: tempURL)
            let activityViewController = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                activityViewController.popoverPresentationController?.sourceView = rootViewController.view
                activityViewController.popoverPresentationController?.sourceRect = CGRect(x: UIScreen.main.bounds.width / 2, y: UIScreen.main.bounds.height / 2, width: 0, height: 0)
                activityViewController.popoverPresentationController?.permittedArrowDirections = []
                rootViewController.present(activityViewController, animated: true, completion: nil)
            }
        } catch {
            print("Error saving PDF: \(error)")
        }
    }
    
    private func generatePDFURL() -> URL {
        let pdfData = generatePDFData() // This calls the existing PDF generation logic
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(docName).pdf")
        do {
            try pdfData.write(to: tempURL)
            return tempURL
        } catch {
            print("Error saving PDF: \(error)")
            return tempURL // Return the URL even if saving failed, to avoid crashing
        }
    }
    
    private func generateDocumentURL(for option: ExportOption) -> URL {
        let sanitizedDisplayName = docName.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let fileName = "\(sanitizedDisplayName).pdf"
        let fileManager = FileManager.default
        let documentDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentDirectoryURL.appendingPathComponent(fileName)
        
        let metadata = DocumentMetadata(id: documentID, displayName: docName, sessionId: sessionId)
        let metadataData = try? JSONEncoder().encode(metadata)
        
        fileWritingQueue.async {
            do {
                try (metadataData ?? Data()).write(to: fileURL)
                try self.pdfDocument.dataRepresentation()?.write(to: fileURL, options: .atomic)
            } catch {
                print("Error writing PDF: \(error)")
            }
        }
        
        return fileURL
    }
    
    private func updatePDFDocument() {
        let pageRect = CGRect(x: 0, y: 0, width: 8.5 * 72.0, height: 11 * 72.0)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: UIGraphicsPDFRendererFormat())
        
        let newPDFData = renderer.pdfData { (context) in
            if visualMode == "Visual" {
                drawVisualContent(in: context, pageRect: pageRect)
            } else if visualMode == "Audio" {
                drawAudioContent(in: context, pageRect: pageRect)
            } else if visualMode == "Multi" {
                drawMultiContent(in: context, pageRect: pageRect)
            }
        }
        
        if let newPDF = PDFDocument(data: newPDFData) {
            pdfDocument = newPDF
        }
    }
    
    func urlForDocument(_ document: Document) -> URL {
        let fileManager = FileManager.default
        let documentDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDirectoryURL.appendingPathComponent("\(document.sessionId)_\(document.id).json")
    }
    
    private func generatePDFData() -> Data {
        let pdfMetaData = [
            kCGPDFContextCreator: "Spectacle App",
            kCGPDFContextAuthor: "Spectacle",
            kCGPDFContextTitle: docName
        ]
        
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        
        let pageWidth: CGFloat = 8.5 * 72.0
        let pageHeight: CGFloat = 11 * 72.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        
        let data = renderer.pdfData { (context) in
            if visualMode == "Visual" {
                drawVisualContent(in: context, pageRect: pageRect)
            } else if visualMode == "Audio" {
                drawAudioContent(in: context, pageRect: pageRect)
            } else if visualMode == "Multi" {
                drawMultiContent(in: context, pageRect: pageRect)
            }
        }
        
        return data
    }
    
    private func drawVisualContent(in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        let fontSize: CGFloat = 14
        let font = UIFont.systemFont(ofSize: fontSize)
        let textColor = UIColor.black
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        
        context.beginPage()
        var leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var isLeftColumn = true
        
        let fullText = detectedSentences.map { $0.text + "\n\n" }.joined()
        let attributedText = NSAttributedString(string: fullText, attributes: attributes)
        let frameSetter = CTFramesetterCreateWithAttributedString(attributedText)
        var currentRange = CFRangeMake(0, 0)
        
        repeat {
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: pageRect.height)
            context.cgContext.scaleBy(x: 1.0, y: -1.0)
            
            let currentRect = isLeftColumn ? leftTextRect : rightTextRect
            let flipRect = CGRect(x: currentRect.minX, y: pageRect.height - currentRect.maxY, width: currentRect.width, height: currentRect.height)
            let path = CGPath(rect: flipRect, transform: nil)
            let frame = CTFramesetterCreateFrame(frameSetter, currentRange, path, nil)
            CTFrameDraw(frame, context.cgContext)
            
            let frameRange = CTFrameGetVisibleStringRange(frame)
            currentRange = CFRangeMake(frameRange.location + frameRange.length, 0)
            
            context.cgContext.restoreGState()
            
            if currentRange.location < attributedText.length {
                if isLeftColumn {
                    isLeftColumn = false
                } else {
                    isLeftColumn = true
                    context.beginPage()
                    leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                    rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                }
            }
        } while currentRange.location < attributedText.length
    }
    
    private func drawAudioContent(in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        let fontSize: CGFloat = 14
        let font = UIFont.systemFont(ofSize: fontSize)
        let textColor = UIColor.black
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .left
        paragraphStyle.lineBreakMode = .byWordWrapping
        
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]
        
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
        
        let transcript: String
        if fileManager.fileExists(atPath: fileURL.path) {
            do {
                transcript = try String(contentsOf: fileURL, encoding: .utf8)
            } catch {
                print("Error reading transcript file: \(error)")
                transcript = "Error reading transcript"
            }
        } else {
            transcript = "No transcript file found"
        }
        
        let attributedText = NSAttributedString(string: transcript, attributes: attributes)
        let frameSetter = CTFramesetterCreateWithAttributedString(attributedText)
        var currentRange = CFRangeMake(0, 0)
        
        repeat {
            context.beginPage()
            let leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
            let rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
            var isLeftColumn = true
            
            repeat {
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: pageRect.height)
                context.cgContext.scaleBy(x: 1.0, y: -1.0)
                
                let currentRect = isLeftColumn ? leftTextRect : rightTextRect
                let flipRect = CGRect(x: currentRect.minX, y: pageRect.height - currentRect.maxY, width: currentRect.width, height: currentRect.height)
                let path = CGPath(rect: flipRect, transform: nil)
                let frame = CTFramesetterCreateFrame(frameSetter, currentRange, path, nil)
                CTFrameDraw(frame, context.cgContext)
                
                let frameRange = CTFrameGetVisibleStringRange(frame)
                currentRange = CFRangeMake(frameRange.location + frameRange.length, 0)
                
                context.cgContext.restoreGState()
                
                if currentRange.location < attributedText.length {
                    if isLeftColumn {
                        isLeftColumn = false
                    } else {
                        break
                    }
                }
            } while currentRange.location < attributedText.length
        } while currentRange.location < attributedText.length
    }
    
    private func drawMultiContent(in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
        // Draw visual content
        drawVisualContent(in: context, pageRect: pageRect)
        
        // Draw audio content
        drawAudioContent(in: context, pageRect: pageRect)
    }
    
    private func saveAudioTranscript(_ transcript: String) {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent("audio_transcript_\(sessionId).txt")
        
        do {
            try transcript.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error writing audio transcript to file: \(error)")
        }
    }
    
    private func createEmptyTranscriptFileIfNeeded() {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
        
        if !fileManager.fileExists(atPath: fileURL.path) {
            do {
                try "".write(to: fileURL, atomically: true, encoding: .utf8)
                print("Empty transcript file created at: \(fileURL.path)")
            } catch {
                print("Error creating empty transcript file: \(error)")
            }
        } else {
            print("Transcript file already exists at: \(fileURL.path)")
        }
    }
    
    private func textCardWidth() -> CGFloat {
        let deviceType = UIDevice.current.userInterfaceIdiom
        switch deviceType {
        case .pad:
            return UIScreen.main.bounds.width * 0.5
        default:
            return UIScreen.main.bounds.width - 40
        }
    }
    
    private func textCardHeight() -> CGFloat {
        let deviceType = UIDevice.current.userInterfaceIdiom
        switch deviceType {
        case .pad:
            if isFocused {
                return visualMode == "Multi" ? UIScreen.main.bounds.height * 0.4 : 200
            } else {
                return visualMode == "Multi" ? UIScreen.main.bounds.height * 0.5 : 300
            }
        default:
            if isFocused {
                return visualMode == "Multi" ? UIScreen.main.bounds.height * 0.6 - 150 : 200
            } else {
                return visualMode == "Multi" ? UIScreen.main.bounds.height * 0.6 - 100 : 300
            }
        }
    }
    
    private func updateDocumentDisplayName() {
        for index in documents.indices {
            if documents[index].sessionId == sessionId {
                documents[index].displayName = docName
                documents[index].content = generateDocumentContent()
                documents[index].size = Int64(documents[index].content.utf8.count)
            }
        }
        saveDocuments()
    }
    
    private func generateDocumentContent() -> String {
        var content = ""
        if visualMode == "Visual" || visualMode == "Multi" {
            for sentence in detectedSentences {
                content += sentence.text + "\n"
            }
        }
        if visualMode == "Audio" || visualMode == "Multi" {
            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
            
            do {
                let transcript = try String(contentsOf: fileURL, encoding: .utf8)
                content += transcript + "\n"
            } catch {
                print("Error reading transcript file: \(error)")
            }
        }
        return content
    }
    
    
    private func updateDocument() {
        let content = generateDocumentContent()
        let size = Int64(content.utf8.count)
        let currentDate = Date()
        
        if let index = documents.firstIndex(where: { $0.sessionId == sessionId }) {
            documents[index].displayName = docName
            documents[index].content = content
            documents[index].size = size
            documents[index].updatedAt = currentDate
            documents[index].visualMode = visualMode
            saveDocument(documents[index])
        } else {
            let newDocument = Document(
                id: UUID().uuidString,
                displayName: docName,
                createdAt: currentDate,
                updatedAt: currentDate,
                size: size,
                sessionId: sessionId,
                content: content,
                visualMode: visualMode
            )
            documents.append(newDocument)
            saveDocument(newDocument)
        }
        
        updatePDFDocument()
        
        // Notify ProfileView to reload documents
        NotificationCenter.default.post(name: NSNotification.Name("DocumentUpdated"), object: nil)
    }
    
    func saveDocument(_ document: Document) {
        fileOperationQueue.async {
            do {
                let data = try JSONEncoder().encode(document)
                let url = self.urlForDocument(document)
                try data.write(to: url, options: .atomicWrite)
            } catch {
                print("Error saving document: \(error)")
            }
        }
    }
    
    
    private func saveDocuments() {
        for document in documents {
            saveDocument(document)
        }
    }
    
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        isFocused = false
        updateDocument()
    }
}


struct ScrollHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
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
            .animation(Animation.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isAnimating)
            .onAppear {
                self.isAnimating = true
            }
    }
}

