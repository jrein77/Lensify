//
//  DocumentView.swift
//  Lensify
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

struct Document: Identifiable, Codable {
    let id: String
    var displayName: String
    let createdAt: Date
    var updatedAt: Date
    var size: Int64
    let sessionId: String
    var content: String
    var visualMode: String
    
    var url: URL {
        let fileManager = FileManager.default
        let documentDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentDirectoryURL.appendingPathComponent("\(sessionId)_\(id).json")
    }
    
    enum CodingKeys: String, CodingKey {
        case id, displayName, createdAt, updatedAt, size, sessionId, content, visualMode
    }
}

struct DocumentView: View {
    @Environment(\.presentationMode) var presentationMode
    @Binding var isPresented: Bool
    @State private var documents: [Document] = []
    @State private var isLandscape = false
    
    private let documentsFetchQueue = DispatchQueue(label: "com.spectacle.documentsFetch", qos: .background)
    
    var body: some View {
        VStack(spacing: 0) {
            if UIDevice.current.userInterfaceIdiom == .phone && isLandscape {
                // Custom grab handle for iPhone landscape
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(Color.gray)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
            }
            
            Text("Documents")
                .font(.system(size: 28, weight: .bold))
                .padding(.top, 20)
                .padding(.bottom, 20)
            
            // Documents list
            List {
                ForEach($documents) { $document in
                    DocumentRow(document: $document, onDelete: deleteDocument)
                }
            }
            .listStyle(PlainListStyle())
            
            // Delete all button
            Button(action: deleteAllDocuments) {
                Text("Delete Data")
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(Color.black)
                    .cornerRadius(10)
            }
            .padding(.vertical)
        }
        .background(Color(UIColor.systemBackground))
        .presentationDetents([.height(400), .medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            updateOrientation()
            loadDocuments()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateOrientation()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DocumentUpdated"))) { _ in
            loadDocuments()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AudioRecordingStopped"))) { notification in
            if let sessionId = notification.userInfo?["sessionId"] as? String {
                self.handleAudioTranscript(for: sessionId)
            }
        }
        .gesture(
            DragGesture()
                .onEnded { gesture in
                    if gesture.translation.height > 50 {
                        self.dismiss()
                    }
                }
        )
    }
    
    private func updateOrientation() {
        let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        isLandscape = windowScene?.interfaceOrientation.isLandscape ?? false
    }
    
    private func dismiss() {
        isPresented = false
    }
    
    private func loadDocuments() {
        documentsFetchQueue.async {
            let fileManager = FileManager.default
            let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
                let loadedDocuments = fileURLs.compactMap { fileURL -> Document? in
                    guard fileURL.pathExtension == "json" else { return nil }
                    
                    do {
                        let data = try Data(contentsOf: fileURL)
                        let document = try JSONDecoder().decode(Document.self, from: data)
                        return document
                    } catch {
                        print("Error reading document at \(fileURL): \(error)")
                        return nil
                    }
                }.sorted(by: { $0.updatedAt > $1.updatedAt })
                
                DispatchQueue.main.async {
                    self.documents = loadedDocuments
                    if self.documents.isEmpty {
                        self.createDefaultDocument()
                    }
                }
            } catch {
                print("Error loading documents: \(error)")
            }
        }
    }
    
    private func deleteDocument(_ document: Document) {
        do {
            try FileManager.default.removeItem(at: document.url)
            documents.removeAll { $0.id == document.id }
            
            // Remove associated exported files
            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let filePrefix = "\(document.sessionId)_\(document.id)"
            let enumerator = FileManager.default.enumerator(at: documentDirectory, includingPropertiesForKeys: nil)
            while let fileURL = enumerator?.nextObject() as? URL {
                if fileURL.lastPathComponent.hasPrefix(filePrefix) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            }
        } catch {
            print("Error deleting document: \(error)")
        }
    }
    
    private func createDefaultDocument() {
        let sessionId = UserDefaults.standard.string(forKey: "currentSessionId") ?? UUID().uuidString
        let currentDate = Date()
        let newDocument = Document(
            id: UUID().uuidString,
            displayName: "Untitled",
            createdAt: currentDate,
            updatedAt: currentDate,
            size: 0,
            sessionId: sessionId,
            content: "",
            visualMode: "Visual"
        )
        
        // Check if a document with this session ID already exists
        if !documents.contains(where: { $0.sessionId == sessionId }) {
            documents.append(newDocument)
            saveDocument(newDocument)
        }
    }
    
    private func saveDocument(_ document: Document) {
        do {
            let data = try JSONEncoder().encode(document)
            try data.write(to: document.url, options: .atomicWrite)
        } catch {
            print("Error saving document: \(error)")
        }
    }
    
    private func deleteAllDocuments() {
        let fileManager = FileManager.default
        let documentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: documentDirectory, includingPropertiesForKeys: nil)
            for fileURL in fileURLs {
                try fileManager.removeItem(at: fileURL)
            }
            documents.removeAll()
            
            NotificationCenter.default.post(name: NSNotification.Name("AllDataDeleted"), object: nil)
        } catch {
            print("Error deleting all documents: \(error)")
        }
    }
    
    private func handleAudioTranscript(for sessionId: String) {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptURL = documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
        
        do {
            if fileManager.fileExists(atPath: transcriptURL.path) {
                let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                
                if let index = self.documents.firstIndex(where: { $0.sessionId == sessionId }) {
                    self.documents[index].content += transcript
                    self.documents[index].updatedAt = Date()
                    self.documents[index].size = Int64(self.documents[index].content.utf8.count)
                } else {
                    let newDocument = Document(
                        id: UUID().uuidString,
                        displayName: "Session \(sessionId)",
                        createdAt: Date(),
                        updatedAt: Date(),
                        size: Int64(transcript.utf8.count),
                        sessionId: sessionId,
                        content: transcript,
                        visualMode: "Audio"
                    )
                    self.documents.append(newDocument)
                }
                
                // Delete the original transcript file
                try fileManager.removeItem(at: transcriptURL)
                
                // Save the updated document
                if let updatedDocument = self.documents.first(where: { $0.sessionId == sessionId }) {
                    self.saveDocument(updatedDocument)
                }
            }
        } catch {
            print("Error handling audio transcript: \(error)")
        }
    }
}

struct DocumentRow: View {
    @Binding var document: Document
    let onDelete: (Document) -> Void
    @State private var tempURL: URL?
    
    private let fileWritingQueue = DispatchQueue(label: "com.example.fileWritingQueue", qos: .background)
    
    var body: some View {
        HStack {
            ShareLink(item: generateDocumentURL()) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.black)
            }
            
            VStack(alignment: .leading) {
                Text(document.displayName)
                    .font(.headline)
                Text(formattedDate(document.createdAt, document.updatedAt))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
            
            Spacer()
            
            Button(action: { onDelete(document) }) {
                Text("Delete")
                    .foregroundColor(.black)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(Color.white)
                    .cornerRadius(5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.black, lineWidth: 1)
                    )
            }
            .buttonStyle(BorderlessButtonStyle())
        }
    }
    
    private func generateAndSharePDF() {
        let pdfData = generatePDFData()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(document.displayName).pdf")
        
        do {
            try pdfData.write(to: tempURL)
            self.tempURL = tempURL
            
            let activityViewController = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootViewController = windowScene.windows.first?.rootViewController {
                rootViewController.present(activityViewController, animated: true) {
                    // Clean up the temporary file after sharing
                    try? FileManager.default.removeItem(at: tempURL)
                    self.tempURL = nil
                }
            }
        } catch {
            print("Error saving PDF: \(error)")
        }
    }
    
    
    private func formattedDate(_ createdAt: Date, _ updatedAt: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd hh:mm a"
        let createdString = dateFormatter.string(from: createdAt)
        let updatedString = dateFormatter.string(from: updatedAt)
        return "Created: \(createdString)\nUpdated: \(updatedString)"
    }
    
    private func generateDocumentURL() -> URL {
        let sanitizedDisplayName = document.displayName.replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let fileName = "\(sanitizedDisplayName).pdf"
        let fileManager = FileManager.default
        let documentDirectoryURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentDirectoryURL.appendingPathComponent(fileName)
        
        fileWritingQueue.async {
            do {
                let pdfData = self.generatePDFData()
                try pdfData.write(to: fileURL, options: .atomic)
            } catch {
                print("Error writing PDF: \(error)")
            }
        }
        
        return fileURL
    }
    
    private func generatePDFData() -> Data {
        let pdfMetaData = [
            kCGPDFContextCreator: "Spectacle App",
            kCGPDFContextAuthor: "Spectacle",
            kCGPDFContextTitle: document.displayName
        ]
        
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = pdfMetaData as [String: Any]
        
        let pageWidth: CGFloat = 8.5 * 72.0
        let pageHeight: CGFloat = 11 * 72.0
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)
        
        return renderer.pdfData { (context) in
            if document.visualMode == "Visual" {
                drawVisualContent(in: context, pageRect: pageRect)
            } else if document.visualMode == "Audio" {
                drawAudioContent(in: context, pageRect: pageRect)
            } else if document.visualMode == "Multi" {
                drawMultiContent(in: context, pageRect: pageRect)
            }
        }
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
        
        let sentences = document.content.components(separatedBy: .newlines)
        
        context.beginPage()
        var leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var isLeftColumn = true
        
        for (index, sentence) in sentences.enumerated() {
            let attributedText = NSAttributedString(string: sentence, attributes: attributes)
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
            
            // Start a new page for the next sentence, but only if it's not the last sentence
            if index < sentences.count - 1 {
                context.beginPage()
                leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                isLeftColumn = true
            }
        }
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
        
        let sentences = document.content.components(separatedBy: .newlines)
        
        context.beginPage()
        var leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var isLeftColumn = true
        
        for sentence in sentences {
            let attributedText = NSAttributedString(string: sentence, attributes: attributes)
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
    }
    
    private func drawMultiContent(in context: UIGraphicsPDFRendererContext, pageRect: CGRect) {
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
        
        let sentences = document.content.components(separatedBy: .newlines)
        let midPoint = sentences.count / 2
        
        context.beginPage()
        var leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        var isLeftColumn = true
        
        // First, draw all visual content
        for (index, sentence) in sentences[..<midPoint].enumerated() {
            let attributedText = NSAttributedString(string: sentence, attributes: attributes)
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
            
            // Start a new page for the next sentence, but only if it's not the last sentence
            if index < midPoint - 1 {
                context.beginPage()
                leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
                isLeftColumn = true
            }
        }
        
        // Then, draw all audio content
        context.beginPage()
        leftTextRect = CGRect(x: 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        rightTextRect = CGRect(x: pageRect.width * 0.5 + 20, y: 20, width: pageRect.width * 0.5 - 40, height: pageRect.height - 40)
        isLeftColumn = true
        
        for transcript in sentences[midPoint...] {
            let attributedText = NSAttributedString(string: transcript, attributes: attributes)
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
        
    }
    
    enum ExportOption {
        case pdf
    }
}

struct DocumentView_Previews: PreviewProvider {
    static var previews: some View {
        DocumentView(isPresented: .constant(true))
    }
}

