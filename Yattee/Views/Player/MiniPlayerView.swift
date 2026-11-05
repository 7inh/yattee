//
//  MiniPlayerView.swift
//  Yattee
//
//  Mini player bar shown at bottom of screen during playback.
//

import SwiftUI
import NukeUI

struct MiniPlayerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.presentAppSheet) private var presentAppSheet

    /// Whether this is displayed as a tab bottom accessory (affects styling)
    var isTabAccessory: Bool = false

    @State private var buttonTapCounts: [UUID: Int] = [:]
    @State private var miniPlayerSettings: MiniPlayerSettings = MiniPlayerSettings.cached

    private var playerService: PlayerService? { appEnvironment?.playerService }
    private var playerState: PlayerState? { playerService?.state }
    private var navigationCoordinator: NavigationCoordinator? { appEnvironment?.navigationCoordinator }
    private var deArrowProvider: DeArrowBrandingProvider? { appEnvironment?.deArrowBrandingProvider }
    private var queueManager: QueueManager? { appEnvironment?.queueManager }
    private var playerControlsLayoutService: PlayerControlsLayoutService? { appEnvironment?.playerControlsLayoutService }

    private var currentVideo: Video? { playerState?.currentVideo }

    /// Whether PiP is currently active
    private var isPiPActive: Bool { playerState?.pipState == .active }

    private var shouldShowVideoPreview: Bool { false }
    private var isThumbnailHidden: Bool { false }
    private var shouldMountVideoView: Bool { false }
    /// The title to display, preferring DeArrow title if available.
    private var displayTitle: String {
        if let video = currentVideo, let deArrowTitle = deArrowProvider?.title(for: video) {
            return deArrowTitle
        }
        return currentVideo?.title ?? String(localized: "player.notPlaying")
    }

    /// Thumbnail URLs to try in order, preferring DeArrow, then the quality chain.
    private var displayThumbnailURLs: [URL] {
        guard let video = currentVideo else { return [] }
        let deArrowThumbnail = deArrowProvider?.thumbnailURL(for: video)
        return [deArrowThumbnail].compactMap { $0 } + video.thumbnailURLsByQuality
    }

    // MARK: - Actions

    private func handleVideoPreviewTap() { navigationCoordinator?.expandPlayer() }
    /// Closes the current video: stops playback, clears the queue, and dismisses
    /// the expanded player (so the separate macOS player window is hidden too).
    private func closeVideo() {
        playerState?.isClosingVideo = true
        queueManager?.clearQueue()
        // Stop the player before dismissing the window so the backend is torn down first.
        playerService?.stop()
        navigationCoordinator?.isPlayerExpanded = false
    }

    private func expandPlayerWithPiPRestore() { navigationCoordinator?.expandPlayer() }
    var body: some View {
        let _ = PerfCounter.body("MiniPlayerView")
        Group {
            if isTabAccessory {
                accessoryLayout
            } else {
                capsuleLayout
            }
        }
        .accessibilityIdentifier("player.miniPlayer")
        .accessibilityLabel("player.miniPlayer")
        // Hidden under the expanded player: stop the scrolling titles.
        // (macOS shows the expanded player in its own window.)
        .environment(\.isMarqueePaused, navigationCoordinator?.isPlayerExpanded == true)
        .modifier(MiniPlayerContextMenuModifier(video: currentVideo) {
            closeVideo()
        })
        .task {
            await loadMiniPlayerSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerControlsActivePresetDidChange)) { _ in
            Task { await loadMiniPlayerSettings() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerControlsPresetsDidChange)) { _ in
            Task { await loadMiniPlayerSettings() }
        }
    }

    /// Loads mini player settings from the active preset.
    private func loadMiniPlayerSettings() async {
        guard let layoutService = playerControlsLayoutService else { return }
        let layout = await layoutService.activeLayout()
        await MainActor.run {
            miniPlayerSettings = layout.effectiveMiniPlayerSettings
            MiniPlayerSettings.cached = layout.effectiveMiniPlayerSettings
            GlobalLayoutSettings.cached = layout.globalSettings
        }
    }

    // MARK: - Tab Accessory Layout (iOS 26+)

    private var accessoryLayout: some View {
        HStack(spacing: 8) {
            // Video preview - tap for PiP (or expand if PiP unavailable)
            videoPreviewView
                .frame(width: 64, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .reportsMiniPlayerVideoFrame(cornerRadius: 6, navigationCoordinator: navigationCoordinator)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVideoPreviewTap()
                }

            // Title/author - tap to expand player (restores from PiP first if needed)
            Button {
                expandPlayerWithPiPRestore()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: displayTitle,
                        font: .subheadline,
                        fontWeight: .medium,
                        foregroundStyle: .primary
                    )

                    if let authorName = currentVideo?.author.name, !authorName.isEmpty {
                        MarqueeText(
                            text: authorName,
                            font: .caption,
                            foregroundStyle: .secondary
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Dynamic buttons from settings
            buttonsView
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
    }

    // MARK: - Capsule Layout (macOS + iOS 18 overlay)

    /// Preview size for the capsule: slightly larger on iOS for touch.
    private var capsulePreviewSize: CGSize {
        CGSize(width: 56, height: 32)
    }

    /// Compact, centered capsule (Music.app style). On macOS it floats in the main
    /// window alongside the separate player window; on iOS 18 (no tab accessory)
    /// it floats above the tab bar with the same width limit.
    private var capsuleLayout: some View {
        HStack(spacing: 10) {
            // Video preview - tap for PiP (or expand if PiP unavailable)
            videoPreviewView
                .frame(width: capsulePreviewSize.width, height: capsulePreviewSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .reportsMiniPlayerVideoFrame(cornerRadius: 4, navigationCoordinator: navigationCoordinator)
                .contentShape(Rectangle())
                .onTapGesture {
                    handleVideoPreviewTap()
                }

            // Title/author area - tap to expand player (restores from PiP first if needed)
            VStack(alignment: .leading, spacing: 1) {
                MarqueeText(
                    text: displayTitle,
                    font: .subheadline,
                    fontWeight: .medium,
                    foregroundStyle: .primary
                )

                authorLine(font: .caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                expandPlayerWithPiPRestore()
            }

            // Dynamic buttons from settings (close is part of the preset)
            buttonsView

            // Safety net: keep a way to close when the preset has no close button
            if !miniPlayerSettings.buttons.contains(where: { $0.buttonType == .close }) {
                closeButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: 420)
        .glassBackground(.regular, in: .capsule, fallback: .regularMaterial)
        .overlay(alignment: .bottom) {
            progressLine
        }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
    }

    // MARK: - Shared Components

    /// Author line with a red LIVE indicator for live streams.
    /// MarqueeText draws its text at the top of a fixed-height frame, so the badge
    /// is top-aligned with it (dot stays centered against the LIVE text only).
    @ViewBuilder
    private func authorLine(font: Font) -> some View {
        let authorName = currentVideo?.author.name ?? ""
        if playerState?.isLive == true {
            HStack(alignment: .top, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(String(localized: "player.live"))
                        .font(font.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .fixedSize()

                if !authorName.isEmpty {
                    MarqueeText(
                        text: authorName,
                        font: font,
                        foregroundStyle: .secondary
                    )
                }
            }
        } else if !authorName.isEmpty {
            MarqueeText(
                text: authorName,
                font: font,
                foregroundStyle: .secondary
            )
        }
    }

    /// Bottom progress line; hidden for live streams where progress is meaningless.
    @ViewBuilder
    private var progressLine: some View {
        if playerState?.isLive != true {
            GeometryReader { geo in
                Rectangle()
                    .fill(.red)
                    .frame(width: geo.size.width * (playerState?.progress ?? 0), height: 2)
            }
            .frame(height: 2)
        }
    }

    private var videoPreviewView: some View {
        thumbnailView.allowsHitTesting(false)
    }
    @ViewBuilder
    private var thumbnailView: some View {
        FallbackLazyImage(urls: displayThumbnailURLs) { state in
            if let image = state.image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    // MARK: - Dynamic Buttons

    /// Renders buttons from miniPlayerSettings.buttons
    @ViewBuilder
    private var buttonsView: some View {
        ForEach(miniPlayerSettings.buttons) { config in
            miniPlayerButton(for: config)
        }
    }

    /// Renders a single button based on its configuration
    @ViewBuilder
    private func miniPlayerButton(for config: ControlButtonConfiguration) -> some View {
        switch config.buttonType {
        case .playPause:
            playPauseButton(config: config)
        case .playNext:
            playNextButton(config: config)
        case .playPrevious:
            playPreviousButton(config: config)
        case .seek:
            seekButton(config: config)
        case .close:
            closeButton
        case .queue:
            queueButton(config: config)
        case .share:
            shareButton(config: config)
        case .addToPlaylist:
            addToPlaylistButton(config: config)
        case .airplay:
            airplayButton
        case .pictureInPicture:
            pipButton(config: config)
        case .playbackSpeed:
            playbackSpeedButton(config: config)
        case .audioMode:
            audioModeButton(config: config)
        default:
            EmptyView()
        }
    }

    // MARK: - Individual Button Views

    private func playPauseButton(config: ControlButtonConfiguration) -> some View {
        Button {
            incrementTapCount(for: config)
            playerService?.togglePlayPause()
        } label: {
            Image(systemName: playPauseIcon)
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
        }
        .buttonStyle(.plain)
        .disabled(isTransportDisabled)
    }

    private func playNextButton(config: ControlButtonConfiguration) -> some View {
        Button {
            incrementTapCount(for: config)
            Task { await playerService?.playNext() }
        } label: {
            Image(systemName: "forward.fill")
                .symbolEffect(.bounce.down.byLayer, options: .nonRepeating, value: buttonTapCounts[config.id] ?? 0)
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(playerState?.hasNext == true ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .disabled(playerState?.hasNext != true)
    }

    private func playPreviousButton(config: ControlButtonConfiguration) -> some View {
        Button {
            incrementTapCount(for: config)
            Task { await playerService?.playPrevious() }
        } label: {
            Image(systemName: "backward.fill")
                .symbolEffect(.bounce.down.byLayer, options: .nonRepeating, value: buttonTapCounts[config.id] ?? 0)
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(playerState?.hasPrevious == true ? .primary : .tertiary)
        }
        .buttonStyle(.plain)
        .disabled(playerState?.hasPrevious != true)
    }

    private func seekButton(config: ControlButtonConfiguration) -> some View {
        let settings = config.seekSettings ?? SeekSettings()
        return Button {
            incrementTapCount(for: config)
            playerService?.seek(seconds: Double(settings.seconds), direction: settings.direction)
        } label: {
            Image(systemName: settings.systemImage)
                .symbolEffect(.bounce.down.byLayer, options: .nonRepeating, value: buttonTapCounts[config.id] ?? 0)
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button {
            closeVideo()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func queueButton(config: ControlButtonConfiguration) -> some View {
        Button {
            incrementTapCount(for: config)
            presentAppSheet(.queue(halfHeight: true))
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: "list.bullet")
                    .font(isTabAccessory ? .title3 : .title2)
                    .frame(width: 32, height: 32)

                // Badge showing queue count
                let queueCount = playerState?.queue.count ?? 0
                if queueCount > 0 {
                    Text("\(queueCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .offset(y: 4)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func shareButton(config: ControlButtonConfiguration) -> some View {
        if let video = currentVideo {
            ShareLink(item: appEnvironment?.shareURL(for: video) ?? video.shareURL) {
                Image(systemName: "square.and.arrow.up")
                    .font(isTabAccessory ? .title3 : .title2)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func addToPlaylistButton(config: ControlButtonConfiguration) -> some View {
        Button {
            incrementTapCount(for: config)
            if let video = appEnvironment?.playerService.state.currentVideo {
                presentAppSheet(.addToPlaylist(video, halfHeight: true))
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var airplayButton: some View {
        AirPlayButton(tintColor: .label)
            .frame(width: 32, height: 32)
    }

    private func pipButton(config: ControlButtonConfiguration) -> some View {
        EmptyView()
    }
    private func playbackSpeedButton(config: ControlButtonConfiguration) -> some View {
        let currentRate = playerState?.rate ?? .x1
        return Menu {
            ForEach(PlaybackRate.allCases) { rate in
                Button {
                    playerState?.rate = rate
                    playerService?.currentBackend?.rate = Float(rate.rawValue)
                } label: {
                    HStack {
                        Text(rate.displayText)
                        if currentRate == rate {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Text(currentRate.compactDisplayText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .tint(.primary)
    }

    private func audioModeButton(config: ControlButtonConfiguration) -> some View {
        let isAudioMode = appEnvironment?.settingsManager.audioOnlyModeEnabled ?? false
        return Button {
            incrementTapCount(for: config)
            Task { await playerService?.setAudioMode(!isAudioMode) }
        } label: {
            Image(systemName: "music.note")
                .font(isTabAccessory ? .title3 : .title2)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .foregroundStyle(isAudioMode ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    /// Whether transport controls should be disabled (during loading/buffering or buffer not ready)
    private var isTransportDisabled: Bool {
        guard let state = playerState else { return true }
        return state.playbackState == .loading ||
               state.playbackState == .buffering ||
               !state.isFirstFrameReady ||
               !state.isBufferReady
    }

    private var playPauseIcon: String {
        switch playerState?.playbackState {
        case .playing:
            return "pause.fill"
        default:
            return "play.fill"
        }
    }

    private func incrementTapCount(for config: ControlButtonConfiguration) {
        buttonTapCounts[config.id, default: 0] += 1
    }
}

// MARK: - Video Frame Reporting

private extension View {
    /// Publishes the video preview's frame as the expanded player's dismiss
    /// morph target (iOS only; macOS's player is a separate window or overlay).
    @ViewBuilder
    func reportsMiniPlayerVideoFrame(cornerRadius: CGFloat, navigationCoordinator: NavigationCoordinator?) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            guard let navigationCoordinator, navigationCoordinator.miniPlayerVideoFrame != frame else { return }
            navigationCoordinator.miniPlayerVideoFrame = frame
            navigationCoordinator.miniPlayerVideoCornerRadius = cornerRadius
        }
        .onDisappear {
            navigationCoordinator?.miniPlayerVideoFrame = .zero
        }
    }
}

// MARK: - Context Menu Modifier

/// A view modifier that conditionally applies the video context menu.
/// Only applies the context menu when a video is available.
private struct MiniPlayerContextMenuModifier: ViewModifier {
    let video: Video?
    let closeAction: () -> Void

    func body(content: Content) -> some View {
        if let video {
            content.videoContextMenu(
                video: video,
                customActions: [
                    VideoContextAction(
                        String(localized: "player.close"),
                        systemImage: "xmark",
                        role: .destructive,
                        action: closeAction
                    )
                ],
                context: .player
            )
        } else {
            content
        }
    }
}

// MARK: - Previews

#Preview("Overlay Mode") {
    VStack {
        Spacer()
        MiniPlayerView(isTabAccessory: false)
    }
    .appEnvironment(.preview)
}

#Preview("Accessory Mode") {
    MiniPlayerView(isTabAccessory: true)
        .appEnvironment(.preview)
}
