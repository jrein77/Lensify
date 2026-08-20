//
//  AutoScrollView.swift
//  Lensify
//  Property of Spectacle Systems, LLC.
//
//  Created by Jake Reinhart on 7/7/24.
//

import SwiftUI

/// A scroll view that keeps its tail in view as content arrives.
///
/// It scrolls to a marker pinned below the content instead of guessing at the
/// identifier of the last row, so it cannot miss when rows are trimmed.
struct AutoScrollView<Content: View>: View {
    private let bottomId = "auto-scroll-bottom"

    let trigger: String
    let animated: Bool
    @ViewBuilder let content: () -> Content

    init(trigger: String, animated: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.trigger = trigger
        self.animated = animated
        self.content = content
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content()
                Color.clear
                    .frame(height: 1)
                    .id(bottomId)
            }
            .onChange(of: trigger) { _, _ in
                scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard animated else {
            proxy.scrollTo(bottomId, anchor: .bottom)
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(bottomId, anchor: .bottom)
        }
    }
}
