//
//  DocumentStore.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import Foundation

struct Document: Identifiable, Codable, Equatable {
    let id: String
    var displayName: String
    let createdAt: Date
    var updatedAt: Date
    var size: Int64
    let sessionId: String
    var content: String
    var visualMode: String

    var url: URL {
        DocumentStore.url(forSessionId: sessionId, documentId: id)
    }
}

/// Reads and writes the saved documents. Every disk operation runs on one
/// background queue so the UI never blocks on JSON encoding or file writes.
enum DocumentStore {
    private static let queue = DispatchQueue(label: "io.spectaclesystems.lensify.documents", qos: .utility)

    static func url(forSessionId sessionId: String, documentId: String) -> URL {
        SessionStore.documentsDirectory.appendingPathComponent("\(sessionId)_\(documentId).json")
    }

    static func save(_ document: Document) {
        queue.async {
            do {
                let data = try JSONEncoder().encode(document)
                try data.write(to: document.url, options: .atomic)
            } catch {
                print("DocumentStore: could not save document - \(error)")
            }
        }
    }

    static func loadAll(completion: @escaping ([Document]) -> Void) {
        queue.async {
            let directory = SessionStore.documentsDirectory
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
            let decoder = JSONDecoder()
            let documents = urls
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> Document? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? decoder.decode(Document.self, from: data)
                }
                .sorted { $0.updatedAt > $1.updatedAt }

            DispatchQueue.main.async { completion(documents) }
        }
    }

    static func delete(_ document: Document) {
        queue.async {
            let manager = FileManager.default
            try? manager.removeItem(at: document.url)
            try? manager.removeItem(at: SessionStore.transcriptURL(for: document.sessionId))
        }
    }

    /// Removes everything Lensify has written: documents, transcripts and any
    /// exported PDFs left behind by the share sheet.
    static func deleteAll(completion: @escaping () -> Void) {
        queue.async {
            let manager = FileManager.default
            let directory = SessionStore.documentsDirectory
            let urls = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []

            for url in urls where ["json", "txt", "pdf"].contains(url.pathExtension) {
                try? manager.removeItem(at: url)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }
}
