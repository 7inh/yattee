//
//  QualitySelectorView.swift
//  Yattee
//
//  Sheet for selecting video quality, audio track, and subtitles.
//

import SwiftUI

struct QualitySelectorView: View {
    // MARK: - Environment

    @Environment(\.dismiss) var dismiss
    @Environment(\.appEnvironment) var appEnvironment

    // MARK: - Properties

    let streams: [Stream]
    let captions: [Caption]
    let currentStream: Stream?
    let currentAudioStream: Stream?
    let currentCaption: Caption?
    let isLoading: Bool
    let currentDownload: Download?
    let isLoadingOnlineStreams: Bool
    let localCaptionURL: URL?
    let onStreamSelected: (Stream, Stream?) -> Void
    let onCaptionSelected: (Caption?) -> Void
    let onLoadOnlineStreams: () -> Void
    let onSwitchToOnlineStream: (Stream, Stream?) -> Void

    /// Embedded (in-container) tracks reported by player for the loaded file.
    let embeddedAudioTracks: [MediaTrack]
    let embeddedSubtitleTracks: [MediaTrack]
    let currentEmbeddedAudioTrackID: Int?
    let currentEmbeddedSubtitleTrackID: Int?
    /// The playing file's video track, used to label metadata-less local streams
    let embeddedVideoTrack: MediaTrack?
    let onEmbeddedAudioTrackSelected: (Int) -> Void
    /// nil = subtitles off
    let onEmbeddedSubtitleTrackSelected: (Int?) -> Void

    /// Current playback rate
    var currentRate: PlaybackRate = .x1
    /// Callback when playback rate changes
    var onRateChanged: ((PlaybackRate) -> Void)?

    /// Whether controls are locked
    var isControlsLocked: Bool = false
    /// Callback when lock state changes
    var onLockToggled: ((Bool) -> Void)?

    /// Whether audio-only (music) mode is enabled
    var isAudioMode: Bool = false
    /// Callback when audio mode is toggled
    var onAudioModeToggled: ((Bool) -> Void)?

    /// Initial tab to show when view appears
    var initialTab: QualitySelectorTab = .video
    /// Whether to show the segmented tab picker (false for focused single-tab mode)
    var showTabPicker: Bool = true

    /// Optional dismiss callback used when the view is presented inline (e.g. as
    /// the tvOS half-screen panel). When nil, falls back to `@Environment(\.dismiss)`.
    var onDismiss: (() -> Void)?

    /// Embedded inside a container: no close toolbar item, no sheet detents,
    /// and no minimum frame.
    var isEmbedded: Bool = false


    // MARK: - State
    @State var selectedTab: QualitySelectorTab = .video
    @State var selectedVideoStream: Stream?
    @State var selectedAudioStream: Stream?
    @State var showingSubtitleFilePicker = false

    // MARK: - Settings Access

    /// The preferred audio language from settings
    var preferredAudioLanguage: String? {
        appEnvironment?.settingsManager.preferredAudioLanguage
    }

    /// The preferred subtitles language from settings
    var preferredSubtitlesLanguage: String? {
        appEnvironment?.settingsManager.preferredSubtitlesLanguage
    }

    /// The preferred video quality from settings
    var preferredQuality: VideoQuality {
        appEnvironment?.settingsManager.preferredQuality ?? .auto
    }

    /// Whether to show advanced stream details (codec, bitrate, size)
    var showAdvancedStreamDetails: Bool {
        appEnvironment?.settingsManager.showAdvancedStreamDetails ?? false
    }

    var allowSoftwareDecodedFormats: Bool {
        appEnvironment?.settingsManager.allowSoftwareDecodedFormats ?? false
    }

    // MARK: - Computed Properties

    /// Available tabs based on streams
    var availableTabs: [QualitySelectorTab] {
        var tabs: [QualitySelectorTab] = [.video]
        if (hasVideoOnlyStreams && !audioStreams.isEmpty) || embeddedAudioTracks.count > 1 {
            tabs.append(.audio)
        }
        if !captions.isEmpty || !embeddedSubtitleTracks.isEmpty || canLoadExternalSubtitles {
            tabs.append(.subtitles)
        }
        // The selector never renders with zero tabs; fall back to video.
        return tabs.isEmpty ? [.video] : tabs
    }

    /// Whether the "Load subtitle from file…" row is available: media-source
    /// playback (local folder/SMB/WebDAV) on platforms with a file picker.
    var canLoadExternalSubtitles: Bool {
        return appEnvironment?.playerService.state.currentVideo?.isFromMediaSource == true
    }

    /// Navigation title based on mode
    var navigationTitle: String {
        if showTabPicker {
            return String(localized: "player.quality.settings")
        } else {
            switch initialTab {
            case .video:
                return String(localized: "player.quality.video")
            case .audio:
                return String(localized: "stream.audio")
            case .subtitles:
                return String(localized: "stream.subtitles")
            }
        }
    }

    /// Whether we're playing downloaded content
    var isPlayingDownloadedContent: Bool {
        currentDownload != nil
    }

    /// Whether streams are empty (not loading, but no streams available)
    var hasNoStreams: Bool {
        if !showTabPicker && initialTab == .subtitles {
            return !isLoading && captions.isEmpty && embeddedSubtitleTracks.isEmpty
                && !isPlayingDownloadedContent && !canLoadExternalSubtitles
        }
        return !isLoading && streams.isEmpty && !isPlayingDownloadedContent
    }

    /// Whether online streams have been loaded
    var hasOnlineStreams: Bool {
        streams.contains { !$0.url.isFileURL }
    }

    /// Whether the current or selected video stream is muxed
    var isCurrentStreamMuxed: Bool {
        if let selected = selectedVideoStream {
            return selected.isMuxed
        }
        return currentStream?.isMuxed ?? false
    }

    // MARK: - Initialization

    init(
        streams: [Stream],
        captions: [Caption] = [],
        currentStream: Stream?,
        currentAudioStream: Stream? = nil,
        currentCaption: Caption? = nil,
        isLoading: Bool = false,
        currentDownload: Download? = nil,
        isLoadingOnlineStreams: Bool = false,
        localCaptionURL: URL? = nil,
        currentRate: PlaybackRate = .x1,
        isControlsLocked: Bool = false,
        isAudioMode: Bool = false,
        initialTab: QualitySelectorTab = .video,
        showTabPicker: Bool = true,
        embeddedAudioTracks: [MediaTrack] = [],
        embeddedSubtitleTracks: [MediaTrack] = [],
        currentEmbeddedAudioTrackID: Int? = nil,
        currentEmbeddedSubtitleTrackID: Int? = nil,
        embeddedVideoTrack: MediaTrack? = nil,
        onStreamSelected: @escaping (Stream, Stream?) -> Void,
        onCaptionSelected: @escaping (Caption?) -> Void = { _ in },
        onLoadOnlineStreams: @escaping () -> Void = {},
        onSwitchToOnlineStream: @escaping (Stream, Stream?) -> Void = { _, _ in },
        onEmbeddedAudioTrackSelected: @escaping (Int) -> Void = { _ in },
        onEmbeddedSubtitleTrackSelected: @escaping (Int?) -> Void = { _ in },
        onRateChanged: ((PlaybackRate) -> Void)? = nil,
        onLockToggled: ((Bool) -> Void)? = nil,
        onAudioModeToggled: ((Bool) -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        isEmbedded: Bool = false
    ) {
        self.streams = streams
        self.captions = captions
        self.currentStream = currentStream
        self.currentAudioStream = currentAudioStream
        self.currentCaption = currentCaption
        self.isLoading = isLoading
        self.currentDownload = currentDownload
        self.isLoadingOnlineStreams = isLoadingOnlineStreams
        self.localCaptionURL = localCaptionURL
        self.initialTab = initialTab
        self.showTabPicker = showTabPicker
        self.currentRate = currentRate
        self.isControlsLocked = isControlsLocked
        self.isAudioMode = isAudioMode
        self.embeddedAudioTracks = embeddedAudioTracks
        self.embeddedSubtitleTracks = embeddedSubtitleTracks
        self.currentEmbeddedAudioTrackID = currentEmbeddedAudioTrackID
        self.currentEmbeddedSubtitleTrackID = currentEmbeddedSubtitleTrackID
        self.embeddedVideoTrack = embeddedVideoTrack
        self.onStreamSelected = onStreamSelected
        self.onCaptionSelected = onCaptionSelected
        self.onLoadOnlineStreams = onLoadOnlineStreams
        self.onSwitchToOnlineStream = onSwitchToOnlineStream
        self.onEmbeddedAudioTrackSelected = onEmbeddedAudioTrackSelected
        self.onEmbeddedSubtitleTrackSelected = onEmbeddedSubtitleTrackSelected
        self.onRateChanged = onRateChanged
        self.onLockToggled = onLockToggled
        self.onAudioModeToggled = onAudioModeToggled
        self.onDismiss = onDismiss
        self.isEmbedded = isEmbedded
    }

    // MARK: - Body

    @ViewBuilder
    private var rootContent: some View {
        if isLoading {
            loadingContent
        } else if isPlayingDownloadedContent {
            downloadedContent
        } else if hasNoStreams {
            emptyContent
        } else {
            streamsContent
        }
    }

    var body: some View {
        if isEmbedded {
            NavigationStack {
                stackRoot
            }
        } else {
            NavigationStack {
                stackRoot
            }
            // Rest at a taller-than-medium detent so the general section (playback
            // speed / audio mode / lock) at the bottom of the scroll view is
            // visible without dragging the sheet up to `.large`.
            .presentationDetents([.fraction(0.6), .large])
        }
    }

    @ViewBuilder
    private var stackRoot: some View {
        Group {
            rootContent
        }
        .background(ListBackgroundStyle.grouped.color)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEmbedded {
                sheetCloseToolbarItem { performDismiss() }
            }
        }
        .navigationDestination(for: QualitySelectorDestination.self) { destination in
            switch destination {
            case .video:
                videoDetailContent
            case .audio:
                audioDetailContent
            case .subtitles:
                subtitlesDetailContent
            }
        }
        .sheet(isPresented: $showingSubtitleFilePicker) {
            SubtitleFilePickerView { url in
                handlePickedSubtitleFile(url)
            }
        }
        .onAppear {
            selectedVideoStream = currentStream
            // In audio mode the audio track IS the main stream
            selectedAudioStream = currentStream?.isAudioOnly == true
                ? currentStream
                : (currentAudioStream ?? defaultAudioStream)
        }
    }


    func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    QualitySelectorView(
        streams: [.preview, .videoOnlyPreview, .audioPreview],
        captions: [.preview, .autoGeneratedPreview],
        currentStream: .preview,
        onStreamSelected: { _, _ in }
    )
}

#Preview("Loading") {
    QualitySelectorView(
        streams: [],
        currentStream: nil,
        isLoading: true,
        onStreamSelected: { _, _ in }
    )
}

#Preview("Empty") {
    QualitySelectorView(
        streams: [],
        currentStream: nil,
        onStreamSelected: { _, _ in }
    )
}
