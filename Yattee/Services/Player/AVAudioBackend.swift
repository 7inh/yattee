//
//  AVAudioBackend.swift
//  Yattee
//
//  AVFoundation playback of standalone audio renditions, with no video surface.
//

import Foundation
@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class AVAudioBackend: PlayerBackend {
    let backendType: PlayerBackendType = .avFoundation
    weak var delegate: PlayerBackendDelegate?

    var rate: Float = 1 {
        didSet {
            applyRate()
            LoggingService.shared.logPlayer("Audio speed selected: \(rate)x, effective=\(effectiveRate)x, playing=\(wantsToPlay)")
            startLocalCopyIfNeeded()
        }
    }

    /// iOS plays HLS above 2x silently, so the streamed (HLS) path is held at
    /// 2x until the local copy for 2.5x/3x is ready.
    private var effectiveRate: Float {
        playlistResourceLoader != nil ? min(rate, 2) : rate
    }

    private func applyRate() {
        player.defaultRate = effectiveRate
        if wantsToPlay { player.rate = effectiveRate }
    }
    var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    private let player: AVPlayer
    private var observations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var generation = UUID()
    private var seekGeneration = UUID()
    private var loadingAsset: AVURLAsset?
    private let dashPlaylistLoader: DASHAudioPlaylistLoader
    private var playlistTask: Task<String, Error>?
    // AVAssetResourceLoader holds its delegate weakly; retain it for the whole item lifetime.
    private var playlistResourceLoader: DASHAudioResourceLoader?
    private var wantsToPlay = false
    private var defersReady = false
    private var reportedReady = false
    private var playbackState: PlaybackState = .idle
    /// The remote rendition behind the current HLS item, for fetching a local copy.
    private var remoteAudio: Stream?
    private var localCopyTask: Task<Void, Never>?
    private let localCopies: AudioLocalCopyCache

    init(
        player: AVPlayer = AVPlayer(),
        dashPlaylistLoader: DASHAudioPlaylistLoader = DASHAudioPlaylistLoader(),
        localCopies: AudioLocalCopyCache = .shared
    ) {
        self.player = player
        self.dashPlaylistLoader = dashPlaylistLoader
        self.localCopies = localCopies
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    // MARK: - Playback

    func load(stream: Stream, audioStream: Stream?, autoplay: Bool) async throws {
        try Task.checkCancellation()
        let initialSeekPending = defersReady
        resetPlayback()
        defersReady = initialSeekPending
        let token = generation
        let audio = audioStream ?? stream
        guard audio.isAVPlayerAudioPlayable else {
            let error = BackendError.unsupportedFormat(StreamFormat.detect(from: audio))
            fail(error)
            throw error
        }
        setState(.loading)

        do {
            try activateAudioSession()
            // Validation above prevents opening muxed/video assets or HLS masters.
            let asset = try await makeAudioAsset(for: audio)
            loadingAsset = asset
            try checkLoad(token)
            let item = AVPlayerItem(asset: asset)
            item.audioTimePitchAlgorithm = .spectral
            installObservers(for: item, generation: token)
            player.replaceCurrentItem(with: item)

            // Let the item validate and load the asset inside this bounded wait.
            // An isPlayable/duration preflight can hang indefinitely on remote
            // DASH renditions, before an item or its timeout even exists.
            // Cancellation or replacement must never publish ready for an old item.
            let deadline = Date().addingTimeInterval(30)
            while item.status != .readyToPlay {
                try checkLoad(token)
                if item.status == .failed {
                    throw BackendError.loadFailed(item.error?.localizedDescription ?? "Audio loading failed")
                }
                guard Date() < deadline else { throw BackendError.loadFailed("Audio loading timed out") }
                try await Task.sleep(for: .milliseconds(25))
            }
            try checkLoad(token)
            LoggingService.shared.logPlayer("Audio ready: rate=\(rate)x, canFastForward=\(item.canPlayFastForward), pitch=\(item.audioTimePitchAlgorithm.rawValue)")
            publishProgress()
            if !defersReady { reportReady() }
            if autoplay { play() }
        } catch {
            guard generation == token else { throw CancellationError() }
            if error is CancellationError {
                stop()
                throw error
            }
            let failure = error as? BackendError ?? .loadFailed(error.localizedDescription)
            fail(failure)
            throw failure
        }
    }

    func makeAudioAsset(for audio: Stream) async throws -> AVURLAsset {
        let token = generation
        try checkLoad(token)
        let options = audio.httpHeaders.map { ["AVURLAssetHTTPHeaderFieldsKey": $0] }
        let isMP4 = audio.mimeType?.lowercased().hasPrefix("audio/mp4") == true
            || ["m4a", "mp4"].contains(audio.format.lowercased())
        if !audio.url.isFileURL, !audio.isLive, isMP4,
           audio.initRange != nil, audio.indexRange != nil {
            if rate > 2, let copy = await localCopies.existingCopy(for: audio) {
                try checkLoad(token)
                LoggingService.shared.logPlayer("Audio: using cached local copy for \(rate)x")
                return AVURLAsset(url: copy)
            }
            // DASH fragments are not ordinary progressive M4A files. Successful
            // metadata/range reads do not guarantee native playback will start.
            // Always adapt remote indexed audio first, regardless of the speed;
            // local/downloaded M4A remains native and supports rates above 2x.
            let task = Task { try await dashPlaylistLoader.playlist(for: audio) }
            playlistTask = task
            do {
                let playlist = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                try checkLoad(token)
                playlistTask = nil
                let loader = DASHAudioResourceLoader(playlist: playlist)
                let asset = AVURLAsset(url: loader.url, options: options)
                asset.resourceLoader.setDelegate(loader, queue: .main)
                playlistResourceLoader = loader
                remoteAudio = audio
                LoggingService.shared.logPlayer("Audio: using generated DASH HLS byte-range playlist")
                return asset
            } catch {
                try checkLoad(token)
                playlistTask = nil
                LoggingService.shared.logPlayerError("Audio DASH playlist failed", error: error)
                throw error
            }
        }
        try checkLoad(token)
        LoggingService.shared.logPlayer("Audio: using \(audio.url.isFileURL ? "local" : "progressive") native audio")
        return AVURLAsset(url: audio.url, options: options)
    }

    func play() {
        guard player.currentItem?.status == .readyToPlay else { return }
        if case .failed = playbackState { return }
        do {
            try activateAudioSession()
            wantsToPlay = true
            player.defaultRate = effectiveRate
            player.play()
        } catch {
            fail(.loadFailed(error.localizedDescription))
        }
    }

    func pause() {
        wantsToPlay = false
        player.pause()
        if player.currentItem != nil { setState(.paused) }
    }

    func stop() {
        resetPlayback()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            LoggingService.shared.logPlayerError("Audio session deactivation failed", error: error)
        }
    }

    private func resetPlayback() {
        generation = UUID()
        seekGeneration = UUID()
        playlistTask?.cancel()
        playlistTask = nil
        loadingAsset?.cancelLoading()
        loadingAsset = nil
        wantsToPlay = false
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
        playlistResourceLoader = nil
        remoteAudio = nil
        localCopyTask?.cancel()
        localCopyTask = nil
        defersReady = false
        reportedReady = false
        setState(.idle)
    }

    func prepareForInitialSeek() { defersReady = true }

    func seek(to time: TimeInterval, showLoading: Bool) async {
        guard time.isFinite, let item = player.currentItem, item.status == .readyToPlay else { return }
        let token = generation
        let seekToken = UUID()
        seekGeneration = seekToken
        if showLoading { setState(.buffering) }
        let duration = item.duration.seconds
        let target = duration.isFinite ? min(max(time, 0), max(duration, 0)) : max(time, 0)
        let completed = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
        guard generation == token, seekGeneration == seekToken else { return }
        guard completed else {
            fail(.seekFailed)
            return
        }
        defersReady = false
        reportReady()
        publishProgress()
        setState(wantsToPlay ? .playing : .paused)
    }

    static func configureAudioSession() throws {
        // The playback category enables AirPlay automatically. Explicit
        // allowAirPlay is only valid with playAndRecord and can fail here.
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
    }

    private func activateAudioSession() throws {
        try Self.configureAudioSession()
        try AVAudioSession.sharedInstance().setActive(true)
    }

    // MARK: - Local Copy Above 2x

    private func startLocalCopyIfNeeded() {
        guard rate > 2, localCopyTask == nil, let audio = remoteAudio,
              playlistResourceLoader != nil, reportedReady else { return }
        let token = generation
        LoggingService.shared.logPlayer("Audio: fetching local copy for \(rate)x")
        localCopyTask = Task { [weak self, localCopies] in
            do {
                let file = try await localCopies.localCopy(for: audio)
                await self?.switchToLocalCopy(file, generation: token)
            } catch {
                guard !(error is CancellationError) else { return }
                LoggingService.shared.logPlayerError("Audio local copy failed", error: error)
                await MainActor.run { [weak self] in
                    if self?.generation == token { self?.localCopyTask = nil }
                }
            }
        }
    }

    /// Replaces the HLS item with the local file at the same position.
    private func switchToLocalCopy(_ file: URL, generation token: UUID) async {
        guard generation == token, playlistResourceLoader != nil, rate > 2,
              let oldItem = player.currentItem else { return }
        let position = player.currentTime()
        let resume = wantsToPlay

        let item = AVPlayerItem(asset: AVURLAsset(url: file))
        item.audioTimePitchAlgorithm = .spectral
        // Old observers belong to the HLS item; give the new one a fresh generation.
        let newToken = UUID()
        generation = newToken
        seekGeneration = UUID()
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        installObservers(for: item, generation: newToken)
        player.replaceCurrentItem(with: item)

        let deadline = Date().addingTimeInterval(10)
        while item.status != .readyToPlay {
            if generation != newToken { return }
            if item.status == .failed || Date() >= deadline {
                LoggingService.shared.logPlayerError(
                    "Audio local copy did not load; staying on HLS",
                    error: item.error ?? BackendError.loadFailed("timeout")
                )
                restoreHLSItem(oldItem, at: position, resume: resume)
                try? FileManager.default.removeItem(at: file)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        guard generation == newToken else { return }
        playlistResourceLoader = nil
        remoteAudio = nil
        applyRate()
        if resume { player.play(); player.rate = effectiveRate }
        publishProgress()
        LoggingService.shared.logPlayer("Audio: switched to local copy at \(Int(position.seconds))s for \(rate)x")
    }

    private func restoreHLSItem(_ item: AVPlayerItem, at position: CMTime, resume: Bool) {
        let token = UUID()
        generation = token
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
        notifications.removeAll()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        installObservers(for: item, generation: token)
        player.replaceCurrentItem(with: item)
        player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        applyRate()
        if resume { player.play() }
        // Don't retry this item; the copy failed once already.
    }

    // MARK: - Observers

    private func installObservers(for item: AVPlayerItem, generation token: UUID) {
        observations.append(item.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if let error = self.player.currentItem?.error { self.fail(.loadFailed(error.localizedDescription)) }
            }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.reportedReady,
                      self.playbackState != .ended else { return }
                if case .failed = self.playbackState { return }
                switch self.player.timeControlStatus {
                case .playing:
                    self.setState(.playing)
                    if let timebase = self.player.currentItem?.timebase {
                        LoggingService.shared.logPlayer("Audio playing: selected=\(self.rate)x, effective=\(CMTimebaseGetRate(timebase))x")
                    }
                case .waitingToPlayAtSpecifiedRate: self.setState(.buffering)
                case .paused: self.setState(self.wantsToPlay ? .buffering : .paused)
                @unknown default: break
                }
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.publishProgress()
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.wantsToPlay = false
                self.publishProgress()
                self.setState(.ended)
                self.delegate?.backendDidFinishPlaying(self)
            }
        })
        notifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                                                object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.fail(.loadFailed(self.player.currentItem?.error?.localizedDescription ?? "Audio playback failed"))
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, self.generation == token,
                      reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.pause()
            }
        })
    }

    private func publishProgress() {
        guard let item = player.currentItem else { return }
        let time = player.currentTime().seconds
        if time.isFinite { delegate?.backend(self, didUpdateTime: max(time, 0)) }
        let duration = item.duration.seconds
        if duration.isFinite { delegate?.backend(self, didUpdateDuration: max(duration, 0)) }
        let buffered = item.loadedTimeRanges.map(\.timeRangeValue).filter { range in
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return start.isFinite && end.isFinite && start <= time + 0.5 && end >= time
        }.map { CMTimeRangeGetEnd($0).seconds }.max() ?? max(time, 0)
        if buffered.isFinite { delegate?.backend(self, didUpdateBufferedTime: buffered) }
    }

    private func reportReady() {
        guard !reportedReady else { return }
        reportedReady = true
        // The item type (HLS or local) is known now, so cap or lift the rate.
        applyRate()
        setState(.ready)
        delegate?.backendDidBecomeReady(self)
        startLocalCopyIfNeeded()
    }

    private func checkLoad(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func setState(_ state: PlaybackState) {
        guard playbackState != state else { return }
        playbackState = state
        delegate?.backend(self, didChangeState: state)
    }

    private func fail(_ error: BackendError) {
        wantsToPlay = false
        player.pause()
        loadingAsset?.cancelLoading()
        if case .failed = playbackState { return }
        LoggingService.shared.logPlayerError("Audio backend failed", error: error)
        setState(.failed(error))
    }
}
