//
//  CustomNavBar.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

struct CustomNavBar: View {
    @Binding var showTextBox: Bool
    @Binding var isProfileViewPresented: Bool

    var body: some View {
        HStack(spacing: 5) {
            Spacer(minLength: 5)
            NavBarButton(imageName: "arkit") {
                withAnimation(.easeInOut(duration: 0.2)) { showTextBox.toggle() }
            }
            Spacer(minLength: 5)
            NavBarButton(imageName: "folder") {
                isProfileViewPresented = true
            }
            Spacer(minLength: 5)
        }
        .background(Color.black.opacity(0.7))
        .cornerRadius(25)
        .shadow(radius: 10)
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
