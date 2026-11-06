//
//  MiniPlayerView.swift
//  Yattee
//
//  Compact audio player above the tab bar.
//

import Foundation
import SwiftUI

@MainActor
struct MiniPlayerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.playerTransitionNamespace) private var playerTransitionNamespace

    static let height = CompactPlayerCard.height
    static let cornerRadius = CompactPlayerCard.cornerRadius
    static let horizontalInset: CGFloat = 20
    /// Distance from the bottom safe area to the card, clearing the floating tab bar.
    static let tabBarClearance: CGFloat = 64

    var body: some View {
        if let playerService = appEnvironment?.playerService {
            CompactPlayerCard(
                playerService: playerService,
                artworkTransitionNamespace: playerTransitionNamespace,
                actionLabel: "player.miniPlayer"
            ) {
                appEnvironment?.navigationCoordinator.expandPlayer()
            }
        }
    }
}

extension View {
    /// Reserves room above the tab bar so scrolling content isn't hidden behind the mini player.
    func miniPlayerInset(_ isVisible: Bool) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isVisible {
                Color.clear.frame(height: MiniPlayerView.height + 8)
            }
        }
    }
}
