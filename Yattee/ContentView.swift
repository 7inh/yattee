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
    @Namespace private var playerTransition


    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if !usesSidebar {
                    CompactTabView(router: appEnvironment.navigationCoordinator.router)
                        .environment(appEnvironment.settingsManager)
                } else {
                    UnifiedTabView(router: appEnvironment.navigationCoordinator.router)
                    .environment(appEnvironment.settingsManager)
                }
            }
            .environment(\.playerTransitionNamespace, playerTransition)

            // The tab bar layout on iOS 26.1+ shows the mini player as the tab
            // bar's bottom accessory; the split-view sidebar layout insets it
            // into its detail column.
            if !usesSidebar && !Self.usesTabBottomAccessory {
                miniPlayerOverlay
            }

        }
        .fullScreenCover(isPresented: Binding(
            get: { appEnvironment.navigationCoordinator.isPlayerExpanded },
            set: { appEnvironment.navigationCoordinator.isPlayerExpanded = $0 }
        )) {
            ExpandedPlayerSheet()
                .appEnvironment(appEnvironment)
                .playerZoomTransition(in: playerTransition)
                .onAppear { appEnvironment.navigationCoordinator.isPlayerWindowVisible = true }
                .onDisappear { appEnvironment.navigationCoordinator.isPlayerWindowVisible = false }
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


}


// MARK: - Preview

#Preview {
    ContentView()
        .appEnvironment(.preview)
}


// MARK: - Player zoom transition

private struct PlayerTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Shared namespace linking the mini player to the full-screen player so the
    /// cover uses the native zoom transition (with interactive swipe-down dismiss).
    var playerTransitionNamespace: Namespace.ID? {
        get { self[PlayerTransitionNamespaceKey.self] }
        set { self[PlayerTransitionNamespaceKey.self] = newValue }
    }
}

enum PlayerTransition {
    static let sourceID = "nowPlaying"
}

extension View {
    @ViewBuilder
    func playerZoomTransition(in namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) {
            navigationTransition(.zoom(sourceID: PlayerTransition.sourceID, in: namespace))
        } else {
            self
        }
    }

    @ViewBuilder
    func playerTransitionSource(_ namespace: Namespace.ID?) -> some View {
        if #available(iOS 18, *), let namespace {
            matchedTransitionSource(id: PlayerTransition.sourceID, in: namespace)
        } else {
            self
        }
    }
}
