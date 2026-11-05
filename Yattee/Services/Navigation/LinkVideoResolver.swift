//
//  LinkVideoResolver.swift
//  Yattee
//
//  Turns a link into a video and its streams, and queues downloads from them.
//  Shared by the Open Link sheet and URL scheme actions.
//

import Foundation

@MainActor
struct LinkVideoResolver {
    let appEnvironment: AppEnvironment

    /// Resolves a link to a playable video with its streams, captions and
    /// storyboards: YouTube/PeerTube through the matching source, direct media
    /// as-is, anything else through Yattee Server's extraction.
    func resolve(_ url: URL) async throws -> (Video, [Stream], [Caption], [Storyboard]) {
        guard case .video(.id(let videoID), _) = URLRouter().route(url),
              case .global(let provider) = videoID.source, provider == ContentSource.youtubeProvider else {
            throw LinkResolveError.unsupportedYouTubeLink
        }
        guard let instance = appEnvironment.instancesManager.instance(for: videoID.source) else {
            throw LinkResolveError.noInstanceAvailable
        }
        return try await appEnvironment.contentService.videoWithProxyStreamsAndCaptionsAndStoryboards(id: videoID.videoID, instance: instance)
    }

    /// Resolves a link to the screen that shows it: a video's details page
    /// (loaded here so a bad link fails before navigating), or the playlist /
    /// channel screen, which loads its own content. A `?t=` timestamp is
    /// carried to the details page's Play.
    func resolveDestination(_ url: URL) async throws -> NavigationDestination {
        let router = URLRouter()
        let url = router.unwrapped(url)
        let startTime = router.parseTimestamp(url)

        @MainActor func details(_ video: Video) async -> NavigationDestination {
            let context = await queueContext(for: video, from: url, startTime: startTime)
            return .video(.loaded(video), queueContext: context)
        }

        let destination = router.route(url)
        switch destination {
        case .video(.id(let videoID), _):
            guard let instance = appEnvironment.instancesManager.instance(for: videoID.source) else {
                throw LinkResolveError.noInstanceAvailable
            }
            let video = try await appEnvironment.contentService.video(id: videoID.videoID, instance: instance)
            return await details(video)

        case .video(.loaded(let video), _):
            return await details(video)

        case nil:
            throw LinkResolveError.unsupportedYouTubeLink
        case .some(let destination):
            return destination
        }
    }

    /// Plays a video opened from a link. A watch link inside a playlist
    /// (`watch?v=X&list=Y`) plays it with the playlist queued around it;
    /// if the playlist can't be loaded, the video plays alone.
    func play(_ video: Video, from url: URL?, startTime: TimeInterval?) async {
        let context = await queueContext(for: video, from: url, startTime: startTime)
        if let videos = context.videoList, let index = context.videoIndex {
            appEnvironment.queueManager.playFromList(
                videos: videos,
                index: index,
                queueSource: context.queueSource,
                sourceLabel: context.sourceLabel,
                startTime: startTime,
                forceStartTime: startTime != nil
            )
        } else {
            appEnvironment.playerService.openVideo(video, startTime: startTime, forceStartTime: startTime != nil)
        }
    }

    /// Shared by direct playback and loaded details/Opened Links rows. The
    /// content service's playlist API loads all pages before building context.
    private func queueContext(for video: Video, from url: URL?, startTime: TimeInterval?) async -> VideoQueueContext {
        var context = VideoQueueContext.single(video)
        if let url, appEnvironment.queueManager.isQueueEnabled,
           let listID = URLRouter().youTubePlaylistContext(url) {
            do {
                let playlist = try await playlist(for: .remote(.global(listID), instance: nil))
                if let playlistContext = VideoQueueContext.playlist(playlist, startingAt: video) {
                    context = playlistContext
                    LoggingService.shared.logPlayer(
                        "Link playlist \(listID): loaded \(playlist.videos.count) videos, starting at index \(playlistContext.videoIndex ?? 0)"
                    )
                } else {
                    LoggingService.shared.warning(
                        "Link playlist \(listID) does not contain video \(video.id.videoID); playing video alone",
                        category: .player
                    )
                }
            } catch {
                LoggingService.shared.logPlayerError("Failed to load link playlist \(listID); playing video alone", error: error)
            }
        }
        context.linkStartTime = startTime
        return context
    }

    /// Loads a remote playlist with its videos from the instance suited to it.
    func playlist(for source: PlaylistSource) async throws -> Playlist {
        guard case .remote(let playlistID, let instance, _, _) = source else {
            throw LinkResolveError.notAVideo
        }
        guard let instance = instance
                ?? playlistID.source.flatMap({ appEnvironment.instancesManager.playlistInstance(for: $0) }) else {
            throw LinkResolveError.noInstanceAvailable
        }
        return try await appEnvironment.contentService.playlist(id: playlistID.playlistID, instance: instance)
    }

    /// Enqueues a single video for download with already-fetched streams.
    func enqueueDownload(video: Video, streams: [Stream]) async throws {
        guard let stream = AudioStreamSelector.downloadStream(from: streams, preferredLanguage: appEnvironment.settingsManager.preferredAudioLanguage) else {
            throw DownloadError.noStreamAvailable
        }
        try await appEnvironment.downloadManager.enqueue(video, stream: stream)
    }

    func downloadLinks(_ urls: [URL]) async -> (succeeded: Int, failed: Int) {
        var succeeded = 0
        var failed = 0
        for url in urls {
            do {
                let (video, streams, _, _) = try await resolve(url)
                try await enqueueDownload(video: video, streams: streams)
                succeeded += 1
            } catch { failed += 1 }
        }
        return (succeeded, failed)
    }

}

// MARK: - Errors
enum LinkResolveError: LocalizedError {
    case noInstanceAvailable
    case notAVideo
    case unsupportedYouTubeLink

    var errorDescription: String? {
        switch self {
        case .noInstanceAvailable:
            return String(localized: "openLink.noInstance")
        case .notAVideo:
            return String(localized: "openLink.notAVideo")
        case .unsupportedYouTubeLink:
            return String(localized: "openLink.unsupportedYouTubeLink")
        }
    }
}
