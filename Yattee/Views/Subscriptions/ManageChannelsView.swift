//
//  ManageChannelsView.swift
//  Yattee
//
//  View for managing subscribed channels.
//

import SwiftUI

struct ManageChannelsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Namespace private var sheetTransition
    @State private var channels: [Channel] = []
    @State private var showViewOptions = false
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var notificationStates: [String: Bool] = [:]

    // View options (persisted)
    @AppStorage("manageChannelsLayout") private var layout: VideoListLayout = .grid
    @AppStorage("manageChannelsRowStyle") private var rowStyle: VideoRowStyle = .regular
    @AppStorage("manageChannelsGridColumns") private var gridColumns = 3
    @AppStorage("manageChannelsSortOrder") private var sortOrder: SidebarChannelSort = .alphabetical

    @State private var subscriptionMetadata: [String: Subscription] = [:]

    /// List style from centralized settings.
    private var listStyle: VideoListStyle {
        appEnvironment?.settingsManager.listStyle ?? .inset
    }

    private var viewOptionsForm: some View {
        Form {
            // View options section
            Section {
                // Layout picker (segmented)
                Picker(selection: $layout) {
                    ForEach(VideoListLayout.allCases, id: \.self) { option in
                        Label(option.displayName, systemImage: option.systemImage)
                            .tag(option)
                    }
                } label: {
                    Text("viewOptions.layout")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))

                // List-specific options
                if layout == .list {
                    PlatformMenuPicker(String(localized: "viewOptions.rowSize"), selection: $rowStyle) {
                        Text("viewOptions.rowSize.compact").tag(VideoRowStyle.compact)
                        Text("viewOptions.rowSize.regular").tag(VideoRowStyle.regular)
                        Text("viewOptions.rowSize.large").tag(VideoRowStyle.large)
                    }
                }

                // Grid-specific options
                if layout == .grid {
                    Stepper(
                        "viewOptions.columns \(min(max(GridConstants.minAllowedColumns, gridColumns), gridConfig.maxColumns))",
                        value: $gridColumns,
                        in: GridConstants.minAllowedColumns...max(GridConstants.minAllowedColumns, gridConfig.maxColumns)
                    )
                }

                PlatformMenuPicker(String(localized: "manageChannels.sortBy"), selection: $sortOrder) {
                    Text("manageChannels.sortBy.name").tag(SidebarChannelSort.alphabetical)
                    Text("manageChannels.sortBy.recentlySubscribed").tag(SidebarChannelSort.recentlySubscribed)
                    Text("manageChannels.sortBy.lastUploaded").tag(SidebarChannelSort.lastUploaded)
                }
            }

            // Subscriptions Data navigation link
            Section {
                NavigationLink {
                    SubscriptionsSettingsView()
                } label: {
                    Label(String(localized: "manageChannels.subscriptionsData"), systemImage: "person.2.badge.gearshape")
                }
            }
        }
    }

    // Grid layout configuration
    @State private var viewWidth: CGFloat = 0
    private var gridConfig: GridLayoutConfiguration {
        GridLayoutConfiguration(viewWidth: viewWidth, gridColumns: gridColumns)
    }

    private var dataManager: DataManager? { appEnvironment?.dataManager }
    private var subscriptionService: SubscriptionService? { appEnvironment?.subscriptionService }
    private var toastManager: ToastManager? { appEnvironment?.toastManager }
    private var yatteeServer: Instance? { nil }
    private var yatteeServerURL: URL? { nil }
    private var yatteeServerAuthHeader: String? { nil }

    /// Channels filtered by search query and sorted by selected order.
    private var filteredChannels: [Channel] {
        var result = channels

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { $0.name.lowercased().contains(query) }
        }

        switch sortOrder {
        case .alphabetical:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recentlySubscribed:
            result.sort { ch1, ch2 in
                let d1 = subscriptionMetadata[ch1.id.channelID]?.subscribedAt ?? .distantPast
                let d2 = subscriptionMetadata[ch2.id.channelID]?.subscribedAt ?? .distantPast
                return d1 > d2
            }
        case .lastUploaded:
            result.sort { ch1, ch2 in
                let d1 = subscriptionMetadata[ch1.id.channelID]?.lastVideoPublishedAt ?? .distantPast
                let d2 = subscriptionMetadata[ch2.id.channelID]?.lastVideoPublishedAt ?? .distantPast
                return d1 > d2
            }
        case .custom:
            break
        }

        return result
    }

    /// View options button lives on the leading edge on macOS, trailing elsewhere.
    private var viewOptionsPlacement: ToolbarItemPlacement {
        .primaryAction
    }

    var body: some View {
        GeometryReader { geometry in
            stateContent
                .onChange(of: geometry.size.width, initial: true) { _, newWidth in
                    viewWidth = newWidth
                }
        }
        .navigationTitle(String(localized: "subscriptions.channels.title"))
        .toolbarTitleDisplayMode(.inlineLarge)
        .searchable(text: $searchText, prompt: Text(String(localized: "channels.search.placeholder")))
        .toolbar {
            ToolbarItem(placement: viewOptionsPlacement) {
                Button {
                    showViewOptions = true
                } label: {
                    Label(String(localized: "viewOptions.title"), systemImage: "slider.horizontal.3")
                }
                .liquidGlassTransitionSource(id: "manageChannelsViewOptions", in: sheetTransition)
            }
        }
        .sheet(isPresented: $showViewOptions) {
            NavigationStack {
                viewOptionsForm
                .navigationTitle(String(localized: "manageChannels.viewOptions.title"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.height(360), .large])
            .presentationDragIndicator(.visible)
            .liquidGlassSheetContent(sourceID: "manageChannelsViewOptions", in: sheetTransition)
        }
        .onAppear {
            if let syncChannels = subscriptionService?.fetchSubscriptionsSync() {
                channels = syncChannels
            }
            // A channel can be subscribed under several account scopes.
            subscriptionMetadata = Dictionary(
                (dataManager?.subscriptions() ?? []).map { ($0.channelID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
        .task {
            guard channels.isEmpty else { return }
            await refreshChannels()
        }
        .task {
            // Fetch missing subscriber counts from Yattee Server (runs after onAppear)
            await fetchMissingSubscriberCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionsDidChange)) { _ in
            Task {
                await refreshChannels()
            }
        }
        // The data context, not the legacy setting: switching between two
        // logins on the same instance leaves that value identical, and this
        // view would keep listing one account's channels while unsubscribes
        // went to the other.
        .onReceive(NotificationCenter.default.publisher(for: .dataContextDidChange)) { _ in
            Task {
                await refreshChannels()
            }
        }
    }

    // MARK: - Content Views

    @ViewBuilder
    private var stateContent: some View {
        if isLoading && channels.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if channels.isEmpty {
            ContentUnavailableView {
                Label(String(localized: "subscriptions.channels.title"), systemImage: "person.2")
            } description: {
                Text(String(localized: "subscriptions.channels.empty"))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            channelsView
        }
    }

    @ViewBuilder
    private var channelsView: some View {
        Group {
            if filteredChannels.isEmpty {
                ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch layout {
                case .list:
                    listContent
                case .grid:
                    gridContent
                }
            }
        }
    }

    private var listContent: some View {
        VideoListContainer(listStyle: listStyle, rowStyle: rowStyle) {
            Spacer()
                .frame(height: 16)
        } content: {
            ForEach(Array(filteredChannels.enumerated()), id: \.element.id.channelID) { index, channel in
                VideoListRow(
                    isLast: index == filteredChannels.count - 1,
                    rowStyle: rowStyle,
                    listStyle: listStyle
                ) {
                    channelRow(channel: channel)
                }
            }
        }
    }

    @ViewBuilder
    private func channelRow(channel: Channel) -> some View {
        NavigationLink(
            value: NavigationDestination.channel(
                channel.id.channelID,
                channel.id.source
            )
        ) {
            ChannelRowView(
                channel: channelWithOptimizedAvatar(channel),
                style: rowStyle,
                authHeader: yatteeServerAuthHeader
            )
            .contentShape(Rectangle())
        }
        .zoomTransitionSource(id: channel.id.channelID)
        .buttonStyle(.plain)
        .swipeActions {
            SwipeAction(
                symbolImage: notificationsEnabled(for: channel) ? "bell.slash" : "bell",
                tint: .white,
                background: .blue,
                font: .body,
                size: CGSize(width: 38, height: 38)
            ) { reset in
                toggleNotifications(for: channel)
                reset()
            }

            SwipeAction(
                symbolImage: "person.badge.minus",
                tint: .white,
                background: .red,
                font: .body,
                size: CGSize(width: 38, height: 38)
            ) { reset in
                unsubscribe(from: channel)
                reset()
            }
        }
        .contextMenu {
            Button {
                toggleNotifications(for: channel)
            } label: {
                Label(
                    notificationsEnabled(for: channel)
                        ? String(localized: "channel.menu.disableNotifications")
                        : String(localized: "channel.menu.enableNotifications"),
                    systemImage: notificationsEnabled(for: channel) ? "bell.slash" : "bell"
                )
            }

            Button(role: .destructive) {
                unsubscribe(from: channel)
            } label: {
                Label(String(localized: "channel.unsubscribe"), systemImage: "person.badge.minus")
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            VideoGridContent(columns: gridConfig.effectiveColumns) {
                ForEach(filteredChannels, id: \.id.channelID) { channel in
                    NavigationLink(
                        value: NavigationDestination.channel(
                            channel.id.channelID,
                            channel.id.source
                        )
                    ) {
                        ChannelCardGridView(
                            channel: channelWithOptimizedAvatar(channel),
                            isCompact: gridConfig.isCompactCards,
                            authHeader: yatteeServerAuthHeader
                        )
                        .frame(maxHeight: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                    }
                    .zoomTransitionSource(id: channel.id.channelID)
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            toggleNotifications(for: channel)
                        } label: {
                            Label(
                                notificationsEnabled(for: channel)
                                    ? String(localized: "channel.menu.disableNotifications")
                                    : String(localized: "channel.menu.enableNotifications"),
                                systemImage: notificationsEnabled(for: channel) ? "bell.slash" : "bell"
                            )
                        }

                        Button(role: .destructive) {
                            unsubscribe(from: channel)
                        } label: {
                            Label(String(localized: "channel.unsubscribe"), systemImage: "person.badge.minus")
                        }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    // MARK: - Helpers

    /// Returns channel with optimized avatar URL from Yattee Server when available.
    private func channelWithOptimizedAvatar(_ channel: Channel) -> Channel {
        let effectiveAvatarURL = AvatarURLBuilder.avatarURL(
            channelID: channel.id.channelID,
            directURL: channel.thumbnailURL,
            serverURL: yatteeServerURL,
            size: gridConfig.isCompactCards ? 80 : 100
        )

        return Channel(
            id: channel.id,
            name: channel.name,
            description: channel.description,
            subscriberCount: channel.subscriberCount,
            thumbnailURL: effectiveAvatarURL,
            bannerURL: channel.bannerURL,
            isVerified: channel.isVerified
        )
    }

    /// Refreshes channels from the current subscription provider.
    private func refreshChannels() async {
        guard let subscriptionService else { return }

        isLoading = true
        do {
            channels = try await subscriptionService.fetchSubscriptions()
        } catch {
            // Show empty state on error
            channels = []
            LoggingService.shared.error(
                "Failed to fetch subscriptions: \(error.localizedDescription)",
                category: .general
            )
        }
        isLoading = false
    }

    /// Fetches subscriber counts for channels that don't have them cached.
    /// Uses Yattee Server's cached metadata endpoint (no YouTube API calls).
    private func fetchMissingSubscriberCounts() async {
        return
    }

    private func unsubscribe(from channel: Channel) {
        Task {
            do {
                try await subscriptionService?.unsubscribe(from: channel.id.channelID)
                // Remove from local list immediately for responsiveness
                channels.removeAll { $0.id.channelID == channel.id.channelID }
            } catch {
                toastManager?.showError(
                    String(localized: "channel.unsubscribe.error.title"),
                    subtitle: error.localizedDescription
                )
            }
        }
    }

    private func notificationsEnabled(for channel: Channel) -> Bool {
        // Use local state if available, otherwise query DataManager
        if let localState = notificationStates[channel.id.channelID] {
            return localState
        }
        return dataManager?.notificationsEnabled(for: channel.id.channelID) ?? false
    }

    private func toggleNotifications(for channel: Channel) {
        let currentState = notificationsEnabled(for: channel)

        if currentState {
            // Disabling — no permission check needed
            notificationStates[channel.id.channelID] = false
            dataManager?.setNotificationsEnabled(false, for: channel.id.channelID)
        } else {
            Task {
                guard let appEnvironment, await appEnvironment.ensureNotificationsEnabled() else { return }
                notificationStates[channel.id.channelID] = true
                appEnvironment.dataManager.setNotificationsEnabled(true, for: channel.id.channelID)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        ManageChannelsView()
    }
    .appEnvironment(.preview)
}
