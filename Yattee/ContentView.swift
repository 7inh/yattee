//
//  ContentView.swift
//  Yattee
//
//  Root content view with tab-based navigation.
//

import SwiftUI

struct ContentView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        let _ = PerfCounter.body("ContentView")
        Group {
            if let appEnvironment {
                AdaptiveTabView(appEnvironment: appEnvironment)
            } else {
                ProgressView(String(localized: "common.loading"))
            }
        }
        // Shared sheets for the main window. The expanded player hosts its own,
        // and takes global requests while it is up.
        .appSheetHost(
            isTopLevel: appEnvironment?.navigationCoordinator.isPlayerExpanded != true,
            dismissesOnExternalNavigation: true,
            toastScope: .main
        )
        .toastOverlay()
    }

    // MARK: - Unified Content View (macOS 15+, tvOS 18+)

    @ViewBuilder
    private func unifiedContentView(appEnvironment: AppEnvironment) -> some View {
        ZStack(alignment: .bottom) {

            // Mini player overlay (macOS only)
        }
    }


}

// MARK: - Adaptive Tab View

/// Switches between CompactTabView and UnifiedTabView based on horizontal size class.
/// Compact width (iPhone, iPad Stage Manager small): CompactTabView with settings-based customization
/// Regular width (iPad full, iPad larger windows): UnifiedTabView with sidebar adaptable
/// Both render `NavigationRouter` state, so swapping between them keeps the
/// selection and every stack.
struct AdaptiveTabView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    let appEnvironment: AppEnvironment


    /// Whether to show the black overlay that covers scaled content when player is expanded
    private var shouldShowExpandedOverlay: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show overlay only when:
        // - Player window is actually visible (not just isPlayerExpanded intent)
        // - Expand animation has completed (not animating)
        // - Dismiss gesture is not active (so user can see scaled content during drag)
        return nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating && !nav.isPlayerDismissGestureActive
    }

    /// Whether to show loading spinner while waiting for player window to appear
    private var shouldShowExpandPendingSpinner: Bool {
        let nav = appEnvironment.navigationCoordinator
        // Show spinner when expand is requested but window isn't visible yet
        // (a gesture dismiss hides the window before un-expanding — not pending)
        return nav.isPlayerExpanded && !nav.isPlayerWindowVisible && !nav.isPlayerSheetAnimating
            && !nav.isPlayerCollapsing && !nav.isPlayerMorphingToMini
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !usesSidebar {
                CompactTabView(router: appEnvironment.navigationCoordinator.router)
                    .environment(appEnvironment.settingsManager)
            } else {
                UnifiedTabView(router: appEnvironment.navigationCoordinator.router)
                .environment(appEnvironment.settingsManager)
            }

            // The tab bar layout on iOS 26.1+ shows the mini player as the tab
            // bar's bottom accessory; the split-view sidebar layout insets it
            // into its detail column.
            if !usesSidebar && !Self.usesTabBottomAccessory {
                miniPlayerOverlay
            }

            // Black overlay when player is fully expanded
            // Hides scaled content behind player sheet, removed during dismiss gesture for parallax effect
            if shouldShowExpandedOverlay {
                Color.black
                    .ignoresSafeArea()
                    .transaction { $0.animation = nil }
            }

            // Loading spinner when expand is pending but window not yet visible
            // This handles the case when scene is transitioning (e.g., Control Center)
            if shouldShowExpandPendingSpinner {
                ZStack {
                    Color.black.opacity(0.7)
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
                .ignoresSafeArea()
                .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        .onChange(of: appEnvironment.navigationCoordinator.playerExpandTrigger) { _, _ in
            presentExpandedPlayer()
        }
        .onChange(of: appEnvironment.navigationCoordinator.isPlayerExpanded) { _, isExpanded in
            if !isExpanded {
                ExpandedPlayerWindowManager.shared.hide()
            }
        }
    }

    private var usesSidebar: Bool {
        NavigationLayout.usesSidebar(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            style: appEnvironment.settingsManager.navigationStyle
        )
    }

    private static var usesTabBottomAccessory: Bool {
        if #available(iOS 26.1, *) { true } else { false }
    }

    @ViewBuilder
    private var miniPlayerOverlay: some View {
        let playerState = appEnvironment.playerService.state
        let hasActiveVideo = playerState.currentVideo != nil

        // Stays mounted under the expanded player: the dismiss gesture morphs
        // the video into its preview, so it must already be in place
        if hasActiveVideo {
            VStack(spacing: 0) {
                Spacer()
                MiniPlayerView()
            }
            .padding(.horizontal, 16)
            // Clear the bottom tab bar (49pt)
            .padding(.bottom, 49 + 8)
            // Use move-only transition (no opacity) to prevent thumbnail flash during collapse
            // The opacity transition caused video to appear faded during player sheet dismiss
            .transition(.move(edge: .bottom))
            .animation(.spring(response: 0.3), value: hasActiveVideo)
        }
    }

    private func presentExpandedPlayer() {
        let shouldAnimate = !appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation
        appEnvironment.navigationCoordinator.skipNextPlayerExpandAnimation = false
        ExpandedPlayerWindowManager.shared.show(with: appEnvironment, animated: shouldAnimate)
    }
}


// MARK: - Preview

#Preview {
    ContentView()
        .appEnvironment(.preview)
}
