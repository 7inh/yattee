//
//  YouTubeHomeFeed.swift
//  Yattee
//
//  Compact iOS Home feed with local shelves, subscriptions, and trending videos.
//

import Foundation
import SwiftUI

#if os(iOS)
@MainActor
struct YouTubeHomeFeed: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.scenePhase) private var scenePhase

    @State private var feedCache = SubscriptionFeedCache.shared
    @State private var continueWatching: [Video] = []
    @State private var recentPlaylists: [PlaylistListItem] = []
    @State private var trendingVideos: [Video] = []
    @State private var trendingError: String?
    @State private var isLoading = true
    @State private var reloadToken = 0
    @State private var loadGeneration = 0

    private var dataManager: DataManager? { appEnvironment?.dataManager }
    private var settingsManager: SettingsManager? { appEnvironment?.settingsManager }

    private var shelfLimit: Int {
        settingsManager?.homeSectionItemsLimit ?? SettingsManager.defaultHomeSectionItemsLimit
    }

    private var trendingInstance: Instance? {
        guard let instances = appEnvironment?.instancesManager else { return nil }
        if let active = instances.activeInstance, active.type == .invidious {
            return active
        }
        return instances.enabledInstances.first { $0.type == .invidious }
    }

    private var subscriptionVideos: [Video] {
        guard appEnvironment?.subscriptionService.cachedSubscriptionCount != 0 else { return [] }
        return feedCache.videos
    }

    /// Preserve subscription order, then append trending without repeating a video.
    private var videos: [Video] {
        var seen = Set<VideoID>()
        return (subscriptionVideos + trendingVideos).filter { seen.insert($0.id).inserted }
    }

    private var errorMessage: String? {
        if let trendingError { return trendingError }
        guard appEnvironment?.subscriptionService.cachedSubscriptionCount != 0,
              case let .error(error) = feedCache.feedLoadState else { return nil }
        switch error {
        case .yatteeServerRequired:
            return String(localized: "subscriptions.error.yatteeServerRequired")
        case .notAuthenticated:
            return String(localized: "subscriptions.error.notAuthenticated")
        case .networkError(let message):
            return message
        }
    }

    // MARK: - Feed

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !continueWatching.isEmpty {
                    continueWatchingShelf
                }
                if !recentPlaylists.isEmpty {
                    playlistsShelf
                }
                videoCards
                loadingOrEmptyState
            }
            .padding(.vertical, 16)
        }
        .refreshable { await loadFeed(forceRefresh: true) }
        .task(id: reloadToken) { await loadFeed() }
        .onReceive(NotificationCenter.default.publisher(for: .watchHistoryDidChange)) { _ in
            loadLocalShelves()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistsDidChange)) { _ in
            loadLocalShelves()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentPlaylistsDidChange)) { _ in
            loadLocalShelves()
        }
        .onReceive(NotificationCenter.default.publisher(for: .subscriptionsDidChange)) { _ in
            feedCache.invalidate()
            reloadToken += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountCredentialDidChange)) { _ in
            reloadToken += 1
        }
        .onChange(of: appEnvironment?.dataContextValidator.effectiveContext) { _, _ in
            reloadToken += 1
        }
        .onChange(of: trendingInstance) { _, _ in
            trendingVideos = []
            reloadToken += 1
        }
        .onChange(of: settingsManager?.saveRecentPlaylists) { _, _ in
            loadLocalShelves()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadToken += 1 }
        }
    }

    private var continueWatchingShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "home.section.continueWatching"))
                .font(.headline)
                .padding(.horizontal)
            HomeHorizontalCards(
                videos: continueWatching,
                queueSource: .manual,
                sourceLabel: String(localized: "queue.source.continueWatching")
            )
        }
    }

    private var playlistsShelf: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "search.recentPlaylists.title"))
                .font(.headline)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(recentPlaylists, id: \.id) { item in
                        NavigationLink(value: NavigationDestination.playlist(playlistSource(for: item))) {
                            playlistCard(for: item)
                                .frame(width: 200)
                        }
                        .buttonStyle(.plain)
                        .zoomTransitionSource(id: item.transitionID)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private var videoCards: some View {
        let videoList = videos
        let subscriptionIDs = Set(subscriptionVideos.map(\.id))
        return ForEach(Array(videoList.enumerated()), id: \.element.id) { index, video in
            let isSubscription = subscriptionIDs.contains(video.id)
            VideoCardView(video: video)
                .frame(maxWidth: .infinity)
                .tappableVideo(
                    video,
                    queueSource: isSubscription ? .subscriptions(continuation: nil) : .manual,
                    sourceLabel: isSubscription
                        ? String(localized: "queue.source.subscriptions")
                        : String(localized: "home.instanceContent.trending"),
                    videoList: videoList,
                    videoIndex: index
                )
                .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var loadingOrEmptyState: some View {
        if isLoading || feedCache.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if videos.isEmpty || errorMessage != nil {
            ContentUnavailableView {
                Label(
                    String(localized: errorMessage == nil ? "common.noContent" : "common.error"),
                    systemImage: errorMessage == nil ? "video.slash" : "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage ?? String(localized: "instance.browse.noVideos"))
            } actions: {
                Button(String(localized: "common.retry")) {
                    Task { await loadFeed(forceRefresh: true) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Playlists

    @ViewBuilder
    private func playlistCard(for item: PlaylistListItem) -> some View {
        switch item {
        case .local(let playlist): LocalPlaylistCardView(playlist: playlist)
        case .remote(let playlist): PlaylistCardView(playlist: playlist)
        }
    }

    private func playlistSource(for item: PlaylistListItem) -> PlaylistSource {
        switch item {
        case .local(let playlist): .local(playlist.id, title: playlist.title)
        case .remote(let playlist): .remote(playlist.id, instance: nil, title: playlist.title)
        }
    }

    private func playlist(from recent: RecentPlaylist) -> Playlist {
        let source: ContentSource
        let instanceURL = recent.instanceURLString.flatMap { URL(string: $0) }
        switch (recent.sourceRawValue, instanceURL) {
        case ("federated", .some(let url)):
            source = .federated(provider: ContentSource.peertubeProvider, instance: url)
        case ("extracted", .some(let url)):
            source = .extracted(extractor: "generic", originalURL: url)
        default:
            source = .global(provider: ContentSource.youtubeProvider)
        }
        return Playlist(
            id: PlaylistID(source: source, playlistID: recent.playlistID),
            title: recent.title,
            author: Author(id: "", name: recent.authorName),
            videoCount: recent.videoCount,
            thumbnailURL: recent.thumbnailURLString.flatMap { URL(string: $0) }
        )
    }

    // MARK: - Loading

    private func loadLocalShelves() {
        let history = dataManager?.watchHistory(limit: 100) ?? []
        continueWatching = Array(history.filter {
            !$0.isFinished && !$0.isLive && $0.watchedSeconds > 10
        }.prefix(shelfLimit)).map { $0.toVideo() }

        var playlists = (dataManager?.playlists() ?? []).filter { !$0.isPlaceholder }.map {
            (date: $0.updatedAt, item: PlaylistListItem.local($0))
        }
        if settingsManager?.saveRecentPlaylists != false {
            playlists += (dataManager?.fetchRecentPlaylists(limit: shelfLimit) ?? []).map {
                (date: $0.visitedAt, item: PlaylistListItem.remote(playlist(from: $0)))
            }
        }
        var seen = Set<PlaylistListItemID>()
        recentPlaylists = Array(playlists.sorted { $0.date > $1.date }.map(\.item)
            .filter { seen.insert($0.id).inserted }.prefix(shelfLimit))
    }

    private func loadFeed(forceRefresh: Bool = false) async {
        guard let appEnvironment else {
            isLoading = false
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        trendingError = nil
        loadLocalShelves()
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        // Trending can arrive even while the subscription backend is still loading.
        async let subscriptionRefresh: Void = Self.refreshSubscriptions(using: appEnvironment, forceRefresh: forceRefresh)
        if let instance = trendingInstance {
            do {
                let fetched = try await appEnvironment.contentService.trending(for: instance)
                guard !Task.isCancelled, generation == loadGeneration else { return }
                trendingVideos = fetched
            } catch {
                guard !Task.isCancelled, generation == loadGeneration else { return }
                trendingError = error.localizedDescription
                LoggingService.shared.warning("Home trending failed: \(error.localizedDescription)", category: .general)
            }
        }
        await subscriptionRefresh
    }

    private static func refreshSubscriptions(using appEnvironment: AppEnvironment, forceRefresh: Bool) async {
        let cache = SubscriptionFeedCache.shared
        await cache.loadFromDiskIfNeeded()
        guard !Task.isCancelled else { return }

        var count = appEnvironment.subscriptionService.cachedSubscriptionCount
        if count == nil {
            do {
                count = try await appEnvironment.subscriptionService.fetchSubscriptions().count
            } catch {
                LoggingService.shared.warning("Home subscriptions failed: \(error.localizedDescription)", category: .general)
            }
        }
        guard !Task.isCancelled, count != 0,
              forceRefresh || !cache.isCacheValid(using: appEnvironment.settingsManager),
              !cache.isLoading else { return }
        await cache.refresh(using: appEnvironment)
    }
}
#endif
