//
//  UnifiedTabView.swift
//  Yattee
//
//  Unified tab view with sidebar sections.
//  Uses TabSection to group navigation items and display user data (channels, playlists).
//  iOS 26.1+ gets additional features: bottom accessory mini player and tab bar minimize behavior.
//

import SwiftUI

// MARK: - iOS Tab Bar Helpers

private extension View {
    @ViewBuilder
    func sidebarBottomBarPill() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }
}

// iOS 26.1+ Tab Features
extension View {
    @ViewBuilder
    func iOS26TabFeatures(shouldShowAccessory: Bool, settingsManager: SettingsManager?) -> some View {
        if #available(iOS 26.1, *) {
            let behavior = settingsManager?.miniPlayerMinimizeBehavior.tabBarMinimizeBehavior ?? .onScrollDown
            self
                .tabViewBottomAccessory(isEnabled: shouldShowAccessory) {
                    MiniPlayerView(isTabAccessory: true)
                }
                .tabBarMinimizeBehavior(behavior)
                // iOS 27 stopped focusing the search field when the search tab is
                // selected; restore the iOS 26 behavior explicitly.
                .tabViewSearchActivation(.searchTabSelection)
        } else {
            self
        }
    }
}

@available(iOS 26, *)
extension MiniPlayerMinimizeBehavior {
    var tabBarMinimizeBehavior: TabBarMinimizeBehavior {
        switch self {
        case .onScrollDown:
            return .onScrollDown
        case .never:
            return .never
        }
    }
}


// MARK: - iOS and macOS Implementation

/// Sidebar layout for iPad, the iPhone Duo inner screen and macOS: a
/// split view with a list sidebar. SwiftUI's sidebarAdaptable TabView never
/// shows a sidebar on iPhone idiom, so the split view is used on iOS too.
struct UnifiedTabView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let router: NavigationRouter

    // Zoom transition namespace (local to this tab view)
    @Namespace private var zoomTransition

    private var yatteeServerAuthHeader: String? {
        guard let server = appEnvironment?.instancesManager.enabledYatteeServerInstances.first else { return nil }
        return appEnvironment?.basicAuthCredentialsManager.basicAuthHeader(for: server)
    }

    private var zoomTransitionsEnabled: Bool {
        appEnvironment?.settingsManager.zoomTransitionsEnabled ?? true
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Global trailing edge of the sidebar column and leading edge of the split
    /// view, so the mini player can sit over the detail column.
    @State private var sidebarTrailingEdge: CGFloat = 0
    @State private var splitViewLeadingEdge: CGFloat = 0
    @State private var miniPlayerClearance: CGFloat = 0

    var body: some View {
        splitView
            .zoomTransitionNamespace(zoomTransition)
            .zoomTransitionsEnabled(zoomTransitionsEnabled)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                splitViewLeadingEdge = $0
            }
            // The detail column absorbs its NavigationStack, so modifiers on the
            // stack only reach its root page and vanish on push. The mini player
            // floats over the whole split view instead, and every page reserves
            // room for it through the environment.
            .overlay(alignment: .bottom) { miniPlayerOverlay }
            .environment(\.miniPlayerBottomClearance, miniPlayerClearance)
            .onAppear {
                configureSidebarManager()
                router.applyStartupTabIfNeeded(settingsManager?.effectiveStartupTabForSidebar() ?? .home)
                ensureSelectionIsAvailable(visibleMainItems: visibleMainItems)
            }
            .onChange(of: router.selection) { _, _ in
                ensureSelectionIsAvailable(visibleMainItems: visibleMainItems)
            }
            .onChange(of: sidebarManager.sortedSourceItems) { _, items in
                leaveRemovedSource(remaining: items)
            }
    }

    @ViewBuilder
    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: {
                    sidebarTrailingEdge = $0
                }
        } detail: {
            detailForSelection
        }
    }

    // MARK: - Visible Main Items

    private var visibleMainItems: [SidebarMainItem] {
        settingsManager?.visibleSidebarMainItems() ?? SidebarMainItem.defaultOrder
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        sidebarList
            .safeAreaInset(edge: .bottom) {
                if DataContextSwitcherVisibility.showsPickers(in: appEnvironment) {
                    // The sidebar is the one surface every section shares, so
                    // the switcher lives here rather than on each screen's toolbar.
                    DataContextSwitcherSidebarRow()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .sidebarBottomBarPill()
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
    }

    private var sidebarList: some View {
        // List selection is optional; deselecting keeps the current section.
        let selection = Binding<SidebarItem?>(
            get: { router.selection },
            set: { if let item = $0 { router.selection = item } }
        )

        return List(selection: selection) {
            ForEach(visibleMainItems) { item in
                sidebarRow(for: item)
            }

            if !sidebarManager.hasNoSources && (settingsManager?.sidebarSourcesEnabled ?? true) {
                Section(String(localized: "sidebar.section.sources")) {
                    ForEach(sidebarManager.sortedSourceItems) { item in
                        NavigationLink(value: item) {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                }
            }

            if !sidebarManager.channelItems.isEmpty && (settingsManager?.sidebarChannelsEnabled ?? true) {
                Section(String(localized: "sidebar.section.channels")) {
                    ForEach(sidebarManager.channelItems) { item in
                        NavigationLink(value: item) {
                            channelLabel(for: item)
                        }
                    }
                }
            }

            if !sidebarManager.playlistItems.isEmpty && (settingsManager?.sidebarPlaylistsEnabled ?? true) {
                Section(String(localized: "sidebar.section.playlists")) {
                    ForEach(sidebarManager.playlistItems) { item in
                        NavigationLink(value: item) {
                            playlistLabel(for: item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(for item: SidebarMainItem) -> some View {
        let sidebarItem = item.sidebarItem
        NavigationLink(value: sidebarItem) {
            Label(sidebarItem.title, systemImage: sidebarItem.systemImage)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailForSelection: some View {
        let selection = router.selection
        switch selection {
        case .home:
            NavigationStack(path: router.path(for: .home)) {
                HomeView().withNavigationDestinations()
            }
        case .search:
            NavigationStack(path: router.path(for: .search)) {
                SearchView(searchText: Bindable(router).searchText).withNavigationDestinations()
            }
        case .subscriptionsFeed:
            NavigationStack(path: router.path(for: .subscriptionsFeed)) {
                SubscriptionsView().withNavigationDestinations()
            }
        case .bookmarks:
            NavigationStack(path: router.path(for: .bookmarks)) {
                BookmarksListView().withNavigationDestinations()
            }
        case .history:
            NavigationStack(path: router.path(for: .history)) {
                HistoryListView().withNavigationDestinations()
            }
        case .downloads:
            NavigationStack(path: router.path(for: .downloads)) {
                DownloadsView().withNavigationDestinations()
            }
        case .manageChannels:
            NavigationStack(path: router.path(for: .manageChannels)) {
                ManageChannelsView().withNavigationDestinations()
            }
        case .playlistsList:
            NavigationStack(path: router.path(for: .playlistsList)) {
                PlaylistsListView().withNavigationDestinations()
            }
        case .sources:
            NavigationStack(path: router.path(for: .sources)) {
                MediaSourcesView().withNavigationDestinations()
            }
        case .settings:
            NavigationStack(path: router.path(for: .settings)) {
                SettingsView(showCloseButton: false).withNavigationDestinations()
            }
        case .openURL:
            NavigationStack(path: router.path(for: .openURL)) {
                OpenLinkView().withNavigationDestinations()
            }
        case .remoteControl:
            NavigationStack(path: router.path(for: .remoteControl)) {
                RemoteControlContentView(navigationStyle: .link)
                    .navigationTitle(String(localized: "remoteControl.title"))
                    .withNavigationDestinations()
            }
        case .continueWatching:
            NavigationStack(path: router.path(for: .continueWatching)) {
                ContinueWatchingView()
                    .withNavigationDestinations()
            }
        case .channel:
            channelContent(for: selection)
        case .playlist, .remotePlaylist:
            playlistContent(for: selection)
        case .mediaSource, .instance:
            sourceContent(for: selection)
        case .nowPlaying:
            EmptyView()
        }
    }

    private var settingsManager: SettingsManager? { appEnvironment?.settingsManager }

    /// The split view has no tab bar to host the mini player as a bottom
    /// accessory, so it floats at the bottom of the detail column and pages
    /// reserve its height as bottom safe area: floating content such as the
    /// subscriptions channel strip and the last rows of every list then clear
    /// it, as they clear the tab accessory.
    private var miniPlayerOverlay: some View {
        let hasActiveVideo = appEnvironment?.playerService.state.currentVideo != nil
        let sidebarWidth = columnVisibility == .detailOnly
            ? 0
            : max(0, sidebarTrailingEdge - splitViewLeadingEdge)

        // Stays mounted under the expanded player: the dismiss gesture morphs
        // the video into its preview, so it must already be in place
        return VStack(spacing: 0) {
            if hasActiveVideo {
                MiniPlayerView()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    // Move-only transition (no opacity) prevents a thumbnail flash during collapse
                    .transition(.move(edge: .bottom))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            miniPlayerClearance = $0
        }
        .padding(.leading, sidebarWidth)
        .animation(.spring(response: 0.3), value: hasActiveVideo)
    }
}

#Preview("Unified Tab View") {
    UnifiedTabView(router: NavigationRouter())
        .appEnvironment(.preview)
}

// MARK: - tvOS Implementation


// MARK: - Shared Helpers

extension UnifiedTabView {

    // MARK: - Computed Properties

    var sidebarManager: SidebarManager {
        router.sidebarManager
    }

    // MARK: - Configuration

    func configureSidebarManager() {
        guard let appEnvironment else { return }
        router.configureSidebarManagerIfNeeded(appEnvironment)
    }

    // MARK: - Layout Mapping

    /// Main items hidden from the sidebar by customization (or selected in the
    /// tab bar layout) are remapped onto a row that can host them.
    func ensureSelectionIsAvailable(visibleMainItems: [SidebarMainItem]) {
        let available = Set(visibleMainItems.map(\.sidebarItem))
        router.ensureSelectionIsAvailable(
            isAvailable: { item in
                switch item {
                case .channel, .playlist, .remotePlaylist, .mediaSource, .instance, .nowPlaying:
                    return true
                default:
                    return available.contains(item)
                }
            },
            instance: { id in appEnvironment?.instancesManager.enabledInstances.first { $0.id == id } }
        )
    }

    /// A source removed (or disabled) while selected leaves its row with
    /// nothing to render, so the user lands on Home instead of a blank page.
    func leaveRemovedSource(remaining items: [SidebarItem]) {
        let current = router.selection
        guard current.isMediaSource || current.isInstance,
              !items.contains(where: { $0.id == current.id }) else { return }
        router.popToRoot(current)
        router.select(.home)
    }

    // MARK: - Channel Content & Labels

    @ViewBuilder
    func channelContent(for item: SidebarItem) -> some View {
        if case .channel(let channelID, _, let source) = item {
            NavigationStack(path: router.path(for: item)) {
                ChannelView(channelID: channelID, source: source)
                    .withNavigationDestinations()
            }
            .id(item.id)
        }
    }

    @ViewBuilder
    func channelLabel(for item: SidebarItem) -> some View {
        if case .channel(_, let name, _) = item {
            Label {
                Text(name)
            } icon: {
                SidebarChannelIcon(
                    url: sidebarManager.avatarURL(for: item),
                    name: name,
                    authHeader: yatteeServerAuthHeader
                )
            }
        }
    }

    // MARK: - Playlist Content & Labels

    @ViewBuilder
    func playlistContent(for item: SidebarItem) -> some View {
        switch item {
        case .playlist(let id, _):
            NavigationStack(path: router.path(for: item)) {
                UnifiedPlaylistDetailView(source: .local(id))
                    .withNavigationDestinations()
            }
            .id(item.id)
        case .remotePlaylist(let id, let title, let accountID):
            NavigationStack(path: router.path(for: item)) {
                // No instance passed: the detail view resolves it from the
                // account, same as SidebarItem.navigationDestination().
                UnifiedPlaylistDetailView(source: .remote(id, instance: nil, title: title, accountID: accountID))
                    .withNavigationDestinations()
            }
            .id(item.id)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    func playlistLabel(for item: SidebarItem) -> some View {
        if item.isPlaylist {
            Label {
                Text(item.title)
            } icon: {
                SidebarPlaylistIcon(url: sidebarManager.thumbnailURL(for: item))
            }
        }
    }

    // MARK: - Media Source Content

    @ViewBuilder
    func mediaSourceContent(for item: SidebarItem) -> some View {
        if case .mediaSource(let id, _, _) = item,
           let source = appEnvironment?.mediaSourcesManager.source(byID: id) {
            NavigationStack(path: router.path(for: item)) {
                MediaBrowserView(source: source, path: "/")
                    .withNavigationDestinations()
            }
            .id(item.id)
        }
    }

    // MARK: - Instance Content

    @ViewBuilder
    func instanceContent(for item: SidebarItem) -> some View {
        if case .instance(let id, _, _) = item,
           let instance = appEnvironment?.instancesManager.enabledInstances.first(where: { $0.id == id }) {
            NavigationStack(path: router.path(for: item)) {
                InstanceBrowseView(instance: instance)
                    .withNavigationDestinations()
            }
            .id(item.id)
        }
    }

    // MARK: - Unified Source Content

    /// Renders content for any source item (instance or media source).
    @ViewBuilder
    func sourceContent(for item: SidebarItem) -> some View {
        switch item {
        case .instance:
            instanceContent(for: item)
        case .mediaSource:
            mediaSourceContent(for: item)
        default:
            EmptyView()
        }
    }
}
