//
//  DocumentView.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

struct DocumentView: View {
    @Binding var isPresented: Bool

    @State private var documents: [Document] = []
    @State private var isLandscape = false
    @State private var isConfirmingDelete = false

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

            List {
                ForEach(documents) { document in
                    DocumentRow(document: document) { deleteDocument(document) }
                }
            }
            .listStyle(PlainListStyle())

            Button(action: { isConfirmingDelete = true }) {
                Text("Delete Data")
                    .foregroundColor(.white)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(Color.black)
                    .cornerRadius(10)
            }
            .padding(.vertical)
            .confirmationDialog("Delete every saved document and transcript?",
                                isPresented: $isConfirmingDelete,
                                titleVisibility: .visible) {
                Button("Delete Everything", role: .destructive, action: deleteAllDocuments)
                Button("Cancel", role: .cancel) {}
            }
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
        .onReceive(NotificationCenter.default.publisher(for: .documentUpdated)) { _ in
            loadDocuments()
        }
    }

    private func updateOrientation() {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        isLandscape = scene?.interfaceOrientation.isLandscape ?? false
    }

    private func loadDocuments() {
        DocumentStore.loadAll { loaded in
            documents = loaded
        }
    }

    private func deleteDocument(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        DocumentStore.delete(document)
    }

    private func deleteAllDocuments() {
        documents.removeAll()
        DocumentStore.deleteAll {
            NotificationCenter.default.post(name: .allDataDeleted, object: nil)
        }
    }
}

struct DocumentRow: View {
    let document: Document
    let onDelete: () -> Void

    var body: some View {
        HStack {
            // Rendering happens inside the share sheet, so opening this list no
            // longer writes a PDF per row.
            ShareLink(item: CapturedTextDocument(title: document.displayName, body: document.content),
                      preview: SharePreview(document.displayName)) {
                Image(systemName: "square.and.arrow.down")
                    .foregroundColor(.black)
            }
            .buttonStyle(BorderlessButtonStyle())

            VStack(alignment: .leading) {
                Text(document.displayName)
                    .font(.headline)
                Text(formattedDate(document.createdAt, document.updatedAt))
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }

            Spacer()

            Button(action: onDelete) {
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

    private func formattedDate(_ createdAt: Date, _ updatedAt: Date) -> String {
        let created = Self.formatter.string(from: createdAt)
        let updated = Self.formatter.string(from: updatedAt)
        return "Created: \(created)\nUpdated: \(updated)"
    }

    /// Formatters are expensive to build; one is enough for every row.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd hh:mm a"
        return formatter
    }()
}

#Preview {
    DocumentView(isPresented: .constant(true))
}
