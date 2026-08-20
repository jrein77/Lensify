//
//  ContentView.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ContentViewModel()
    @State private var isProfileViewPresented = false

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
        .onAppear {
            viewModel.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .allDataDeleted)) { _ in
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
            ARViewContainer(scanner: viewModel.scanner)
                .edgesIgnoringSafeArea(.all)

            VStack {
                if viewModel.isRenamingDocument {
                    Spacer().frame(height: 30)
                }
                if let message = viewModel.statusMessage {
                    statusBanner(message)
                }
                Spacer()
                HStack {
                    Spacer(minLength: leftPadding)
                    VStack(spacing: spacing) {
                        if viewModel.showTextBox {
                            TextCard(viewModel: viewModel)
                                .frame(width: cardWidth, height: cardHeight)
                        } else {
                            Spacer().frame(height: cardHeight)
                        }

                        CustomNavBar(
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
    }

    /// Permission and hardware problems used to fail silently; this says what
    /// went wrong without taking over the screen.
    private func statusBanner(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(Color.black.opacity(0.7))
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .transition(.opacity)
    }
}
