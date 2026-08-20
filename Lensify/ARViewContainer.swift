//
//  ARViewContainer.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import AVFoundation
import SwiftUI
import UIKit

/// A view whose backing layer *is* the camera preview, so the preview always
/// matches the view's bounds without any manual frame or orientation bookkeeping.
final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` above guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}

/// Hosts the live camera preview and the pinch-to-zoom gesture. All of the
/// capture work itself belongs to `TextScanner`.
struct ARViewContainer: UIViewRepresentable {
    let scanner: TextScanner

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.backgroundColor = .black
        scanner.attachPreview(view.previewLayer)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        // Nothing to do: the preview layer tracks the view, and capture state is
        // driven by the view model rather than by SwiftUI updates.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(scanner: scanner)
    }

    final class Coordinator: NSObject {
        private let scanner: TextScanner
        private var zoomAtGestureStart: CGFloat = 1

        init(scanner: TextScanner) {
            self.scanner = scanner
        }

        @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                zoomAtGestureStart = scanner.zoomFactor
            case .changed:
                scanner.setZoom(zoomAtGestureStart * gesture.scale)
            default:
                break
            }
        }
    }
}
