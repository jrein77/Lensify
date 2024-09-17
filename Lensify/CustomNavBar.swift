//
//  CustomNavBar.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

enum ActiveSheet: Identifiable {
    case profile
    
    var id: Int {
        hashValue
    }
}

struct CustomNavBar: View {
    @Binding var showARView: Bool
    @Binding var showDocuments: Bool
    @Binding var showTextBox: Bool
    @Binding var isProfileViewPresented: Bool
    
    var body: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 5)
            NavBarButton(imageName: "arkit", action: { self.showTextBox.toggle() })
            Spacer(minLength: 5)
            NavBarButton(imageName: "folder", action: { self.isProfileViewPresented = true })
            Spacer(minLength: 5)
        }
        .background(Color.black.opacity(0.7))
        .cornerRadius(25)
        .shadow(radius: 10)
    }
    
    private func navBarWidth() -> CGFloat {
        let deviceType = UIDevice.current.userInterfaceIdiom
        switch deviceType {
        case .pad:
            return UIScreen.main.bounds.width * 0.2 // Smaller width for iPad
        default:
            return UIScreen.main.bounds.width * 0.5 // Original width for iPhone and other devices
        }
    }
}

struct NavBarButton: View {
    let imageName: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: imageName)
                .font(.title2)
                .foregroundColor(.white)
                .padding(10)
                .background(Color.black.opacity(0.7))
                .clipShape(Circle())
        }
    }
}

