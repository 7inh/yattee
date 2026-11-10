//
//  PlayerService.swift
//  Yattee
//
//  Service managing video playback with pluggable backends.
//

import Foundation
import AVFoundation
import Combine
import SwiftUI

/// Protocol for player service delegate callbacks.
@MainActor
protocol PlayerServiceDelegate: AnyObject {
    func playerService(_ service: PlayerService, didUpdateTime time: TimeInterval)
    func playerService(_ service: PlayerService, didChangeState state: PlaybackState)
    func playerService(_ service: PlayerService, didEncounterError error: Error)
    func playerService(_ service: PlayerService, shouldSkipSegment segment: SponsorBlockSegment) -> Bool
    func playerServiceDidFinishPlaying(_ service: PlayerService)
}

/// Main service for video playback.
@MainActor
@Observable
final class PlayerService {
    // MARK: - Properties

    /// The current player backend.
    private(set) var currentBackend: (any PlayerBackend)?

    /// The type of backend currently in use.
    var currentBackendType: PlayerBackendType {
        currentBackend?.backendType ?? preferredBackendType
    }

    /// User's preferred backend type (reads directly from settings for live updates).
    var preferredBackendType: PlayerBackendType {
        settingsManager?.preferredBackend ?? .avFoundation
    }

    /// Observable player state.
    let state: PlayerState

    /// Delegate for callbacks.
    weak var delegate: PlayerServiceDelegate?

    /// Available streams for the current video.
    private(set) var availableStreams: [Stream] = []

    /// Original (unproxied) streams from the API, used to re-apply proxy when settings change.
    private var originalStreams: [Stream] = []

    /// The current download being played, if any.
    private(set) var currentDownload: Download?

    /// Whether online streams are currently being loaded.
    private(set) var isLoadingOnlineStreams: Bool = false

    // MARK: - Dependencies

    private let contentService: ContentService
    private let sponsorBlockAPI: SponsorBlockAPI
    private let returnYouTubeDislikeAPI: ReturnYouTubeDislikeAPI
    private let dataManager: DataManager
    private let backendFactory: BackendFactory
    private weak var settingsManager: SettingsManager?
    private weak var downloadManager: DownloadManager?
    private weak var navigationCoordinator: NavigationCoordinator?
    private weak var connectivityMonitor: ConnectivityMonitor?
    private weak var toastManager: ToastManager?
    private weak var queueManager: QueueManager?
    private weak var playerControlsLayoutService: PlayerControlsLayoutService?
    private weak var handoffManager: HandoffManager?
    private weak var watchHistorySyncService: WatchHistorySyncService?

    // MARK: - Private State

    /// Current scene phase, updated by handleScenePhase
    private var currentScenePhase: ScenePhase = .active

    private var progressSaveTimer: Timer?
    private let progressSaveInterval: TimeInterval = 5
    /// Last position written by the periodic progress save.
    private var lastSavedProgress: (videoID: String, seconds: TimeInterval)?

    /// Now Playing service for Control Center/Lock Screen.
    private let nowPlayingService = NowPlayingService()

    /// Service to prevent system sleep during playback.
    private let sleepPreventionService = SleepPreventionService()

    /// Tracks the last skipped segment to prevent duplicate skips.
    private var lastSkippedSegmentID: String?

    /// 5-second bucket of the last Now Playing elapsed-time update.
    private var lastNowPlayingTimeBucket: Int?

    /// Tracks if the current video ended naturally (reached EOF).
    /// Used to prevent saving progress when switching to next video after natural completion.
    private var videoEndedNaturally = false

    /// Prevents pending loads or backend recovery from undoing a sleep timer pause.
    private var isPausedBySleepTimer = false

    /// Bumped every time the playback identity changes hands: a load claiming
    /// the player, or a teardown clearing it. Work that suspends mid-playback
    /// captures it and compares on the way back, so a continuation belonging to
    /// a watch that is over cannot act on the one that replaced it — including
    /// when the replacement is the very same video, which an ID check alone
    /// cannot tell apart.
    private var playbackGeneration = 0

    /// Current playback task - cancelled when video is closed or new video is opened.
    private var currentPlayTask: Task<Void, Never>?

    /// Video ID that we're currently loading - used to ignore stale time updates from previous video.
    private var loadingVideoID: VideoID?

    /// Counter for stream refresh attempts to prevent infinite refresh loops.
    private var streamRefreshAttempts = 0
    private let maxStreamRefreshAttempts = 2

    /// Tracks if playback was interrupted by system (phone call, alarm, etc.)
    /// Used to auto-resume when interruption ends.
    private var wasInterrupted = false

    /// Token for the audio session interruption observer.
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(
        httpClient: HTTPClient,
        contentService: ContentService,
        dataManager: DataManager,
        backendFactory: BackendFactory? = nil
    ) {
        self.contentService = contentService
        self.dataManager = dataManager
        self.sponsorBlockAPI = SponsorBlockAPI(httpClient: httpClient)
        self.returnYouTubeDislikeAPI = ReturnYouTubeDislikeAPI(httpClient: httpClient)
        self.state = PlayerState()

        let factory = backendFactory ?? BackendFactory()
        self.backendFactory = factory

        // Link now playing service back to player
        nowPlayingService.playerService = self

        // Stop re-rendering the hidden player UI on every time update while
        // the app is in the background (see PlayerState.publishesTimeUpdates).
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.publishesTimeUpdates = false
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.state.publishesTimeUpdates = true
                SleepTimer.shared.checkForExpiration()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    // MARK: - Public Methods

    /// Plays a video with optional starting time.
    /// - Parameters:
    ///   - video: The video to play
    ///   - stream: Optional specific stream to use (if provided, skips fetching streams from API)
    ///   - audioStream: Optional separate audio stream (for video-only streams)
    ///   - startTime: Optional start time in seconds
    ///   - forceStartTime: When true, startTime is an explicit user request (timed link,
    ///     chapter tap) and is honored even past the completion threshold
    func play(video: Video, stream: Stream? = nil, audioStream: Stream? = nil, startTime: TimeInterval? = nil, forceStartTime: Bool = false) async {
        isPausedBySleepTimer = false

        // Downloaded/local files bypass stream selection (they arrive here as
        // ready-made file:// streams), so audio mode is applied at this choke
        // point instead of in selectStreams.
        var stream = stream
        var audioStream = audioStream
        if let provided = stream {
            (stream, audioStream) = (audioStream ?? provided, nil)
        }

        // Set up audio session when playback actually starts (not at app launch)
        setupAudioSession()

        let isNewVideo = state.currentVideo?.id != video.id

        // Save progress and sync for previous video before switching
        // Skip if video ended naturally - 100% was already saved in backendDidFinishPlaying
        if state.currentVideo != nil && isNewVideo && !videoEndedNaturally {
            saveProgressAndSync()
        }

        // Mirror this watch into the active account's server history.
        // Unconditional, and the service decides: `isNewVideo` is already false
        // for most openings, because openVideo() puts the video into state
        // before this task runs. The service compares against the session it is
        // holding instead, which keeps a reload of the same video — an
        // audio-mode toggle, a quality switch, a stream retry — from posting it
        // a second time.
        watchHistorySyncService?.beginSessionIfNeeded(video: video)

        // This load is the playback from here on
        playbackGeneration += 1
        state.playbackIntent.reset()
        let loadGeneration = playbackGeneration

        // Reset flag for the new video
        videoEndedNaturally = false

        // Clear the previous video's track list when transitioning to a new
        // video so the player settings sheet doesn't show stale tracks.
        // Skipped for same-video calls (e.g. in-video quality switch) so the
        // full stream list kept around for the picker survives the switch.
        if isNewVideo {
            availableStreams = []
        }

        // The audio backend does not expose embedded video/subtitle tracks.

        // Clear sponsor block state from previous video
        state.sponsorSegments = []
        state.currentSegment = nil
        lastSkippedSegmentID = nil

        // Reset stream refresh counter for new video
        streamRefreshAttempts = 0

        // Clear caption state from previous video
        // (will be set later if this video has captions)

        // Mark that we're loading this video - time updates will be ignored until loading completes
        loadingVideoID = video.id

        // Release the gate on any exit path (a newer play() claims it with its own
        // id, so only clear our own). Prevents the time-update gate from leaking if
        // the load flow exits early (issue #956).
        defer {
            if playbackGeneration == loadGeneration { loadingVideoID = nil }
        }

        state.setPlaybackState(.loading)
        state.isFirstFrameReady = false  // Reset until first frame of new video is rendered
        state.isBufferReady = false  // Reset until buffer is ready for smooth playback
        state.setCurrentVideo(video, stream: stream, audioStream: audioStream)

        // Start fetching SponsorBlock segments early (in parallel with stream loading)
        // so we have them ready before playback starts
        var sponsorBlockTask: Task<Void, Never>?
        if stream == nil, case .global = video.id.source, settingsManager?.sponsorBlockEnabled == true {
            sponsorBlockTask = Task {
                await fetchSponsorBlockSegments(for: video.id.videoID)
            }
        }

        do {
            var selectedStream: Stream
            var selectedAudioStream: Stream?
            let backendType: PlayerBackendType

            // If a stream is provided (e.g., local/downloaded file or quality switch), use it directly
            if let providedStream = stream {
                selectedStream = providedStream
                selectedAudioStream = audioStream
                backendType = preferredBackendType
                // Only set availableStreams if empty (preserve existing streams during quality switch)
                if availableStreams.isEmpty {
                    self.availableStreams = [audioStream, providedStream].compactMap { $0 }.filter(\.isAVPlayerAudioPlayable)
                }
                state.setCurrentVideo(video, stream: providedStream, audioStream: audioStream)
                // Mark details as loaded since we're using the video as-is
                state.videoDetailsState = .loaded
                lockDurationIfNeeded(for: video, stream: providedStream)

            } else {
                // Mark that we're loading video details from API
                state.videoDetailsState = .loading

                // Fetch full video details (includes description), streams, captions, and storyboards in one API call
                let (fullVideo, streams, _, _) = try await fetchVideoStreamsAndCaptionsAndStoryboards(for: video)

                // Check for cancellation after network fetch
                try Task.checkCancellation()
            guard playbackGeneration == loadGeneration else { throw CancellationError() }

                self.availableStreams = streams.filter(\.isAVPlayerAudioPlayable)

                // Select best stream for preferred backend
                let selection = selectStreamAndBackend(from: streams)

                guard let selected = selection.stream else {
                    throw APIError.noStreams
                }

                selectedStream = selected
                selectedAudioStream = selection.audioStream
                backendType = selection.backend

                // Update state with full video details and selected stream
                state.setCurrentVideo(fullVideo, stream: selectedStream, audioStream: selectedAudioStream)
                CachedChannelData.cacheAuthor(fullVideo.author)
                state.videoDetailsState = .loaded
                lockDurationIfNeeded(for: fullVideo, stream: selectedStream)

                // Notify observers that full video details are now available
                NotificationCenter.default.post(name: .videoDetailsDidLoad, object: nil)

            }

            // Enforce audio-only playback for supplied, downloaded and queued
            // streams as well as normal selection. Never load a video fallback.
            guard let audio = bestAudioStream(from: [selectedAudioStream, selectedStream].compactMap { $0 }) ?? bestAudioStream(from: availableStreams) else {
                throw APIError.noStreams
            }
            selectedStream = audio
            selectedAudioStream = nil
            state.setCurrentVideo(state.currentVideo ?? video, stream: audio, audioStream: nil)

            // Audio-only streams never report a video size, so the previous
            // video's aspect ratio would stick to the player area forever.
            // Reset it so the UI falls back to the standard 16:9.
            if selectedStream.isAudioOnly {
                state.videoAspectRatio = nil
            }

            // Check for cancellation before loading stream
            try Task.checkCancellation()
            guard playbackGeneration == loadGeneration else { throw CancellationError() }

            // Calculate seek time BEFORE loading to know if we need to prepare for initial seek
            // This prevents the thumbnail from hiding before the resume position is reached
            let seekTime: TimeInterval
            // Use state.duration as fallback for quality switching when video.duration might be 0
            let effectiveDuration = video.duration > 0 ? video.duration : state.duration
            let completionThreshold = effectiveDuration * 0.9
            let savedProgress = dataManager.watchProgress(for: video.id.videoID)
            LoggingService.shared.logPlayer("Replay check: savedProgress=\(savedProgress ?? -1), startTime=\(startTime ?? -1), duration=\(video.duration), threshold=\(completionThreshold)")

            if video.isLive || selectedStream.isLive {
                // Live playback positions are relative to the live edge, so a stored
                // or passed position means nothing - always start at the live edge.
                seekTime = 0
            } else if let startTime {
                // Explicit startTime provided - use it (0 means play from beginning, >0 means resume)
                // For quality switching with startTime > 0, honor the time unless video was completed
                if forceStartTime {
                    // User-requested timestamp (timed link, chapter tap) - always honor it,
                    // clamped so an out-of-range value can't seek past the end.
                    seekTime = effectiveDuration > 0 ? min(startTime, max(0, effectiveDuration - 1)) : startTime
                } else if startTime > 0 && completionThreshold > 0 && startTime >= completionThreshold {
                    seekTime = 0  // Video was completed, start over
                } else {
                    seekTime = startTime
                }
            } else if let savedProgress, savedProgress > 0, savedProgress < completionThreshold {
                // No explicit startTime - use saved progress if video wasn't completed
                seekTime = savedProgress
            } else {
                // No saved progress or video was completed
                seekTime = 0
            }

            // Create or switch backend if needed
            let backend = try await ensureBackend(type: backendType)

            // Apply volume based on volume mode setting from active preset
            let volumeMode: VolumeMode
            if let layoutService = playerControlsLayoutService {
                let layout = await layoutService.activeLayout()
                volumeMode = layout.globalSettings.volumeMode
            } else {
                volumeMode = GlobalLayoutSettings.cached.volumeMode
            }

            try Task.checkCancellation()
            guard playbackGeneration == loadGeneration else { throw CancellationError() }
            if seekTime > 0 { backend.prepareForInitialSeek() }

            if volumeMode == .inApp {
                // In-app mode: use persisted volume
                backend.volume = settingsManager?.playerVolume ?? 1.0
                state.volume = backend.volume
            } else {
                // System mode: set player to max, let device control volume
                backend.volume = 1.0
                state.volume = 1.0
            }

            backend.rate = Float(state.rate.rawValue)

            // Load the standalone audio rendition.
            try await backend.load(stream: selectedStream, audioStream: selectedAudioStream, autoplay: false)

            // Check for cancellation after stream load completes
            try Task.checkCancellation()
            guard playbackGeneration == loadGeneration else { throw CancellationError() }

            if seekTime > 0 {
                await backend.seek(to: seekTime, showLoading: false)
            }

            // Wait for player sheet animation to complete before starting playback
            await navigationCoordinator?.waitForPlayerSheetAnimation()

            // Wait for SponsorBlock segments (started earlier in parallel with stream loading)
            // This ensures we have segments before playback starts, so intro skips can show loading
            await sponsorBlockTask?.value

            // Resolve chapters after SponsorBlock segments are available
            // Uses hierarchy: SponsorBlock chapters > description parsing
            let videoForChapters = state.currentVideo ?? video
            resolveChapters(for: videoForChapters)

            LoggingService.shared.logPlayer("Setting up Now Playing info before backend.play()")
            // Establish lock-screen metadata before playback starts.
            // The system listens to the play event to trigger Now Playing display,
            // so metadata must be established before playback begins.
            let videoForNowPlaying = state.currentVideo ?? video
            nowPlayingService.updateNowPlaying(
                video: videoForNowPlaying,
                currentTime: seekTime,
                duration: videoForNowPlaying.duration,
                isPlaying: true
            )

            // Load artwork asynchronously (can happen in parallel with playback)
            // For downloaded videos, use local thumbnail if available for offline playback
            Task { [downloadManager] in
                var localThumbnailURL: URL?
                if let downloadManager,
                   let download = downloadManager.download(for: videoForNowPlaying.id),
                   let localThumbnailPath = download.localThumbnailPath {
                    localThumbnailURL = downloadManager.downloadsDirectory().appendingPathComponent(localThumbnailPath)
                }
                // Reliable (hqdefault) variant: artwork is a single fetch with no
                // fallback, and the best advertised variant often 404s.
                await nowPlayingService.loadArtwork(
                    from: videoForNowPlaying.reliableThumbnailURL,
                    localPath: localThumbnailURL
                )
            }

            // Start playback
            LoggingService.shared.logPlayer("Calling backend.play(), playbackState: \(state.playbackState)")
            loadingVideoID = nil  // Clear loading flag - time updates are now valid
            updateSleepPrevention()

            // AVPlayerItem is ready; AVPlayer manages network buffering.
            state.isBufferReady = true
            state.bufferProgress = nil  // Clear buffer progress since buffering is complete

            try Task.checkCancellation()
            guard playbackGeneration == loadGeneration else { throw CancellationError() }

            if isPausedBySleepTimer {
                pause()
            } else {
                state.playbackIntent.setPlaying(true)
                backend.play()
            }

            // Update Handoff activity for cross-device continuation
            handoffManager?.updateActivity(for: .video(.id(video.id)))

            // Fetch dislike counts for YouTube videos (only for online content)
            // Note: SponsorBlock is fetched earlier in parallel with stream loading
            // Note: Captions are now fetched together with video details and streams
            if stream == nil, case .global = video.id.source {
                await fetchReturnYouTubeDislikeCounts(for: video.id.videoID)
            }

            // Start progress saving
            startProgressSaveTimer()

            // Notify queue manager that video started (for proactive continuation loading)
            notifyVideoStarted()

            LoggingService.shared.logPlayer("Playback started: \(video.id.id)", details: "Stream: \(selectedStream.qualityLabel)")

        } catch is CancellationError {
            // Load was cancelled because a new video was selected - don't report as error
            LoggingService.shared.logPlayer("Playback cancelled: \(video.id.id)")
            sleepPreventionService.allowSleep()
        } catch {
            // If the user has already switched to a different video while this one was
            // still loading/retrying, suppress the error — it no longer applies to what
            // is on screen. loadingVideoID is reassigned by every new play() call and
            // cleared on success, so a mismatch means we are no longer the active load.
            guard playbackGeneration == loadGeneration else {
                LoggingService.shared.logPlayer("Ignoring stale playback error for \(video.id.id) — user switched videos")
                sleepPreventionService.allowSleep()
                return
            }

            LoggingService.shared.logPlayerError("Playback failed: \(video.id.id)", error: error)
            sleepPreventionService.allowSleep()
            state.videoDetailsState = .error
            state.setPlaybackState(.failed(error))
            delegate?.playerService(self, didEncounterError: error)

            // Auto-skip to next video if queue is not empty and player is not visible
            await handlePlaybackErrorAutoSkip()
        }
    }

    /// Reconciles sleep prevention with what is actually on screen: display sleep
    /// is only prevented when a video track is rendered. Audio-only playback
    /// lets the screen sleep normally.
    ///
    /// tvOS is the exception: idle there means screensaver and then device sleep,
    /// which suspends the app, stops playback, and powers the TV off over CEC.
    /// Audio-only playback must keep the idle timer disabled as well.
    private func updateSleepPrevention() {
        if state.currentStream?.isAudioOnly == true {
            sleepPreventionService.allowSleep()
        } else {
            sleepPreventionService.preventSleep()
        }
    }

    /// Pauses playback.
    /// - Parameter shouldSaveProgress: Whether to save watch progress. Set to `false` when video has
    ///   already ended (100% was saved in `backendDidFinishPlaying`).
    func pause(saveProgress shouldSaveProgress: Bool = true) {
        state.playbackIntent.setPlaying(false)
        sleepPreventionService.allowSleep()
        currentBackend?.pause()
        state.setPlaybackState(.paused)
        // A sleep timer leaves a completed video paused rather than ended.
        // Preserve its completion when a later control action pauses it again.
        let shouldSaveProgress = shouldSaveProgress && !videoEndedNaturally
        if shouldSaveProgress {
            saveProgress()
        }
        nowPlayingService.updatePlaybackRate(isPlaying: false, currentTime: state.currentTime)
    }

    /// Uses the normal pause path, while keeping a pending load from starting later.
    func pauseForSleepTimer() {
        guard state.currentVideo != nil else { return }
        isPausedBySleepTimer = true
        wasInterrupted = false
        pause(saveProgress: !videoEndedNaturally && state.playbackState != .ended)
    }

    /// Applies a persistent speed selection to playback and system metadata.
    func setPlaybackRate(_ rate: PlaybackRate) {
        state.rate = rate
        rate.save()
        currentBackend?.rate = Float(rate.rawValue)
        nowPlayingService.updatePlaybackRate(
            isPlaying: state.playbackState == .playing,
            currentTime: state.currentTime
        )
    }

    /// Resumes playback.
    func resume() {
        state.playbackIntent.setPlaying(true)
        if isPausedBySleepTimer && videoEndedNaturally {
            Task { await replayCurrentVideo() }
            return
        }
        isPausedBySleepTimer = false

        updateSleepPrevention()
        currentBackend?.play()
        state.setPlaybackState(.playing)
        nowPlayingService.updatePlaybackRate(isPlaying: true, currentTime: state.currentTime)
    }

    /// Toggles shared intent immediately and coalesces rapid taps before commanding the backend.
    func togglePlayPause() {
        guard state.currentVideo != nil else { return }
        state.playbackIntent.toggle { [weak self] playing in
            guard let self else { return }
            LoggingService.shared.debug("Applying playback intent: playing=\(playing), backend=\(state.playbackState)", category: .player)
            if playing {
                if state.playbackState == .ended || videoEndedNaturally {
                    await replayCurrentVideo()
                } else {
                    resume()
                }
            } else {
                pause()
            }
        }
        LoggingService.shared.debug("Playback intent changed: playing=\(state.isPlayingIntended), backend=\(state.playbackState)", category: .player)
    }

    /// Plays the current video again from the beginning, as a new watch.
    ///
    /// Every way a *finished* video is started again comes through here: the
    /// replay button, the end-of-queue overlay, repeat-one, play/pause on an
    /// ended video. Each of those is a second watch of the same video, so the
    /// mirroring session is started fresh and the video is posted to the
    /// account's history again — which is what moves it back to the front.
    /// Seeking to the start mid-video is not this, and does not pass here.
    func replayCurrentVideo() async {
        let video = state.currentVideo
        if let video {
            watchHistorySyncService?.beginSession(video: video)
        }

        // The end of the previous watch left the player set up for a video that
        // is over: no save timer, and the natural-end flag that tells play() the
        // final save is already done. A second watch has to undo both, in the
        // order play() does it — the flag before the seek, the timer only once
        // playback is running again, so a seek that never gets there cannot
        // leave a timer saving progress for an ended video.
        videoEndedNaturally = false

        let generation = playbackGeneration
        await seek(to: 0)

        // The seek is awaited, and the player can have moved on while it ran:
        // stopped, playing something else, or stopped and given this same video
        // a fresh start — which the id alone cannot tell from our own watch.
        // Only the replay that is still the current playback may resume and arm
        // the save timer — otherwise this would unpause a video the user paused
        // or is still loading, or time saves for a watch that is not this one.
        guard !Task.isCancelled, let video, playbackGeneration == generation, state.currentVideo?.id == video.id else { return }

        resume()
        startProgressSaveTimer()
    }

    /// Stops playback and clears the player.
    func stop() {
        sleepPreventionService.allowSleep()

        if let video = state.currentVideo {
            LoggingService.shared.logPlayer("Stopping playback: \(video.id.id)")
        }

        // Cancel any ongoing stream loading
        currentPlayTask?.cancel()
        currentPlayTask = nil

        saveProgressAndSync()
        watchHistorySyncService?.endSession()
        cleanup()

        // Clear Handoff activity
        handoffManager?.invalidateCurrentActivity()

        // Clear video first, then reset (reset clears isClosingVideo)
        state.setCurrentVideo(nil, stream: nil)
        state.reset()
        state.clearHistory()
        availableStreams = []
        originalStreams = []
        lastSkippedSegmentID = nil
        nowPlayingService.clearNowPlaying()
    }

    /// Seeks to a specific time.
    /// - Parameters:
    ///   - time: The time to seek to in seconds
    ///   - showLoading: If true, show loading state during seek (e.g., for early SponsorBlock skips)
    func seek(to time: TimeInterval, showLoading: Bool = false) async {
        state.isSeeking = true
        await currentBackend?.seek(to: time, showLoading: showLoading)
        state.isSeeking = false
        state.currentTime = time
    }

    /// Seeks forward by a duration.
    func seekForward(by seconds: TimeInterval = 10) {
        state.isSeeking = true
        let newTime = state.currentTime + seconds
        Task {
            await currentBackend?.seek(to: newTime, showLoading: false)
            state.isSeeking = false
        }
    }

    /// Seeks backward by a duration.
    func seekBackward(by seconds: TimeInterval = 10) {
        state.isSeeking = true
        let newTime = max(state.currentTime - seconds, 0)
        Task {
            await currentBackend?.seek(to: newTime, showLoading: false)
            state.isSeeking = false
        }
    }

    /// Seeks by a duration in the specified direction.
    /// - Parameters:
    ///   - seconds: Number of seconds to seek.
    ///   - direction: Direction to seek (forward or backward).
    func seek(seconds: TimeInterval, direction: SeekDirection) {
        switch direction {
        case .forward:
            seekForward(by: seconds)
        case .backward:
            seekBackward(by: seconds)
        }
    }

    /// Handles scene phase changes for background playback support.
    func handleScenePhase(_ phase: ScenePhase) {
        currentScenePhase = phase

        // Allow sleep when entering background, re-enable when returning to foreground if playing
        if phase == .background {
            sleepPreventionService.allowSleep()
        } else if phase == .active && state.playbackState == .playing {
            updateSleepPrevention()
        }

        let isPiPActive = false

        // With background playback disabled, pause when the app leaves the
        // foreground — the audio background mode would otherwise keep player
        // playing. Not applicable on macOS, where apps are never suspended.
        let backgroundEnabled = settingsManager?.backgroundPlaybackEnabled ?? true
        if phase == .background, !backgroundEnabled, !isPiPActive, state.playbackState == .playing {
            LoggingService.shared.debug("PlayerService: pausing playback (phase=\(phase), backgroundPlaybackEnabled=false)", category: .player)
            pause()
        }

    }

    /// Plays the next video in queue, respecting the current queue mode.
    func playNext() async {
        if SleepTimer.shared.stopAtEndOfVideo(for: self) { return }

        // Pause without saving progress if video ended - 100% was already saved in backendDidFinishPlaying
        pause(saveProgress: state.playbackState != .ended)

        // Handle queue mode behavior
        switch state.queueMode {
        case .repeatOne:
            // Restart current video — a second watch of it, not a continuation
            await replayCurrentVideo()
            return

        case .repeatAll:
            // If queue is empty but we have history, recycle history back to queue
            if state.queue.isEmpty && !state.history.isEmpty {
                state.recycleHistoryToQueue()
            }
            // Fall through to normal advance behavior

        case .shuffle:
            // Pick random video from queue
            guard let next = state.advanceQueueShuffle() else { return }
            pushCurrentToHistoryIfNeeded()
            await playQueuedVideo(next)
            return

        case .normal:
            break // Use default behavior below
        }

        // Normal/repeatAll advance behavior
        guard let next = state.advanceQueue() else { return }
        pushCurrentToHistoryIfNeeded()
        await playQueuedVideo(next)
    }

    /// Pushes current video to history if not in incognito mode.
    private func pushCurrentToHistoryIfNeeded() {
        guard let currentVideo = state.currentVideo,
              settingsManager?.incognitoModeEnabled != true,
              settingsManager?.saveWatchHistory != false else { return }
        let historyItem = QueuedVideo(
            video: currentVideo,
            stream: state.currentStream,
            audioStream: state.currentAudioStream,
            startTime: state.currentTime
        )
        state.pushToHistory(historyItem)
    }

    /// Plays a queued video with its stream and caption info.
    /// Always starts from the beginning (0) since queue items should play fresh.
    /// Always prefers local downloaded content over pre-loaded network streams.
    /// For media browser videos, resolves stream and captions on-demand.
    private func playQueuedVideo(_ queuedVideo: QueuedVideo) async {
        await playPreferringDownloaded(
            video: queuedVideo.video,
            fallbackStream: queuedVideo.stream,
            fallbackAudioStream: queuedVideo.audioStream,
            startTime: queuedVideo.startTime
        )
    }

    /// Offline files take precedence, including when a queue entry holds an expired network URL.
    func playPreferringDownloaded(
        video: Video,
        fallbackStream: Stream? = nil,
        fallbackAudioStream: Stream? = nil,
        startTime: TimeInterval? = nil,
        forceStartTime: Bool = false
    ) async {
        if let downloadManager,
           let download = downloadManager.download(for: video.id),
           download.status == .completed,
           let (downloadedVideo, stream, _, _, dislikeCount) = downloadManager.videoAndStream(for: download) {
            currentDownload = download
            await play(video: downloadedVideo, stream: stream, startTime: startTime, forceStartTime: forceStartTime)
            state.dislikeCount = dislikeCount
            return
        }
        currentDownload = nil
        await play(video: video, stream: fallbackAudioStream ?? fallbackStream, startTime: startTime, forceStartTime: forceStartTime)
    }

    func isCurrentlyPlaying(video: Video) -> Bool {
        guard let currentVideo = state.currentVideo else { return false }
        guard currentVideo.id == video.id else { return false }

        // Check if we have an active playback state (not idle or failed)
        switch state.playbackState {
        case .playing, .paused, .buffering, .ready, .loading:
            return true
        case .idle, .ended, .failed:
            return false
        }
    }

    /// Opens a video in the player, expanding the player sheet.
    /// If the video is already playing, just expands the player without reloading.
    /// Respects the autoplay setting - if disabled, prepares the video with a play button overlay.
    /// - Parameters:
    ///   - video: The video to open
    ///   - startTime: Optional start time in seconds (used for continue watching)
    ///   - forceStartTime: When true, startTime is an explicit user request (timed link,
    ///     chapter tap) and is honored even past the completion threshold
    func openVideo(_ video: Video, startTime: TimeInterval? = nil, forceStartTime: Bool = false) {
        // Live streams have no meaningful resume position - drop any passed one
        // so callers with a stale watch entry cannot seek into the live window.
        let startTime = video.isLive ? nil : startTime

        // Check if player PiP is active - if so, don't expand the player
        let isPiPActive = false

        // If this video is already loaded, optionally seek/resume instead of reloading.
        if isCurrentlyPlaying(video: video) {
            LoggingService.shared.logPlayer("Video already loaded, applying seek/resume instead of reload (startTime=\(startTime ?? -1), state=\(state.playbackState))")
            if !isPiPActive {
                navigationCoordinator?.expandPlayer()
            }
            let wasPaused = state.playbackState == .paused
            if let startTime {
                Task { @MainActor in
                    await seek(to: startTime)
                    if wasPaused || state.playbackState == .paused {
                        resume()
                    }
                }
            } else if wasPaused {
                resume()
            }
            return
        }

        // Cancel any previous play task before starting a new one
        currentPlayTask?.cancel()

        // The opening owns the player from here, before the load task even runs
        playbackGeneration += 1
        state.playbackIntent.reset()

        // Set video info before expanding so the sheet animates with content visible
        state.setPlaybackState(.loading)
        state.setCurrentVideo(video, stream: nil)

        // Expand player immediately so it opens while loading (unless PiP is active)
        if !isPiPActive {
            navigationCoordinator?.expandPlayer()
        }

        currentPlayTask = Task {
            await playPreferringDownloaded(video: video, startTime: startTime, forceStartTime: forceStartTime)
        }
    }

    /// Opens a video with a specific stream (e.g., for downloaded content or media sources).
    /// If the video is already playing, just expands the player without reloading.
    /// - Parameters:
    ///   - video: The video to open
    ///   - stream: The specific stream to use
    ///   - audioStream: Optional separate audio stream (for video-only streams)
    ///   - download: Optional download to load local storyboards and captions from
    ///   - captions: Optional array of external captions (e.g., from WebDAV subtitle files)
    func openVideo(_ video: Video, stream: Stream, audioStream: Stream? = nil, download: Download? = nil, captions: [Caption] = []) {
        // Check if player PiP is active - if so, don't expand the player
        let isPiPActive = false

        // If this video is already loaded, optionally resume instead of reloading.
        if isCurrentlyPlaying(video: video) {
            if !isPiPActive {
                navigationCoordinator?.expandPlayer()
            }
            if state.playbackState == .paused {
                resume()
            }
            return
        }

        // Cancel any previous play task before starting a new one
        currentPlayTask?.cancel()

        // The opening owns the player from here, before the load task even runs
        playbackGeneration += 1
        state.playbackIntent.reset()

        // Set video info before expanding so the sheet animates with content visible
        state.setPlaybackState(.loading)
        state.setCurrentVideo(video, stream: stream, audioStream: audioStream)

        // Expand player immediately so it opens while loading (unless PiP is active)
        if !isPiPActive {
            navigationCoordinator?.expandPlayer()
        }

        // Try to look up download if not provided but playing local file
        var resolvedDownload = download
        if resolvedDownload == nil, let downloadManager {
            resolvedDownload = downloadManager.download(for: video.id)
        }

        // Store download for reference
        currentDownload = resolvedDownload

        LoggingService.shared.logPlayer("openVideo with stream called - download: \(resolvedDownload != nil ? "present" : "nil")")

        currentPlayTask = Task {
            await play(video: video, stream: audioStream ?? stream)
        }
    }

    /// Plays the previous video in queue.
    /// If more than 3 seconds into current video, restarts it instead.
    func playPrevious() async {
        // Pause without saving progress if video ended - 100% was already saved in backendDidFinishPlaying
        pause(saveProgress: state.playbackState != .ended)

        // If more than 3 seconds in, restart current video
        if state.currentTime > 3 {
            await seek(to: 0)
            resume()
            return
        }

        // Try to go back to previous video in history
        if let previous = state.retreatQueue() {
            // Push current video to front of queue (starts at 0 when replayed)
            if let currentVideo = state.currentVideo {
                state.insertNext(currentVideo, stream: state.currentStream, audioStream: state.currentAudioStream)
            }

            var stream = previous.stream
            var audioStream = previous.audioStream
            if let preResolved = stream, !preResolved.url.isFileURL,
               preResolved.isAudioOnly != (settingsManager?.audioOnlyModeEnabled == true) {
                // Resolved before an audio-mode toggle - discard so selection re-runs
                stream = nil
                audioStream = nil
            }

            // Play the previous video, resuming from saved position
            await play(video: previous.video, stream: stream, audioStream: audioStream, startTime: previous.startTime)
        } else {
            // No history, just restart current video
            await seek(to: 0)
            resume()
        }
    }

    // MARK: - Stream Refresh

    /// Refreshes stream URLs and resumes playback at the specified time.
    /// Called when mid-playback failure is detected (e.g., expired stream URLs).
    private func refreshStreamsAndResume(atTime resumeTime: TimeInterval?) async {
        guard let video = state.currentVideo else {
            LoggingService.shared.logPlayerError("Cannot refresh streams: no current video")
            return
        }

        // Check if we've exceeded refresh attempts
        streamRefreshAttempts += 1
        if streamRefreshAttempts > maxStreamRefreshAttempts {
            LoggingService.shared.logPlayerError("Stream refresh failed: exceeded max attempts (\(maxStreamRefreshAttempts))")
            toastManager?.show(
                category: .playerStatus,
                title: String(localized: "toast.player.streamRefreshFailed.title"),
                icon: "exclamationmark.triangle",
                iconColor: .red,
                autoDismissDelay: 3.0
            )
            // Report error to delegate
            let error = BackendError.loadFailed("Stream refresh failed after \(maxStreamRefreshAttempts) attempts")
            delegate?.playerService(self, didEncounterError: error)
            state.setPlaybackState(.failed(error))
            return
        }

        LoggingService.shared.logPlayer("Refreshing streams (attempt \(streamRefreshAttempts)/\(maxStreamRefreshAttempts))")

        // Show toast that refresh is starting
        toastManager?.show(
            category: .playerStatus,
            title: String(localized: "toast.player.refreshingStream.title"),
            icon: "arrow.clockwise",
            iconColor: .blue,
            autoDismissDelay: 2.0
        )

        do {
            // Fetch fresh streams
            let (_, streams, _) = try await fetchVideoStreamsAndCaptions(for: video)

            guard !streams.isEmpty else {
                throw APIError.noStreams
            }

            // Update available streams
            self.availableStreams = streams.filter(\.isAVPlayerAudioPlayable)

            guard let newStream = findMatchingAudioStream(in: streams, preferring: state.currentStream) else {
                throw APIError.noStreams
            }
            let newAudioStream: Stream? = nil

            LoggingService.shared.logPlayer("Resuming with stream: \(newStream.qualityLabel) at \(resumeTime ?? 0)s")

            // A refresh may have been awaiting the network when the timer fired.
            guard !isPausedBySleepTimer else { return }

            // Resume playback with fresh stream
            await play(video: video, stream: newStream, audioStream: newAudioStream, startTime: resumeTime)

            // Reset refresh counter on success
            streamRefreshAttempts = 0

            // Show success toast
            toastManager?.show(
                category: .playerStatus,
                title: String(localized: "toast.player.streamRefreshed.title"),
                icon: "checkmark.circle",
                iconColor: .green,
                autoDismissDelay: 2.0
            )

        } catch {
            LoggingService.shared.logPlayerError("Stream refresh failed", error: error)

            // If still under max attempts, the next error will trigger another refresh
            // Otherwise, show error to user
            if streamRefreshAttempts >= maxStreamRefreshAttempts {
                toastManager?.show(
                    category: .playerStatus,
                    title: String(localized: "toast.player.streamRefreshFailed.title"),
                    icon: "exclamationmark.triangle",
                    iconColor: .red,
                    autoDismissDelay: 3.0
                )
                delegate?.playerService(self, didEncounterError: error)
                state.setPlaybackState(.failed(error))
            }
        }
    }

    private func findMatchingAudioStream(in streams: [Stream], preferring preferred: Stream?) -> Stream? {
        AudioStreamSelector.select(from: streams, preferredLanguage: preferred?.audioLanguage ?? settingsManager?.preferredAudioLanguage)
    }
    // MARK: - Private Methods

    /// Checks if the stream URL goes through Yattee Server's fast download endpoint.
    /// Fast endpoint streams don't have Content-Length, so player can't determine accurate duration.
    /// In this case, we should use the API-provided duration instead.
    private func isFastEndpointStream(_ stream: Stream?) -> Bool {
        guard let urlString = stream?.url.absoluteString else { return false }
        return urlString.contains("/proxy/fast/")
    }

    /// Locks duration from API if playing through fast endpoint.
    /// This prevents progress bar jitter when player reports changing duration during progressive download.
    private func lockDurationIfNeeded(for video: Video, stream: Stream?) {
        if isFastEndpointStream(stream), video.duration > 0 {
            state.lockDuration(video.duration)
            LoggingService.shared.debug("Locked duration from API: \(video.duration)s (fast endpoint stream)", category: .player)
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try AVAudioBackend.configureAudioSession()

            // Only register observer once
            guard interruptionObserver == nil else { return }

            LoggingService.shared.debug("Registering audio session interruption observer", category: .player)

            // Register for audio interruption notifications (phone calls, alarms, etc.)
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                // Extract values before async boundary to satisfy Sendable requirements
                guard let userInfo = notification.userInfo,
                      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                    return
                }
                let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt

                Task { @MainActor [weak self] in
                    LoggingService.shared.debug("Audio interruption notification received, type: \(type.rawValue), options: \(optionsValue ?? 0)", category: .player)
                    self?.handleAudioSessionInterruption(type: type, optionsValue: optionsValue)
                }
            }
        } catch {
            LoggingService.shared.logPlayerError("Audio session setup failed", error: error)
        }
    }

    private func handleAudioSessionInterruption(type: AVAudioSession.InterruptionType, optionsValue: UInt?) {
        LoggingService.shared.debug("handleAudioSessionInterruption called, current playbackState: \(state.playbackState), wasInterrupted: \(wasInterrupted)", category: .player)

        switch type {
        case .began:
            LoggingService.shared.debug("Audio session interrupted (began), playbackState: \(state.playbackState)", category: .player)
            // Audio was interrupted (phone call, alarm, etc.)
            if state.playbackState == .playing {
                LoggingService.shared.debug("Pausing playback due to interruption", category: .player)
                // Call full pause() to properly pause the backend
                pause()
                wasInterrupted = true
            } else {
                LoggingService.shared.debug("Not pausing - playbackState is not .playing", category: .player)
            }
        case .ended:
            LoggingService.shared.debug("Audio session interruption ended, wasInterrupted: \(wasInterrupted)", category: .player)
            // Interruption ended - check if we should resume
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                LoggingService.shared.debug("Interruption options: shouldResume=\(options.contains(.shouldResume))", category: .player)
                if options.contains(.shouldResume) && wasInterrupted {
                    LoggingService.shared.debug("Auto-resuming playback after interruption", category: .player)
                    // Reactivate audio session before resuming - iOS requires this after interruption
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        LoggingService.shared.debug("Audio session reactivated successfully", category: .player)
                    } catch {
                        LoggingService.shared.error("Failed to reactivate audio session: \(error.localizedDescription)", category: .player)
                    }
                    resume()
                } else {
                    LoggingService.shared.debug("Not auto-resuming: shouldResume=\(options.contains(.shouldResume)), wasInterrupted=\(wasInterrupted)", category: .player)
                }
            } else {
                LoggingService.shared.debug("No interruption options provided", category: .player)
            }
            wasInterrupted = false
        @unknown default:
            LoggingService.shared.debug("Unknown interruption type: \(type.rawValue)", category: .player)
            break
        }
    }

    private func fetchVideoStreamsAndCaptions(for video: Video) async throws -> (Video, [Stream], [Caption]) {
        let result = try await fetchVideoStreamsAndCaptionsAndStoryboards(for: video)
        return (result.0, result.1, result.2)
    }

    private func fetchVideoStreamsAndCaptionsAndStoryboards(for video: Video) async throws -> (Video, [Stream], [Caption], [Storyboard]) {
        guard let instance = try await findInstance(for: video) else {
            throw APIError.noInstance
        }

        // Race the proxy-detection HEAD against the video API call so the
        // verdict is (usually) ready by the time streams come back. Cheap
        // when there's nothing to do — it returns immediately if the
        // verdict is already cached, or if no prior CDN sample exists.
        async let _: Void = InvidiousAPI.prewarmProxyDetection(for: instance)

        // Fetch full video details, streams, captions, and storyboards in a single API call
        // (for Invidious, this is a single request; for other backends, calls are made in parallel)
        let result = try await contentService.videoWithStreamsAndCaptionsAndStoryboards(id: video.id.videoID, instance: instance)

        // Store original (unproxied) streams so we can re-apply proxy when settings change
        self.originalStreams = result.streams

        // Apply proxy URL rewriting for instances that support it
        let streams = await InvidiousAPI.proxyStreamsIfNeeded(result.streams, instance: instance)

        return (result.video, streams, result.captions, result.storyboards)
    }

    /// Re-applies proxy URL rewriting to cached streams when instance settings change.
    /// Uses the stored `originalStreams` to derive the correct URLs without re-fetching from the API.
    private func reapplyProxyToStreams() async {
        guard !originalStreams.isEmpty,
              let video = state.currentVideo,
              let instance = try? await findInstance(for: video) else { return }

        let newStreams = await InvidiousAPI.proxyStreamsIfNeeded(originalStreams, instance: instance)

        // Update available streams (preserve any downloaded/local file streams)
        let downloadedStreams = availableStreams.filter { $0.url.isFileURL }
        availableStreams = downloadedStreams + newStreams

        // Update current stream URL if it changed
        if let currentStream = state.currentStream,
           let matchingNew = newStreams.first(where: { $0.resolution == currentStream.resolution && $0.format == currentStream.format }) {
            if matchingNew.url != currentStream.url {
                state.updateCurrentStream(matchingNew)
                LoggingService.shared.logPlayer("Updated current stream URL after proxy setting change")
            }
        }

        // Update current audio stream URL if it changed
        if let currentAudio = state.currentAudioStream,
           let matchingNew = newStreams.first(where: { $0.resolution == currentAudio.resolution && $0.format == currentAudio.format && $0.isAudioOnly == true }) {
            if matchingNew.url != currentAudio.url {
                state.updateCurrentAudioStream(matchingNew)
                LoggingService.shared.logPlayer("Updated current audio stream URL after proxy setting change")
            }
        }

        LoggingService.shared.logPlayer("Re-applied proxy settings: \(newStreams.count) streams updated")
    }

    /// Creates a stream for media source videos (WebDAV, SMB, or local folder).
    /// For WebDAV, adds authentication headers. For SMB, constructs URL with embedded credentials.

    private func selectStreamAndBackend(from streams: [Stream]) -> (stream: Stream?, audioStream: Stream?, backend: PlayerBackendType) {
        // Try preferred backend first
        if let (stream, audioStream) = selectStreams(for: preferredBackendType, from: streams) {
            return (stream, audioStream, preferredBackendType)
        }

        // Fallback to any available backend
        for backendType in backendFactory.availableBackends {
            if let (stream, audioStream) = selectStreams(for: backendType, from: streams) {
                return (stream, audioStream, backendType)
            }
        }

        return (nil, nil, preferredBackendType)
    }

    /// Selects best streams for preloading (exposed for QueueManager).
    func selectStreamsForPreload(from streams: [Stream]) -> (stream: Stream?, audioStream: Stream?) {
        let result = selectStreamAndBackend(from: streams)
        return (result.stream, result.audioStream)
    }

    private func selectStreams(for backendType: PlayerBackendType, from streams: [Stream]) -> (video: Stream, audio: Stream?)? {
        guard let audio = bestAudioStream(from: streams) else { return nil }
        return (audio, nil)
    }
    private func bestAudioStream(from streams: [Stream]) -> Stream? {
        AudioStreamSelector.select(from: streams, preferredLanguage: settingsManager?.preferredAudioLanguage)
    }
    private func ensureBackend(type: PlayerBackendType) async throws -> any PlayerBackend {
        // Reuse existing backend if same type
        if let current = currentBackend, current.backendType == type {
            return current
        }

        // Create new backend
        let backend = try backendFactory.createBackend(type: type)
        backend.delegate = self
        currentBackend = backend

        return backend
    }

    private var instancesManager: InstancesManager?
    func setInstancesManager(_ manager: InstancesManager) {
        self.instancesManager = manager

        // Observe instance setting changes (e.g. proxy toggle) to re-apply proxy to cached streams
        instanceChangeObserver = NotificationCenter.default.addObserver(
            forName: .instancesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                await self?.reapplyProxyToStreams()
            }
        }
    }

    /// Sets the media sources manager for WebDAV/SMB/local folder playback.

    /// Sets the SMB client for SMB playback.

    /// Sets the WebDAV client for WebDAV playback.

    /// Sets the local file client for local folder playback.

    /// Sets the settings manager for accessing user preferences.
    func setSettingsManager(_ manager: SettingsManager) {
        self.settingsManager = manager
        // Reconfigure remote commands now that we have settings
        nowPlayingService.configureRemoteCommands(duration: settingsManager?.systemControlsSeekDuration)
        // Note: preferredBackendType is now computed directly from settingsManager
    }

    /// Reconfigures system control buttons (Control Center, Lock Screen) based on current settings.
    /// Call this when system controls settings change.
    func reconfigureSystemControls(
        mode: SystemControlsMode? = nil,
        duration: SystemControlsSeekDuration? = nil
    ) {
        nowPlayingService.configureRemoteCommands(mode: mode, duration: duration ?? settingsManager?.systemControlsSeekDuration)
    }

    /// Observer for instance setting changes to re-apply proxy to cached streams.
    private var instanceChangeObserver: NSObjectProtocol?

    /// Observer for preset changes to reconfigure system controls.
    private var presetChangeObserver: NSObjectProtocol?

    /// Sets the player controls layout service for reading preset-specific settings.
    func setPlayerControlsLayoutService(_ service: PlayerControlsLayoutService) {
        self.playerControlsLayoutService = service
        nowPlayingService.playerControlsLayoutService = service

        // Reconfigure with the actual saved settings now that layout service is available
        nowPlayingService.configureRemoteCommands(duration: settingsManager?.systemControlsSeekDuration)

        // Observe preset changes to reconfigure system controls
        presetChangeObserver = NotificationCenter.default.addObserver(
            forName: .playerControlsActivePresetDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.reconfigureSystemControls()
            }
        }
    }

    /// Sets the download manager for checking downloaded videos.
    func setDownloadManager(_ manager: DownloadManager) {
        self.downloadManager = manager
    }

    /// Sets the DeArrow branding provider for enhanced titles.
    func setDeArrowBrandingProvider(_ provider: DeArrowBrandingProvider) {
        nowPlayingService.deArrowBrandingProvider = provider
    }

    /// Sets the connectivity monitor for network-aware quality selection.
    func setConnectivityMonitor(_ monitor: ConnectivityMonitor) {
        self.connectivityMonitor = monitor
    }

    /// Sets the toast manager for displaying notifications.
    func setToastManager(_ manager: ToastManager) {
        self.toastManager = manager
    }

    /// Sets the queue manager for queue operations.
    func setQueueManager(_ manager: QueueManager) {
        self.queueManager = manager
    }

    /// Sets the navigation coordinator for waiting on sheet animations.
    func setNavigationCoordinator(_ coordinator: NavigationCoordinator) {
        self.navigationCoordinator = coordinator

    }

    /// Sets the handoff manager for activity updates.
    func setHandoffManager(_ manager: HandoffManager) {
        self.handoffManager = manager
    }

    /// Sets the service that mirrors playback into an account's server history.
    func setWatchHistorySyncService(_ service: WatchHistorySyncService) {
        self.watchHistorySyncService = service
    }

    func playerSheetDidAppear() {}
    func playerSheetDidDisappear() {}
    private func findInstance(for video: Video) async throws -> Instance? {
        guard let instancesManager else { return nil }
        return instancesManager.instance(for: video)
    }

    private func fetchSponsorBlockSegments(for videoID: String) async {
        // Update SponsorBlock API URL from settings
        if let urlString = settingsManager?.sponsorBlockAPIURL,
           let url = URL(string: urlString) {
            await sponsorBlockAPI.setBaseURL(url)
        }

        do {
            let segments = try await sponsorBlockAPI.segments(for: videoID)
            state.sponsorSegments = segments
        } catch {
            LoggingService.shared.logPlayerError("SponsorBlock fetch failed", error: error)
        }
    }

    private func fetchReturnYouTubeDislikeCounts(for videoID: String) async {
        guard settingsManager?.returnYouTubeDislikeEnabled == true else { return }

        do {
            let votes = try await returnYouTubeDislikeAPI.votes(for: videoID)
            state.dislikeCount = votes.dislikes
            // Notify observers that video details updated
            NotificationCenter.default.post(name: .videoDetailsDidLoad, object: nil)
        } catch {
            LoggingService.shared.logPlayerError("Return YouTube Dislike fetch failed", error: error)
        }
    }

    /// Fetches full video details from API and updates state.
    /// Used for downloaded videos that may not have full metadata stored.
    private func fetchAndUpdateVideoDetails(for video: Video) async {
        guard let instance = try? await findInstance(for: video) else { return }

        do {
            let fullVideo = try await contentService.video(id: video.id.videoID, instance: instance)

            // Only update if this is still the current video
            guard state.currentVideo?.id == video.id else { return }

            // Update state with full video (preserving current stream)
            state.setCurrentVideo(fullVideo, stream: state.currentStream, audioStream: state.currentAudioStream)
            NotificationCenter.default.post(name: .videoDetailsDidLoad, object: nil)

            // Also fetch dislike count if enabled
            if case .global = video.id.source {
                await fetchReturnYouTubeDislikeCounts(for: video.id.videoID)
            }
        } catch {
            // Silently fail - offline playback continues with stored metadata
        }
    }

    private func startProgressSaveTimer() {
        progressSaveTimer?.invalidate()
        progressSaveTimer = Timer.scheduledTimer(withTimeInterval: progressSaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.saveProgress()
            }
        }
    }

    private func saveProgress() {
        PerfCounter.count("player.progressSave")
        guard settingsManager?.incognitoModeEnabled != true,
              settingsManager?.saveWatchHistory != false else { return }

        guard let video = state.currentVideo,
              state.currentTime > 0 else { return }

        // A paused player keeps the timer running; rewriting the same position
        // only adds database writes, including while the app is being suspended.
        let position = (videoID: video.id.videoID, seconds: state.currentTime)
        guard lastSavedProgress?.videoID != position.videoID
            || lastSavedProgress?.seconds != position.seconds else { return }
        lastSavedProgress = position

        // Save locally only during playback - no iCloud sync overhead.
        // Live streams still get a history entry, but no resume position.
        // In the background (audio playback) the app can be suspended the
        // moment playback stops. Suspending mid-save holds the SQLite lock in
        // the shared app-group container and iOS kills the app with
        // 0xdead10cc, so keep it running until the save has committed.
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
        if UIApplication.shared.applicationState != .active {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveWatchProgress")
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }
        dataManager.updateWatchProgressLocal(for: video, seconds: state.currentTime, duration: state.duration, isLive: state.isLive)
        watchHistorySyncService?.recordProgress(videoID: video.id.videoID)

        // Update Handoff activity with current playback time
        handoffManager?.updatePlaybackTime(state.currentTime)
    }

    /// Saves progress as 100% completed when video finishes naturally.
    /// This ensures the watch history shows full completion instead of ~99%.
    private func saveProgressAsCompleted() {
        guard settingsManager?.incognitoModeEnabled != true,
              settingsManager?.saveWatchHistory != false,
              let video = state.currentVideo else { return }

        // A live stream never "completes" - saveProgress() has already recorded
        // its history entry, and writing a duration here would fabricate progress.
        guard !state.isLive else { return }

        // Use video.duration (API-reported) to match WatchEntry.duration stored value.
        // This ensures 100% progress since WatchEntry.progress = watchedSeconds / WatchEntry.duration.
        // Fall back to state.duration (player-reported) if video.duration is not available.
        let completedDuration = video.duration > 0 ? video.duration : state.duration
        guard completedDuration > 0 else { return }

        // Save the full duration as watched time and queue for iCloud sync.
        // This is the only save for a naturally finished video — play() skips
        // saveProgressAndSync() when videoEndedNaturally is set.
        dataManager.updateWatchProgress(for: video, seconds: completedDuration, duration: completedDuration)
        watchHistorySyncService?.recordProgress(videoID: video.id.videoID)

        // Update Handoff activity with completed time
        handoffManager?.updatePlaybackTime(completedDuration)
    }

    /// Saves progress and triggers iCloud sync for watch history.
    /// Call this when video playback ends or switches to a different video.
    private func saveProgressAndSync() {
        guard settingsManager?.incognitoModeEnabled != true,
              settingsManager?.saveWatchHistory != false else { return }

        guard let video = state.currentVideo,
              state.currentTime > 0 else { return }

        // Save and queue for iCloud sync (used when video closes/switches)
        dataManager.updateWatchProgress(for: video, seconds: state.currentTime, duration: state.duration, isLive: state.isLive)
        watchHistorySyncService?.recordProgress(videoID: video.id.videoID)
        NotificationCenter.default.post(name: .watchHistoryDidChange, object: nil)
    }

    /// Saves current progress and queues it for iCloud sync without ending playback.
    /// Called when the app enters background so the position reaches other devices.
    func syncWatchProgress() {
        saveProgressAndSync()
    }

    private func checkSponsorBlockSegments(at time: Double) {
        PerfCounter.count("player.sponsorBlockCheck")
        // Read settings - use defaults if settings manager not available
        let enabled = settingsManager?.sponsorBlockEnabled ?? true
        let enabledCategories = settingsManager?.sponsorBlockCategories ?? SponsorBlockCategory.defaultEnabled

        guard enabled else { return }

        // Find segment at current time that matches enabled categories
        let applicableSegments = state.sponsorSegments.skippable().inCategories(enabledCategories)
        if let segment = applicableSegments.segment(at: time) {
            // Auto-skip all enabled categories
            // Prevent duplicate skips for the same segment
            guard lastSkippedSegmentID != segment.id else { return }

            if delegate?.playerService(self, shouldSkipSegment: segment) ?? true {
                lastSkippedSegmentID = segment.id
                Task {
                    await skipSegment(segment)
                }
            }
        } else {
            if state.currentSegment != nil {
                state.currentSegment = nil
            }
            // Clear last skipped when not in any segment (allows re-skip if user seeks back)
            lastSkippedSegmentID = nil
        }
    }

    /// Skips a specific segment by seeking past it.
    private func skipSegment(_ segment: SponsorBlockSegment) async {
        let skipTarget = segment.endTime + 0.1

        // Don't skip if target is past video duration - this would cause an infinite loop
        // since we'd seek to end, still be "in" the segment, and skip again
        guard state.duration > 0, skipTarget < state.duration else {
            LoggingService.shared.logPlayer("SponsorBlock: not skipping \(segment.category.rawValue) segment (extends past video end)", details: "\(segment.startTime)s - \(segment.endTime)s, duration: \(state.duration)s")
            return
        }

        LoggingService.shared.logPlayer("SponsorBlock: skipping \(segment.category.rawValue) segment", details: "\(segment.startTime)s - \(segment.endTime)s")
        // Show loading for early skips (intro, early sponsors) to avoid brief video flash
        // But only if we haven't already shown video (still in loading state)
        let isEarlySkip = segment.startTime < 30
        let isStillLoading = state.playbackState == .loading
        await seek(to: skipTarget, showLoading: isEarlySkip && isStillLoading)
    }

    private func cleanup() {
        // Whatever was playing is gone from here on
        playbackGeneration += 1
        state.playbackIntent.reset()

        progressSaveTimer?.invalidate()
        progressSaveTimer = nil
        lastNowPlayingTimeBucket = nil

        // Remove audio session interruption observer
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil

        // Cancel any ongoing play task
        currentPlayTask?.cancel()
        currentPlayTask = nil

        currentBackend?.stop()
        // Reuse the lightweight audio backend on the next load.
    }

    /// Cleans up temporary subtitle files for a given video.
    /// Call this when closing/stopping a video.
    /// - Parameter videoID: The video ID whose subtitles to clean up.

    /// Cleans up all temporary subtitle files (pre-downloaded and per-video).
    /// Called when stopping playback entirely.

    // MARK: - Chapter Resolution

    /// Resolves chapters for the video using source hierarchy.
    /// Priority: SponsorBlock chapters > description parsing
    /// - Parameter video: The video to resolve chapters for.
    private func resolveChapters(for video: Video) {
        let videoDuration = video.duration > 0 ? video.duration : state.duration
        guard videoDuration > 0 else {
            state.chapters = []
            return
        }

        // 1. Try SponsorBlock chapters (if enabled and segments available)
        let sponsorBlockEnabled = settingsManager?.sponsorBlockEnabled ?? true
        if sponsorBlockEnabled {
            let chapters = state.sponsorSegments.extractChapters(videoDuration: videoDuration)
            if chapters.count >= 2 {
                state.chapters = chapters
                LoggingService.shared.logPlayer("Chapters: \(chapters.count) from SponsorBlock")
                return
            }
        }

        // 2. Fall back to description parsing
        if let description = video.description {
            let introTitle = String(localized: "player.chapters.intro")
            let chapters = ChapterParser.parse(
                description: description,
                videoDuration: videoDuration,
                introTitle: introTitle
            )
            state.chapters = chapters
            if !chapters.isEmpty {
                LoggingService.shared.logPlayer("Chapters: \(chapters.count) from description")
            }
        } else {
            state.chapters = []
        }
    }
}

// MARK: - PlayerBackendDelegate

extension PlayerService: PlayerBackendDelegate {
    func backend(_ backend: any PlayerBackend, didUpdateTime time: TimeInterval) {
        // Ignore time updates while loading a new video - these are stale updates from the previous video
        guard loadingVideoID == nil else { return }

        state.currentTime = time
        delegate?.playerService(self, didUpdateTime: time)
        checkSponsorBlockSegments(at: time)

        // Update Now Playing time once per 5-second bucket. Time updates arrive
        // every frame, so a plain `Int(time) % 5 == 0` check would fire for every
        // frame of that second.
        let nowPlayingBucket = Int(time) / 5
        if nowPlayingBucket != lastNowPlayingTimeBucket {
            lastNowPlayingTimeBucket = nowPlayingBucket
            nowPlayingService.updatePlaybackTime(
                currentTime: time,
                duration: state.duration,
                isPlaying: state.playbackState == .playing
            )
        }
    }

    func backend(_ backend: any PlayerBackend, didUpdateDuration duration: TimeInterval) {
        // Skip duration updates when locked from API (fast endpoint streams where
        // file is progressively downloaded and player can't determine accurate duration)
        guard !state.isDurationLockedFromAPI else { return }
        state.duration = duration
    }

    func backend(_ backend: any PlayerBackend, didChangeState playbackState: PlaybackState) {
        LoggingService.shared.debug("Backend state changed to: \(playbackState)", category: .player)

        if isPausedBySleepTimer && playbackState == .playing {
            pause(saveProgress: !videoEndedNaturally)
            return
        }

        // Clear the time-update gate once the new video is loaded, in case the load
        // flow wedged before doing so (issue #956). Only .ready: it comes from player's
        // file-loaded event, which only the new load can emit. The previous video
        // (still playing on the reused backend during the details/streams fetch) can
        // emit .playing via buffering recovery or unpause — healing on that would
        // open the gate to stale time updates and break the stale-error check in
        // play()'s catch, silently swallowing genuine load failures.
        if playbackState == .ready, loadingVideoID != nil {
            loadingVideoID = nil
        }

        state.setPlaybackState(playbackState)
        switch playbackState {
        case .playing, .paused, .buffering, .ended:
            nowPlayingService.updatePlaybackRate(isPlaying: playbackState == .playing, currentTime: state.currentTime)
        default: break
        }
        if case .failed(let error) = playbackState, loadingVideoID == nil {
            nowPlayingService.updatePlaybackRate(isPlaying: false, currentTime: state.currentTime)
            delegate?.playerService(self, didEncounterError: error)
        }
        delegate?.playerService(self, didChangeState: playbackState)
    }

    func backend(_ backend: any PlayerBackend, didUpdateBufferedTime time: TimeInterval) {
        state.bufferedTime = time
    }

    func backend(_ backend: any PlayerBackend, didUpdateBufferProgress progress: Int) {
        // Only update during initial buffering (before buffer is ready)
        // Skip buffer progress for local files - they load quickly and don't need buffering indicator
        let isLocalFile = state.currentStream?.url.isFileURL == true
        if !state.isBufferReady && !isLocalFile {
            state.bufferProgress = progress
        }
    }

    func backend(_ backend: any PlayerBackend, didUpdateVideoSize width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let aspectRatio = Double(width) / Double(height)

        state.videoAspectRatio = aspectRatio
        LoggingService.shared.debug("Video aspect ratio updated: \(aspectRatio) (\(width)x\(height))", category: .player)
    }

    func backend(_ backend: any PlayerBackend, didUpdateRetryState currentRetry: Int, maxRetries: Int, isRetrying: Bool, exhausted: Bool) {
        let retryState = RetryState(
            currentRetry: currentRetry,
            maxRetries: maxRetries,
            isRetrying: isRetrying,
            exhausted: exhausted
        )
        state.setRetryState(retryState)
    }

    func backend(_ backend: any PlayerBackend, didRequestStreamRefresh atTime: TimeInterval?) {
        LoggingService.shared.logPlayer("Stream refresh requested at time: \(atTime ?? -1)")

        Task {
            await refreshStreamsAndResume(atTime: atTime)
        }
    }

    func backendDidBecomeReady(_ backend: any PlayerBackend) {
        // First frame of new video has been rendered - thumbnail can now hide
        state.isFirstFrameReady = true
    }

    func backendDidFinishPlaying(_ backend: any PlayerBackend) {
        // Mark that video ended naturally - prevents play() from saving progress again
        // when switching to next video (100% is already saved below)
        videoEndedNaturally = true

        // Stop the progress save timer BEFORE saving completion
        // Otherwise the timer can overwrite our 100% with a lower value
        progressSaveTimer?.invalidate()
        progressSaveTimer = nil

        state.setPlaybackState(.ended)
        saveProgressAsCompleted()

        // The watch is over, so the session ends with it — after the completion
        // save, which is the last progress this session has to mirror. A
        // finished watch's session must not be left standing to absorb a future
        // watch of the same video: the next load of it would otherwise reach
        // `beginSessionIfNeeded`, recognise the video, keep the already-posted
        // session and never mirror the second watch. Every way a finished video
        // is played again on purpose starts a session of its own —
        // `replayCurrentVideo()` explicitly, any other load through
        // `beginSessionIfNeeded`. Ending the session does not touch a post
        // already in flight.
        watchHistorySyncService?.endSession()

        // Leave the state paused so the visible player's .ended observer cannot
        // start a countdown. Stop here before repeat-one or background autoplay.
        if SleepTimer.shared.stopAtEndOfVideo(for: self) { return }
        if isPausedBySleepTimer {
            pause(saveProgress: false)
            return
        }

        delegate?.playerServiceDidFinishPlaying(self)

        // Repeat one: restart immediately - no countdown, independent of queue contents
        // and the auto-play-next setting (that setting governs advancing to the next video)
        if state.queueMode == .repeatOne {
            Task {
                await playNext()
            }
            return
        }

        if (settingsManager?.queueAutoPlayNext ?? true), !state.queue.isEmpty {
            Task { await playNext() }
        } else {
            sleepPreventionService.allowSleep()
        }
    }

    /// Called when a video starts playing to trigger proactive continuation loading.
    func notifyVideoStarted() {
        queueManager?.onVideoStarted()
    }

    /// Handles playback errors by auto-skipping to next video if available and player is not visible.
    /// When player is visible, user can manually tap "Play Next" button on the error overlay.
    private func handlePlaybackErrorAutoSkip() async {
        guard !isPausedBySleepTimer else { return }

        let autoPlayEnabled = settingsManager?.queueAutoPlayNext ?? true
        let hasNextInQueue = !state.queue.isEmpty

        guard autoPlayEnabled && hasNextInQueue else { return }

        let isSheetCollapsed = navigationCoordinator?.isPlayerExpanded != true
        let isInBackground = currentScenePhase == .background

        // Skip immediately if player is NOT visible to user (no point showing error screen)
        if isSheetCollapsed || isInBackground {
            // Show toast notification
            toastManager?.showInfo(String(localized: "player.error.skippingToNext.title"))

            await playNext()
        }
    }
}
