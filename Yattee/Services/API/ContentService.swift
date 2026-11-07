//
//  ContentService.swift
//  Yattee
//
//  Unified interface for fetching content from any backend (Invidious, Piped, PeerTube).
//

import Foundation

/// Protocol defining the common content fetching interface.
protocol ContentServiceProtocol: Sendable {}

/// Unified content service that routes requests to the appropriate API based on instance type.
actor ContentService: ContentServiceProtocol {
    private let httpClientFactory: HTTPClientFactory

    // Default HTTPClient for instances with standard SSL (allowInvalidCertificates = false)
    private let defaultHTTPClient: HTTPClient

    // Cached API instances for default SSL mode
    private let defaultInvidiousAPI: InvidiousAPI
    private let channelAvatarCache = ChannelAvatarCache()

    private struct LyricsCacheKey: Hashable, Sendable {
        let videoID: String
        let caption: Caption
    }
    private var lyricsCache: [LyricsCacheKey: [LyricLine]] = [:]
    private var lyricsCacheOrder: [LyricsCacheKey] = []

    /// Credentials manager for fetching basic auth headers on demand.
    private let basicAuthCredentialsManager: BasicAuthCredentialsManager?

    init(httpClient: HTTPClient, basicAuthCredentialsManager: BasicAuthCredentialsManager? = nil) {
        // Legacy init - create factory internally
        self.httpClientFactory = HTTPClientFactory()
        self.defaultHTTPClient = httpClient
        self.defaultInvidiousAPI = InvidiousAPI(httpClient: httpClient)
        self.basicAuthCredentialsManager = basicAuthCredentialsManager
    }

    // MARK: - Routing

    /// Builds a per-instance HTTPClient with the basic-auth `Authorization` header baked in,
    /// or returns nil if no basic-auth credentials are configured for the instance.
    /// Used to inject reverse-proxy basic auth uniformly across all backends.
    private func httpClientWithBasicAuth(for instance: Instance) async -> HTTPClient? {
        guard let authHeader = await basicAuthCredentialsManager?.basicAuthHeader(for: instance) else {
            return nil
        }
        let client = httpClientFactory.createClient(for: instance)
        await client.setDefaultHeaders(["Authorization": authHeader])
        return client
    }

    /// Returns an API client configured for the instance's SSL and auth requirements.
    private func api(for instance: Instance) async -> any InstanceAPI {
        switch instance.type {
        case .invidious:
            return await invidiousAPI(for: instance)
        }
    }

    /// Returns a YatteeServerAPI configured for the instance's SSL and auth requirements.

    /// Returns an InvidiousAPI configured for the instance's SSL and auth requirements.
    private func invidiousAPI(for instance: Instance) async -> InvidiousAPI {
        if let authClient = await httpClientWithBasicAuth(for: instance) {
            return InvidiousAPI(httpClient: authClient)
        }
        if !instance.allowInvalidCertificates {
            return defaultInvidiousAPI
        }
        let insecureClient = httpClientFactory.createClient(for: instance)
        return InvidiousAPI(httpClient: insecureClient)
    }

    /// Returns a PipedAPI configured for the instance's SSL and auth requirements.

    /// Returns a PeerTubeAPI configured for the instance's SSL and auth requirements.

    // MARK: - ContentServiceProtocol

    func trending(for instance: Instance) async throws -> [Video] {
        try await api(for: instance).trending(instance: instance)
    }

    func popular(for instance: Instance) async throws -> [Video] {
        try await api(for: instance).popular(instance: instance)
    }

    func feed(for instance: Instance, credential: String) async throws -> [Video] {
        switch instance.type {
        case .invidious:
            let response = try await invidiousAPI(for: instance).feed(
                instance: instance,
                sid: credential,
                page: 1,
                maxResults: 50  // Fetch 50, but HomeView will show max 15 per section
            )
            return response.videos
        default:
            throw APIError.notSupported
        }
    }

    /// Fetches one page of the credential owner's feed.
    ///
    /// Separate from the unpaged `feed(for:credential:)` because only Invidious
    /// has pages at all: Piped answers with the whole feed however it is asked,
    /// which is why it always reports there is no more to come.
    func feed(for instance: Instance, credential: String, page: Int) async throws -> FeedPage {
        switch instance.type {
        case .invidious:
            let response = try await invidiousAPI(for: instance).feed(
                instance: instance,
                sid: credential,
                page: page
            )
            return FeedPage(videos: response.videos, hasMore: response.hasMore)
        default:
            throw APIError.notSupported
        }
    }

    func subscriptions(for instance: Instance, credential: String) async throws -> [Channel] {
        switch instance.type {
        case .invidious:
            let subs = try await invidiousAPI(for: instance).subscriptions(
                instance: instance,
                sid: credential
            )
            return subs.map { $0.toChannel(baseURL: instance.url) }
        default:
            throw APIError.notSupported
        }
    }

    func search(query: String, instance: Instance, page: Int = 1, filters: SearchFilters = .defaults) async throws -> SearchResult {
        try await api(for: instance).search(query: query, instance: instance, page: page, filters: filters)
    }

    func searchSuggestions(query: String, instance: Instance) async throws -> [String] {
        try await api(for: instance).searchSuggestions(query: query, instance: instance)
    }

    func video(id: String, instance: Instance) async throws -> Video {
        try await api(for: instance).video(id: id, instance: instance)
    }

    func channel(id: String, instance: Instance) async throws -> Channel {
        try await api(for: instance).channel(id: id, instance: instance)
    }

    /// Avatar-only consumers share a bounded cache and in-flight channel requests.
    func channelAvatarURL(id: String, instance: Instance) async throws -> URL? {
        try await channelAvatarCache.thumbnailURL(channelID: id, instanceURL: instance.url) {
            do {
                return try await self.channel(id: id, instance: instance).thumbnailURL
            } catch {
                LoggingService.shared.warning("Channel avatar lookup failed: \(error.localizedDescription)", category: .general)
                throw error
            }
        }
    }

    func channelVideos(id: String, instance: Instance, continuation: String? = nil) async throws -> ChannelVideosPage {
        try await api(for: instance).channelVideos(id: id, instance: instance, continuation: continuation)
    }

    func channelPlaylists(id: String, instance: Instance, continuation: String? = nil) async throws -> ChannelPlaylistsPage {
        try await api(for: instance).channelPlaylists(id: id, instance: instance, continuation: continuation)
    }

    func channelShorts(id: String, instance: Instance, continuation: String? = nil) async throws -> ChannelVideosPage {
        try await api(for: instance).channelShorts(id: id, instance: instance, continuation: continuation)
    }

    func channelStreams(id: String, instance: Instance, continuation: String? = nil) async throws -> ChannelVideosPage {
        try await api(for: instance).channelStreams(id: id, instance: instance, continuation: continuation)
    }

    func playlist(id: String, instance: Instance) async throws -> Playlist {
        try await api(for: instance).playlist(id: id, instance: instance)
    }

    func comments(videoID: String, instance: Instance, continuation: String? = nil, sort: CommentSort = .top) async throws -> CommentsPage {
        try await api(for: instance).comments(videoID: videoID, instance: instance, continuation: continuation, sort: sort)
    }

    func captions(videoID: String, instance: Instance) async throws -> [Caption] {
        try await api(for: instance).captions(videoID: videoID, instance: instance)
    }

    /// Keep parsed tracks across panel presentations and track switches, bounded to 32 tracks.
    func lyrics(videoID: String, caption: Caption, instance: Instance) async throws -> [LyricLine] {
        let key = LyricsCacheKey(videoID: videoID, caption: caption)
        if let cached = lyricsCache[key] { return cached }
        let text = try await invidiousAPI(for: instance).captionText(caption)
        guard !Task.isCancelled else { throw APIError.cancelled }
        let lines = WebVTTParser.parse(text)
        if lyricsCache[key] == nil {
            lyricsCacheOrder.append(key)
        }
        lyricsCache[key] = lines
        if lyricsCacheOrder.count > 32 {
            lyricsCache.removeValue(forKey: lyricsCacheOrder.removeFirst())
        }
        return lines
    }

    func channelSearch(id: String, query: String, instance: Instance, page: Int = 1) async throws -> ChannelSearchPage {
        try await api(for: instance).channelSearch(id: id, query: query, instance: instance, page: page)
    }

    // MARK: - Authenticated Playlists

    /// Fetches the playlists the credential's owner has on the instance.
    func userPlaylists(instance: Instance, credential: String) async throws -> [Playlist] {
        switch instance.type {
        case .invidious:
            return try await invidiousAPI(for: instance).userPlaylists(instance: instance, sid: credential)
        default:
            throw APIError.notSupported
        }
    }

    /// Fetches one of the credential owner's playlists along with the per-entry
    /// identities its rows can be removed by.
    func userPlaylistSnapshot(
        id: String,
        instance: Instance,
        credential: String
    ) async throws -> RemotePlaylistSnapshot {
        switch instance.type {
        case .invidious:
            return try await invidiousAPI(for: instance).userPlaylistSnapshot(
                id: id,
                instance: instance,
                sid: credential
            )
        default:
            throw APIError.notSupported
        }
    }

    /// Creates a playlist for the credential's owner. **One request.**
    ///
    /// Neither backend takes a description when creating, so this does not take
    /// one either: setting it is a separate write, sequenced by the caller with
    /// a credential recheck in between.
    ///
    /// The returned playlist is the little the server says about what it just
    /// made — an id and a title. Nothing else is invented here: callers refetch
    /// the list, which is the only description that is actually the server's.
    /// - Parameters:
    ///   - privacy: Ignored by backends without a visibility concept (Piped),
    ///     and defaulted to private on those that have one when not given —
    ///     Invidious rejects a creation that carries no visibility at all.
    func createPlaylist(
        title: String,
        privacy: PlaylistPrivacy?,
        instance: Instance,
        credential: String
    ) async throws -> Playlist {
        switch instance.type {
        case .invidious:
            return try await invidiousAPI(for: instance).createPlaylist(
                title: title,
                privacy: privacy ?? .private,
                instance: instance,
                sid: credential
            )

        default:
            throw APIError.notSupported
        }
    }

    /// Renames one of the credential owner's playlists. **One request.**
    ///
    /// - Parameter privacy: the visibility to store, or `nil` to leave whatever
    ///   the playlist has. Ignored on backends without a visibility concept.
    func renamePlaylist(
        id: String,
        title: String,
        privacy: PlaylistPrivacy?,
        instance: Instance,
        credential: String
    ) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).updatePlaylist(
                id: id,
                title: title,
                description: nil,
                privacy: privacy,
                instance: instance,
                sid: credential
            )

        default:
            throw APIError.notSupported
        }
    }

    /// Stores a playlist's description. **One request.**
    ///
    /// - Parameter title: the playlist's title, resent unchanged. Invidious
    ///   edits every attribute through one endpoint and refuses a body without
    ///   a title; Piped has a description endpoint of its own and ignores this.
    func setPlaylistDescription(
        id: String,
        description: String,
        title: String,
        instance: Instance,
        credential: String
    ) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).updatePlaylist(
                id: id,
                title: title,
                description: description,
                privacy: nil,
                instance: instance,
                sid: credential
            )

        default:
            throw APIError.notSupported
        }
    }

    /// Deletes one of the credential owner's playlists.
    func deletePlaylist(id: String, instance: Instance, credential: String) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).deletePlaylist(id: id, instance: instance, sid: credential)
        default:
            throw APIError.notSupported
        }
    }

    /// Appends a video to one of the credential owner's playlists.
    func addVideoToPlaylist(
        playlistID: String,
        videoID: String,
        instance: Instance,
        credential: String
    ) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).addVideoToPlaylist(
                playlistID: playlistID,
                videoID: videoID,
                instance: instance,
                sid: credential
            )
        default:
            throw APIError.notSupported
        }
    }

    /// Removes one row from one of the credential owner's playlists.
    ///
    /// The entry id says which backend minted it, and it has to be the one this
    /// instance runs: an Invidious `indexId` means nothing to Piped, and a
    /// Piped position sent to Invidious would be a *different row* rather than
    /// an error, so a mismatch is refused rather than translated.
    func removeEntry(
        _ entryID: RemotePlaylistEntryID,
        instance: Instance,
        credential: String
    ) async throws {
        guard case .invidious(let playlistID, let indexID) = entryID else { throw APIError.invalidRequest }
        try await invidiousAPI(for: instance).removeVideoFromPlaylist(
            playlistID: playlistID, indexID: indexID, instance: instance, sid: credential
        )
    }

    // MARK: - Watch History

    /// One page of the credential owner's server-side watch history.
    ///
    /// Invidious is the only backend with a history endpoint at all; the
    /// capability gate above this refuses the others long before here.
    func watchHistory(
        instance: Instance,
        credential: String,
        page: Int,
        maxResults: Int
    ) async throws -> [String] {
        switch instance.type {
        case .invidious:
            return try await invidiousAPI(for: instance).watchHistory(
                instance: instance,
                sid: credential,
                page: page,
                maxResults: maxResults
            )
        default:
            throw APIError.notSupported
        }
    }

    /// Records a video as watched in the credential owner's history.
    func markWatched(videoID: String, instance: Instance, credential: String) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).markWatched(
                videoID: videoID,
                instance: instance,
                sid: credential
            )
        default:
            throw APIError.notSupported
        }
    }

    /// Removes one video from the credential owner's history.
    func removeWatched(videoID: String, instance: Instance, credential: String) async throws {
        switch instance.type {
        case .invidious:
            try await invidiousAPI(for: instance).removeWatched(
                videoID: videoID,
                instance: instance,
                sid: credential
            )
        default:
            throw APIError.notSupported
        }
    }

    // MARK: - Authentication

    /// Signs in to an instance and returns the credential its backend issues —
    /// a session id for Invidious, an auth token for Piped.
    ///
    /// Routed through here so a login carries the same per-instance
    /// configuration every other request does: the reverse-proxy basic auth, the
    /// certificate policy, and the User-Agent some instances insist on. A login
    /// that skipped any of them would fail before reaching the login endpoint.
    func login(username: String, password: String, instance: Instance) async throws -> String {
        switch instance.type {
        case .invidious:
            // Invidious' login POST runs on its own ephemeral URLSession so it
            // can read the Set-Cookie the SID arrives in, and therefore inherits
            // nothing from the client's default headers. An instance behind a
            // basic-auth proxy needs that header handed over explicitly, or the
            // proxy answers 401 before the upstream ever sees the credentials.
            var extraHeaders: [String: String]?
            if let basicAuthHeader = await basicAuthCredentialsManager?.basicAuthHeader(for: instance) {
                extraHeaders = ["Authorization": basicAuthHeader]
            }
            return try await invidiousAPI(for: instance).login(
                email: username,
                password: password,
                instance: instance,
                extraHeaders: extraHeaders
            )
        default:
            // Routing, not policy: whether a backend has accounts to sign in to
            // is `InstanceType.accountCapabilities.supportsAccounts`, and a case
            // belongs here the moment that row turns true.
            throw APIError.notSupported
        }
    }

    /// Fetches video details + streams for downloads. For Yattee Server this routes
    /// through `/proxy/fast/`, which caches the file on disk on the server.
    func videoWithProxyStreamsAndCaptionsAndStoryboards(id: String, instance: Instance) async throws -> (video: Video, streams: [Stream], captions: [Caption], storyboards: [Storyboard]) {

        var result = try await videoWithStreamsAndCaptionsAndStoryboards(id: id, instance: instance)
        result.streams = await InvidiousAPI.proxyStreamsIfNeeded(result.streams, instance: instance)
        return result
    }

    /// Fetches video details, streams, and captions in a single API call (Invidious and Yattee Server).
    /// For other backends, falls back to separate calls.
    func videoWithStreamsAndCaptions(id: String, instance: Instance) async throws -> (video: Video, streams: [Stream], captions: [Caption]) {
        let result = try await videoWithStreamsAndCaptionsAndStoryboards(id: id, instance: instance)
        return (result.video, result.streams, result.captions)
    }

    /// Fetches video details, streams, captions, and storyboards in a single API call.
    /// Storyboards are only available for Invidious and Yattee Server instances.
    func videoWithStreamsAndCaptionsAndStoryboards(id: String, instance: Instance) async throws -> (video: Video, streams: [Stream], captions: [Caption], storyboards: [Storyboard]) {
        switch instance.type {
        case .invidious:
            return try await invidiousAPI(for: instance).videoWithStreamsAndCaptionsAndStoryboards(id: id, instance: instance)
        }
    }

    // MARK: - External URL Extraction

    /// Extracts video information from any URL that yt-dlp supports.
    /// Requires a Yattee Server instance.
    ///
    /// - Parameters:
    ///   - url: The URL to extract (e.g., https://vimeo.com/12345)
    ///   - instance: A Yattee Server instance
    /// - Returns: Tuple of video, streams, and captions

    /// How long an extraction is reused. A link opened from Open Link is
    /// extracted to show its details page, which re-extracts for full details,
    /// and Play extracts again; all three share one Yattee Server request.
    /// Short, so a retry after a failed stream soon fetches fresh URLs.
    private static let extractionCacheTTL: TimeInterval = 60
    private var recentExtractions: [String: (result: (video: Video, streams: [Stream], captions: [Caption]), date: Date)] = [:]

    /// Extracts channel/user videos from any URL that yt-dlp supports.
    /// Requires a Yattee Server instance.
    ///
    /// This works with Vimeo, Dailymotion, SoundCloud, and many other sites.
    /// Note that some sites (like Twitter/X) may not support channel extraction.
    ///
    /// - Parameters:
    ///   - url: The channel/user URL to extract (e.g., https://vimeo.com/username)
    ///   - page: Page number (1-based)
    ///   - instance: A Yattee Server instance
    /// - Returns: Tuple of channel, videos list, and optional continuation token for next page

    // MARK: - Yattee Server Info

    /// Fetches server info including version, dependencies, and enabled sites.
    /// Requires a Yattee Server instance.

}

/// The real transport behind ``AccountService``. Declared here rather than on
/// the protocol's own file so the conformance is checked next to the methods
/// that satisfy it; the protocol exists so tests can script a server.
extension ContentService: RemotePlaylistTransport {}

extension ContentService: WatchHistoryTransport {}

// MARK: - Feed Page

/// One page of an authenticated feed, with whatever the backend says about
/// there being another.
struct FeedPage: Sendable {
    let videos: [Video]
    let hasMore: Bool
}

// MARK: - Search Result

enum OrderedSearchItem: Sendable {
    case video(Video)
    case channel(Channel)
    case playlist(Playlist)
}

struct SearchResult: Sendable {
    let videos: [Video]
    let channels: [Channel]
    let playlists: [Playlist]
    let orderedItems: [OrderedSearchItem]  // Preserves original API order
    let nextPage: Int?

    static let empty = SearchResult(videos: [], channels: [], playlists: [], orderedItems: [], nextPage: nil)
}

// MARK: - Channel Search Result

/// Item in channel search results, preserving API order for mixed video/playlist display.
enum ChannelSearchItem: Sendable, Identifiable {
    case video(Video)
    case playlist(Playlist)

    var id: String {
        switch self {
        case .video(let video): return "video-\(video.id.videoID)"
        case .playlist(let playlist): return "playlist-\(playlist.id.playlistID)"
        }
    }
}

/// Page of channel search results.
struct ChannelSearchPage: Sendable {
    let items: [ChannelSearchItem]
    let nextPage: Int?

    static let empty = ChannelSearchPage(items: [], nextPage: nil)
}
