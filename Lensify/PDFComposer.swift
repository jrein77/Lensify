//
//  PDFComposer.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// Lays captured text out into a two-column PDF.
///
/// This replaces four near-identical copies of the same Core Text pagination
/// loop. Those copies could also spin forever when a column had room for zero
/// characters; this one stops instead.
enum PDFComposer {
    private static let pageSize = CGSize(width: 8.5 * 72, height: 11 * 72)
    private static let margin: CGFloat = 20
    private static let maximumPages = 400

    static func makePDF(title: String, body: String) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Lensify",
            kCGPDFContextAuthor as String: "Spectacle Systems",
            kCGPDFContextTitle as String: title
        ]

        let pageRect = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: format)

        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributed = NSAttributedString(string: text.isEmpty ? "No content captured yet." : text,
                                            attributes: attributes())
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let columns = columnRects(in: pageRect)

        return renderer.pdfData { context in
            var location = 0
            var pages = 0

            repeat {
                context.beginPage()
                pages += 1

                for column in columns {
                    guard location < attributed.length else { break }
                    let drawn = draw(framesetter: framesetter,
                                     from: location,
                                     in: column,
                                     pageRect: pageRect,
                                     context: context)
                    // Nothing fit: stop rather than emitting pages forever.
                    guard drawn > 0 else {
                        location = attributed.length
                        break
                    }
                    location += drawn
                }
            } while location < attributed.length && pages < maximumPages
        }
    }

    private static func attributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping

        return [
            .font: UIFont.systemFont(ofSize: 14),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
    }

    private static func columnRects(in pageRect: CGRect) -> [CGRect] {
        let columnWidth = pageRect.width * 0.5 - margin * 2
        let height = pageRect.height - margin * 2
        return [
            CGRect(x: margin, y: margin, width: columnWidth, height: height),
            CGRect(x: pageRect.width * 0.5 + margin, y: margin, width: columnWidth, height: height)
        ]
    }

    /// Draws as much text as fits and returns how many characters were used.
    private static func draw(framesetter: CTFramesetter,
                             from location: Int,
                             in rect: CGRect,
                             pageRect: CGRect,
                             context: UIGraphicsPDFRendererContext) -> Int {
        let cgContext = context.cgContext
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: pageRect.height)
        cgContext.scaleBy(x: 1, y: -1)

        let flipped = CGRect(x: rect.minX,
                             y: pageRect.height - rect.maxY,
                             width: rect.width,
                             height: rect.height)
        let path = CGPath(rect: flipped, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(location, 0), path, nil)
        CTFrameDraw(frame, cgContext)

        cgContext.restoreGState()
        return CTFrameGetVisibleStringRange(frame).length
    }
}

/// A captured document offered to the share sheet. The PDF is only rendered
/// once the user picks somewhere to send it.
struct CapturedTextDocument: Transferable {
    let title: String
    let body: String

    var fileName: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return (cleaned.isEmpty ? "Lensify" : cleaned) + ".pdf"
    }

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { document in
            PDFComposer.makePDF(title: document.title, body: document.body)
        }
        .suggestedFileName { $0.fileName }
    }
}
