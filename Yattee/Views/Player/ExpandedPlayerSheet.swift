//
//  ExpandedPlayerSheet.swift
//  Yattee
//
//  The expanded audio player, shared by every playback entry point.
//

import Foundation
import SwiftUI

@MainActor
struct ExpandedPlayerSheet: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        if let appEnvironment {
            OnTheGoPanel(playerService: appEnvironment.playerService) {
                appEnvironment.navigationCoordinator.isPlayerExpanded = false
            }
            .appSheetHost(isTopLevel: true, toastScope: .player)
            .playerToastOverlay()
            .resolvedLinkPrompts(
                shouldHost: true,
                appEnvironment: appEnvironment
            )
            .accessibilityLabel(String(localized: "player.nowPlaying.title"))
            .accessibilityIdentifier("player.expandedSheet")
        }
    }
}
