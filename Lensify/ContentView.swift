//
//  ContentView.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI
import Vision
import Speech
import AVFoundation
import Combine

struct DetectedSentence: Identifiable, Equatable {
    let id = UUID()
    let speakerNumber: Int
    var text: String
    
    static func ==(lhs: DetectedSentence, rhs: DetectedSentence) -> Bool {
        return lhs.id == rhs.id
    }
}

class ContentViewModel: ObservableObject {
    @Published var showARView = false
    @Published var showDocuments = false
    @Published var showProfile = false
    @Published var showTextBox = false
    @Published var showProfileBottomSheet = false
    @Published var detectedSentences: [DetectedSentence] = []
    @Published var audioTranscripts: [DetectedSentence] = []
    @Published var docName: String = "Untitled"
    @Published var visualMode: String = "Visual"
    @Published var audioPower: CGFloat = 0.0
    @Published var documents: [Document] = []
    @Published var isRenamingDocument = false
    
    
    
    
    
    func resetContent() {
        detectedSentences.removeAll(keepingCapacity: true)
        audioTranscripts.removeAll(keepingCapacity: true)
        docName = "Untitled"
        showTextBox = false
        documents.removeAll(keepingCapacity: true)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isCameraViewReady = false
    @State private var isRenamingDocument = false
    @State private var isLoading = true
    @State private var activeSheet: ActiveSheet?
    @State private var isProfileViewPresented = false
    @State private var iPadOrientation: UIDeviceOrientation = .unknown
    @State private var zoomFactor: CGFloat = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            NavigationView {
                ZStack {
                    cameraContent(in: geometry)
                }
                .navigationBarHidden(true)
            }
            .navigationViewStyle(StackNavigationViewStyle())
            .edgesIgnoringSafeArea(.all)
        }
        .modifier(iPadRotationViewModifier(orientation: $iPadOrientation))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation {
                    isLoading = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AllDataDeleted"))) { _ in
            viewModel.resetContent()
        }
        .sheet(isPresented: $isProfileViewPresented) {
            DocumentView(isPresented: $isProfileViewPresented)
        }
    }
    
    @ViewBuilder
    private func cameraContent(in geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        
        
        let cardWidth: CGFloat = isLandscape ? (isIPad ? geometry.size.width * 0.3 : geometry.size.width * 0.4) : geometry.size.width * 0.9
        let cardHeight: CGFloat = isLandscape ? geometry.size.height * 0.8 : geometry.size.height * 0.4
        let navBarWidth: CGFloat = cardWidth * 0.70
        let spacing: CGFloat = geometry.size.height * 0.02
        
        let rightPadding: CGFloat = isLandscape ? spacing : 0
        let leftPadding: CGFloat = isLandscape ? (geometry.size.width - cardWidth - rightPadding) : (geometry.size.width - cardWidth) / 2
        
        ZStack {
            ARViewContainer(
                detectedSentences: $viewModel.detectedSentences,
                audioTranscripts: $viewModel.audioTranscripts,
                visualMode: $viewModel.visualMode,
                audioPower: $viewModel.audioPower,
                showTextBox: $viewModel.showTextBox,
                iPadOrientation: $iPadOrientation,
                zoomFactor: $zoomFactor,
                onZoomChange: { newZoom in
                                    DispatchQueue.main.async {
                                        self.zoomFactor = newZoom
                                    }
                                }
            )
            .edgesIgnoringSafeArea(.all)
            
            VStack {
                if viewModel.isRenamingDocument {
                    Spacer().frame(height: 30)
                }
                Spacer()
                HStack {
                    Spacer(minLength: leftPadding)
                    VStack(spacing: spacing) {
                        if viewModel.showTextBox {
                            TextCard(
                                docName: $viewModel.docName,
                                visualMode: $viewModel.visualMode,
                                detectedSentences: $viewModel.detectedSentences,
                                audioTranscripts: $viewModel.audioTranscripts,
                                audioPower: $viewModel.audioPower,
                                showTextBox: $viewModel.showTextBox,
                                documents: $viewModel.documents,
                                isRenamingDocument: $viewModel.isRenamingDocument
                            )
                            .frame(width: cardWidth, height: cardHeight)
                        } else {
                            Spacer().frame(height: cardHeight)
                        }
                        
                        CustomNavBar(
                            showARView: $viewModel.showARView,
                            showDocuments: $viewModel.showDocuments,
                            showTextBox: $viewModel.showTextBox,
                            isProfileViewPresented: $isProfileViewPresented
                        )
                        .frame(width: navBarWidth, height: 60)
                    }
                    .frame(width: cardWidth)
                    Spacer(minLength: rightPadding)
                }
                .padding(.bottom, spacing)
            }
            .padding(.top, isLandscape ? spacing : 0)
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .profile:
                DocumentView(isPresented: Binding(
                    get: { self.activeSheet != nil },
                    set: { if !$0 { self.activeSheet = nil } }
                ))
            }
        }
    }
}

struct iPadRotationViewModifier: ViewModifier {
    @Binding var orientation: UIDeviceOrientation
    
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                if UIDevice.current.userInterfaceIdiom == .pad {
                    orientation = UIDevice.current.orientation
                }
            }
    }
}
