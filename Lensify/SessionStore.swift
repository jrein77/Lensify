//
//  SessionStore.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import Foundation

/// Owns the identity of the current capture session and the transcript file
/// behind it.
///
/// Everything that touches disk runs on a private serial queue and the text is
/// mirrored in memory, so the UI never reads a file to find out what has been
/// transcribed. Finalized speech is appended to the end of the file instead of
/// rewriting the whole thing on every update.
final class SessionStore {
    static let shared = SessionStore()

    private let queue = DispatchQueue(label: "io.spectaclesystems.lensify.session", qos: .utility)
    private let defaultsKey = "currentSessionId"

    private var _sessionId: String
    private var _transcript: String = ""

    private init() {
        _sessionId = UUID().uuidString
        UserDefaults.standard.set(_sessionId, forKey: defaultsKey)
    }

    // MARK: - Session identity

    var sessionId: String {
        queue.sync { _sessionId }
    }

    @discardableResult
    func startNewSession() -> String {
        queue.sync {
            _sessionId = UUID().uuidString
            _transcript = ""
            UserDefaults.standard.set(_sessionId, forKey: defaultsKey)
            return _sessionId
        }
    }

    // MARK: - Transcript

    /// Appends a finalized chunk of speech. Callers only ever pass text that has
    /// not been written before, so there is no read-modify-write on the file.
    func appendTranscript(_ text: String) {
        let chunk = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }

        queue.async {
            self._transcript += self._transcript.isEmpty ? chunk : " " + chunk

            let url = Self.transcriptURL(for: self._sessionId)
            let data = Data((chunk + " ").utf8)

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    print("SessionStore: could not append transcript - \(error)")
                }
            } else {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    print("SessionStore: could not create transcript - \(error)")
                }
            }
        }
    }

    func clearTranscript() {
        queue.async {
            self._transcript = ""
            try? FileManager.default.removeItem(at: Self.transcriptURL(for: self._sessionId))
        }
    }

    // MARK: - Locations

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func transcriptURL(for sessionId: String) -> URL {
        documentsDirectory.appendingPathComponent("transcript_\(sessionId).txt")
    }
}
