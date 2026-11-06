//
//  OnTheGoPanel.swift
//  Yattee
//
//  The full audio player, with album artwork and transport controls.
//

import Foundation
import SwiftUI
import NukeUI

private let nowPlayingAccent = Color.red

@MainActor
struct OnTheGoPanel: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.presentAppSheet) private var presentAppSheet
    @Environment(\.openURL) private var openURL

    let playerService: PlayerService
    let onClose: () -> Void

    @GestureState private var scrubTime: TimeInterval? = nil
    @State private var pendingSeekTime: TimeInterval?
    @State private var transportFeedbackTrigger = false
    @State private var showingDetails = false
    @State private var showingComments = false
    @State private var showingCommentDetails = false
    @State private var showingDeleteDownloadConfirmation = false
    @State private var downloadToDelete: Download?

    private enum Layout {
        static let horizontalPadding: CGFloat = 16
        static let smallSpacing: CGFloat = 8
        static let mediumSpacing: CGFloat = 16
        // Keeps the enlarged thumb inside the seek control at both endpoints.
        static let seekInset: CGFloat = 12
        static let seekTrackHeight: CGFloat = 6
    }

    private var state: PlayerState { playerService.state }
    private var sleepTimer: SleepTimer { .shared }
    private var isAutoPlayNextEnabled: Bool {
        appEnvironment?.settingsManager.queueAutoPlayNext ?? true
    }
    private var duration: TimeInterval {
        state.duration.isFinite ? max(0, state.duration) : 0
    }
    private var displayedTime: TimeInterval {
        boundedTime(scrubTime ?? pendingSeekTime ?? state.currentTime)
    }
    private var isTransportDisabled: Bool {
        state.isTransportDisabled || state.isControlsLocked
    }
    private var isSeekDisabled: Bool {
        isTransportDisabled || state.isLive || duration <= 0
    }
    private var timeLabel: String {
        state.isLive ? state.formattedDuration : "\(displayedTime.formattedAsTimestamp) / \(duration.formattedAsTimestamp)"
    }
    private var isHapticFeedbackEnabled: Bool {
        guard let settings = appEnvironment?.settingsManager else { return true }
        return settings.hapticFeedbackEnabled && settings.hapticFeedbackIntensity != .off
    }

    var body: some View {
        panelContent
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .foregroundStyle(.primary)
            .tint(nowPlayingAccent)
            .sensoryFeedback(.impact(weight: .light), trigger: transportFeedbackTrigger) { _, _ in
                isHapticFeedbackEnabled
            }
            .alert(String(localized: "videoInfo.download.remove.title"), isPresented: $showingDeleteDownloadConfirmation) {
                Button(String(localized: "common.cancel"), role: .cancel) {}
                Button(String(localized: "videoInfo.download.remove.confirm"), role: .destructive) {
                    if let download = downloadToDelete {
                        Task {
                            await appEnvironment?.downloadManager.delete(download)
                        }
                    }
                }
            } message: {
                Text(String(localized: "videoInfo.download.remove.message"))
            }
            .sheet(isPresented: $showingDetails) {
                detailsSheet { showingDetails = false }
            }
            .sheet(isPresented: $showingComments) {
                if let video = state.currentVideo {
                    CommentsView(video: video) {
                        showingCommentDetails = true
                    }
                    .id(video.id)
                    .sheet(isPresented: $showingCommentDetails) {
                        detailsSheet { showingCommentDetails = false }
                    }
                }
            }
            .onChange(of: state.currentVideo?.id) { _, _ in
                pendingSeekTime = nil
            }
            .accessibilityAction(.escape, onClose)
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    playerContent
                        .frame(minHeight: geometry.size.height, alignment: .center)

                    inlineQueue
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, Layout.horizontalPadding)
                        .padding(.bottom, Layout.mediumSpacing)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var playerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Center the artwork and controls as one group, with fixed gaps
            // that leave room for full-width artwork on smaller phones.
            artwork
                .padding(.bottom, Layout.mediumSpacing)
            videoInfo
            seekControls
                .id(state.currentVideo?.id)
                .padding(.top, Layout.smallSpacing)
            transportControls
                .padding(.top, Layout.mediumSpacing)
            if case .failed(let error) = state.playbackState {
                Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await playerService.replayCurrentVideo() } }
            }
            if let segment = state.currentSegment {
                SponsorBlockOverlay(segment: segment) {
                    await playerService.seek(to: segment.endTime)
                } onDismiss: {
                    state.currentSegment = nil
                }
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.mediumSpacing)
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                topBarSymbol("chevron.down")
            }
            .buttonStyle(.plain)
            .topBarCircle()
            .accessibilityLabel(String(localized: "player.nowPlaying.close"))

            Spacer()

            Menu {
                if let video = state.currentVideo {
                    playerMenuItems(for: video)
                }
            } label: {
                topBarSymbol("ellipsis")
            }
            // Let the shared label define the glass instead of the menu style.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
            .topBarCircle()
            .disabled(state.currentVideo == nil)
            .accessibilityLabel(String(localized: "controls.button.more"))
        }
        .tint(.primary)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.smallSpacing)
    }

    private func topBarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 34, height: 34, alignment: .center)
            .contentShape(Circle())
    }

    @ViewBuilder
    private func playerMenuItems(for video: Video) -> some View {
        let shareURL = appEnvironment?.shareURL(for: video) ?? video.shareURL

        Section {
            Button {
                presentAppSheet(.queue())
            } label: {
                Label(String(localized: "controls.button.queue"), systemImage: "list.bullet")
            }

            Button {
                showingComments = true
            } label: {
                Label(String(localized: "videoInfo.section.comments"), systemImage: "text.bubble")
            }
            .disabled(!video.supportsComments)

            Button {
                showingDetails = true
            } label: {
                Label("Details", systemImage: "info.circle")
            }
        }

        Section {
            downloadMenuItem(for: video)

            Button {
                presentAppSheet(.addToPlaylist(video))
            } label: {
                Label(String(localized: "video.context.addToPlaylist"), systemImage: "text.badge.plus")
            }

            ShareLink(item: shareURL) {
                Label(String(localized: "video.context.share"), systemImage: "square.and.arrow.up")
            }

            Button {
                UIPasteboard.general.string = shareURL.absoluteString
            } label: {
                Label(String(localized: "video.context.copyLink"), systemImage: "doc.on.doc")
            }

            if video.id.youtubeURL() != nil {
                Button {
                    if let url = video.id.youtubeURL(startTime: state.currentTime) {
                        openURL(url)
                    }
                } label: {
                    Label(String(localized: "video.context.openInYouTube"), systemImage: "play.rectangle")
                }
            }

            Button {
                appEnvironment?.navigationCoordinator.navigateToChannel(for: video, collapsePlayer: true)
            } label: {
                Label(String(localized: "video.context.goToChannel"), systemImage: "person.circle")
            }
            .disabled(!video.author.hasRealChannelInfo)
        }
    }

    @ViewBuilder
    private func downloadMenuItem(for video: Video) -> some View {
        if let manager = appEnvironment?.downloadManager,
           manager.isDownloading(video.id), let download = manager.download(for: video.id) {
            Button(role: .destructive) {
                Task { await manager.cancel(download) }
            } label: {
                Label(String(localized: "video.context.cancelDownload"), systemImage: "xmark.circle")
            }
        } else if let manager = appEnvironment?.downloadManager,
                  manager.isDownloaded(video.id), let download = manager.download(for: video.id) {
            Button {
                downloadToDelete = download
                showingDeleteDownloadConfirmation = true
            } label: {
                Label(String(localized: "video.context.downloaded"), systemImage: "checkmark.circle.fill")
            }
        } else {
            Button {
                presentAppSheet(.downloadOptions(video, streams: playerService.availableStreams, dislikeCount: state.dislikeCount))
            } label: {
                Label(String(localized: "video.context.download"), systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Inline Queue

    private var queueTitle: String {
        guard let queueManager = appEnvironment?.queueManager,
              case .playlist = queueManager.currentQueueSource,
              let title = queueManager.currentQueueSourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return String(localized: "queue.section.upNext")
        }
        return title
    }

    private var inlineQueue: some View {
        VStack(alignment: .leading, spacing: Layout.mediumSpacing) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, Layout.smallSpacing)
                .accessibilityHidden(true)

            HStack(spacing: Layout.smallSpacing) {
                Text(queueTitle)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)

                Button {
                    presentAppSheet(.queue())
                } label: {
                    Image(systemName: "text.badge.plus")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "controls.button.queue"))
            }

            autoplayRow

            if !state.queue.isEmpty {
                inlineQueueItems
            }
        }
    }

    private var autoplayRow: some View {
        Toggle(isOn: Binding(
            get: { isAutoPlayNextEnabled },
            set: { appEnvironment?.settingsManager.queueAutoPlayNext = $0 }
        )) {
            HStack(spacing: Layout.mediumSpacing) {
                Image(systemName: "infinity")
                    .font(.title2)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "player.nowPlaying.autoplay"))
                        .font(.body.weight(.semibold))
                    Text("Play similar audio when the queue ends")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(nowPlayingAccent)
        .disabled(state.isControlsLocked || appEnvironment == nil)
    }

    private var inlineQueueItems: some View {
        LazyVStack(spacing: 4) {
            if let currentVideo = state.currentVideo {
                QueueItemRow(
                    video: currentVideo,
                    isCurrentlyPlaying: true,
                    onReorder: { presentAppSheet(.queue(reordering: true)) },
                    onTap: {
                        if !isTransportDisabled, state.playbackState != .playing {
                            playerService.togglePlayPause()
                        }
                    }
                )
            }

            ForEach(state.queue) { item in
                QueueItemRow(
                    video: item.video,
                    isCurrentlyPlaying: false,
                    onRemove: {
                        withAnimation {
                            appEnvironment?.queueManager.removeFromQueue(id: item.id)
                        }
                    },
                    onReorder: { presentAppSheet(.queue(reordering: true)) },
                    onTap: {
                        guard let index = state.queue.firstIndex(where: { $0.id == item.id }) else { return }
                        QueuePlaybackActions.playVideo(at: index, appEnvironment: appEnvironment)
                    }
                )
            }
        }
    }

    // MARK: - Header and Video

    private var artworkURLs: [URL] {
        guard let video = state.currentVideo else { return [] }
        let localURL: URL? = if let manager = appEnvironment?.downloadManager,
                               let path = manager.download(for: video.id)?.localThumbnailPath {
            manager.downloadsDirectory().appendingPathComponent(path)
        } else { nil }
        return [localURL, appEnvironment?.deArrowBrandingProvider.thumbnailURL(for: video)].compactMap { $0 }
            + video.thumbnailURLsByQuality
    }

    private var artwork: some View {
        Rectangle().fill(.quaternary)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                FallbackLazyImage(urls: artworkURLs) { imageState in
                    if let image = imageState.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                            .overlay { Image(systemName: "music.note").font(.system(size: 64)).foregroundStyle(.secondary) }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func detailsSheet(onClose: @escaping () -> Void) -> some View {
        NavigationStack {
            ScrollView {
                if let video = state.currentVideo {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(video.title).font(.title2.bold())
                        Button(video.author.name) {
                            onClose()
                            appEnvironment?.navigationCoordinator.navigateToChannel(for: video, collapsePlayer: true)
                        }
                        Text(DescriptionText.attributed(video.description ?? "", linkColor: .red))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetCloseToolbarItem(action: onClose) }
        }
    }

    private var videoTitle: String {
        guard let video = state.currentVideo else { return "" }
        return appEnvironment?.deArrowBrandingProvider.title(for: video) ?? video.title
    }

    private var videoInfo: some View {
        Button {
            showingDetails = true
        } label: {
            videoInfoText
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.currentVideo == nil)
        .accessibilityLabel(videoTitle)
        .accessibilityHint("Shows details")
    }

    private var videoInfoText: some View {
        VStack(alignment: .leading, spacing: Layout.smallSpacing) {
            if let video = state.currentVideo {
                PlayerMarqueeText(text: videoTitle)
                    .font(.title3.bold())
                    .id(video.id)

                Text(video.author.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Seeking

    private var seekControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                let trackWidth = max(1, geometry.size.width)
                let progress = duration > 0 ? CGFloat(displayedTime / duration) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: Layout.seekTrackHeight)
                    Capsule()
                        .fill(nowPlayingAccent)
                        .frame(width: trackWidth * progress, height: Layout.seekTrackHeight)
                    Circle()
                        .fill(nowPlayingAccent)
                        .frame(width: 20, height: 20)
                        .scaleEffect(scrubTime == nil ? 1 : 1.2)
                        .animation(.easeOut(duration: 0.15), value: scrubTime != nil)
                        .offset(x: min(max(0, trackWidth * progress - 10), trackWidth - 20))
                }
                .frame(width: trackWidth, height: 44)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($scrubTime) { value, time, _ in
                            guard !isSeekDisabled else { return }
                            time = seekTime(at: value.location.x, trackWidth: trackWidth)
                        }
                        .onEnded { value in
                            seek(to: seekTime(at: value.location.x, trackWidth: trackWidth))
                        }
                )
            }
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "player.nowPlaying.playbackPosition"))
            .accessibilityValue(timeLabel)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: seek(to: displayedTime + 10)
                case .decrement: seek(to: displayedTime - 10)
                @unknown default: break
                }
            }
            .disabled(isSeekDisabled)
            .opacity(isSeekDisabled ? 0.4 : 1)

            HStack {
                if state.isLive {
                    Text(String(localized: "player.live"))
                } else {
                    Text(verbatim: displayedTime.formattedAsTimestamp)
                    Spacer(minLength: Layout.smallSpacing)
                    Text(verbatim: "-\(max(0, duration - displayedTime).formattedAsTimestamp)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func boundedTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? min(max(0, time), duration) : 0
    }

    private func seekTime(at position: CGFloat, trackWidth: CGFloat) -> TimeInterval {
        boundedTime(Double(position / trackWidth) * duration)
    }

    private func seek(to time: TimeInterval) {
        guard !isSeekDisabled else { return }
        let target = boundedTime(time)
        let videoID = state.currentVideo?.id
        pendingSeekTime = target
        Task {
            await playerService.seek(to: target)
            if state.currentVideo?.id == videoID, pendingSeekTime == target {
                pendingSeekTime = nil
            }
        }
    }

    // MARK: - Transport

    @ViewBuilder
    private var transportControls: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: Layout.mediumSpacing) {
                transportButtons
            }
        } else {
            transportButtons
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 0) {
            playbackSpeedMenu
            Spacer(minLength: 0)
            transportButton("gobackward.10", label: String(localized: "menu.playback.seekBackward \(10)"), disabled: isSeekDisabled) {
                playerService.seekBackward(by: 10)
            }
            Spacer(minLength: 0)
            Button {
                transportFeedbackTrigger.toggle()
                playerService.togglePlayPause()
            } label: {
                playPauseLabel
            }
            .modifier(OnTheGoPlayPauseStyleModifier())
            .disabled(isTransportDisabled)
            .accessibilityLabel(state.playbackState == .playing ? String(localized: "player.controls.pause") : String(localized: "player.controls.play"))
            Spacer(minLength: 0)
            transportButton("goforward.10", label: String(localized: "menu.playback.seekForward \(10)"), disabled: isSeekDisabled) {
                playerService.seekForward(by: 10)
            }
            Spacer(minLength: 0)
            sleepTimerMenu
        }
    }

    @ViewBuilder
    private var playPauseLabel: some View {
        if #available(iOS 26, *) {
            playPauseSymbol
                .font(.system(size: 36, weight: .bold))
                .frame(width: 64, height: 64)
        } else {
            playPauseSymbol
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 104, height: 104)
                .background(nowPlayingAccent, in: Circle())
                .opacity(isTransportDisabled ? 0.4 : 1)
                .contentShape(Circle())
        }
    }

    private var playPauseSymbol: some View {
        Image(systemName: state.playbackState == .playing ? "pause.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp)))
            .animation(.snappy, value: state.playbackState == .playing)
    }

    private func transportButton(_ image: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            transportFeedbackTrigger.toggle()
            action()
        } label: {
            transportSymbol(image)
        }
        .buttonStyle(OnTheGoTransportButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    // MARK: - Playback Menus

    private var playbackSpeedMenu: some View {
        Menu {
            Picker(String(localized: "controls.button.speed"), selection: Binding(
                get: { state.rate },
                set: { rate in
                    state.rate = rate
                    playerService.currentBackend?.rate = Float(rate.rawValue)
                }
            )) {
                ForEach(PlaybackRate.allCases) { rate in
                    Text(rate.displayText).tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            transportValue(playbackSpeedText, color: state.rate != .x1 ? nowPlayingAccent : .primary)
        }
        .transportMenuStyle()
        .disabled(state.isControlsLocked)
        .accessibilityLabel(String(localized: "controls.button.speed"))
        .accessibilityValue(playbackSpeedText)
    }

    private var playbackSpeedText: String {
        state.rate.compactDisplayText.replacingOccurrences(of: "x", with: "×")
    }

    private var sleepTimerMenu: some View {
        Menu {
            if let remainingTime = sleepTimer.caption {
                Button(remainingTime) {}
                    .disabled(true)
            }
            sleepTimerOption(String(localized: "common.off"), isSelected: sleepTimer.mode == .off) {
                sleepTimer.cancel()
            }
            ForEach(SleepTimer.durationOptions, id: \.self) { minutes in
                sleepTimerOption(String(localized: "\(minutes) minutes"), isSelected: sleepTimer.selectedMinutes == minutes) {
                    sleepTimer.start(minutes: minutes, playerService: playerService)
                }
            }
            sleepTimerOption(String(localized: "End of video"), isSelected: sleepTimer.mode == .endOfVideo) {
                sleepTimer.startEndOfVideo(playerService: playerService)
            }
            .disabled(state.currentVideo == nil)
        } label: {
            transportValue(sleepTimerText, color: sleepTimer.isActive ? nowPlayingAccent : .secondary)
        }
        .transportMenuStyle()
        .disabled(state.isControlsLocked)
        .accessibilityLabel(String(localized: "player.nowPlaying.sleepTimer"))
        .accessibilityValue(sleepTimerAccessibilityValue)
    }

    private var sleepTimerText: String {
        switch sleepTimer.mode {
        case .off:
            return String(localized: "common.off")
        case .duration:
            let seconds = sleepTimer.remainingSeconds
            if seconds >= 3600 {
                return TimeInterval(seconds).formattedAsTimestamp
            }
            return String(format: "%02d:%02d", seconds / 60, seconds % 60)
        case .endOfVideo:
            return String(localized: "End")
        }
    }

    private var sleepTimerAccessibilityValue: String {
        switch sleepTimer.mode {
        case .off:
            return String(localized: "common.off")
        case .duration:
            let remainingTime = Duration.seconds(sleepTimer.remainingSeconds)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
            return String(localized: "\(remainingTime) left")
        case .endOfVideo:
            return String(localized: "End of video")
        }
    }

    private func transportValue(_ value: String, color: Color) -> some View {
        Text(verbatim: value)
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: 56, height: 44, alignment: .center)
            .contentShape(Rectangle())
    }

    private func transportSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolVariant(.none)
            .font(.system(size: 32, weight: .regular))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func sleepTimerOption(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }
}

// MARK: - Top Bar Styling

private extension View {
    /// Glass is applied outside Button/Menu so both get an identical 34pt circle;
    /// the outer frame keeps a 44pt hit area.
    func topBarCircle() -> some View {
        self
            .frame(width: 34, height: 34)
            .modifier(OnTheGoTopBarStyleModifier())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct OnTheGoTopBarStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.quaternary, in: Circle())
        }
    }
}

// MARK: - Transport Styling

private extension View {
    func transportMenuStyle() -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(OnTheGoTransportButtonStyle())
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
    }
}

private struct OnTheGoPlayPauseStyleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(nowPlayingAccent)
                .foregroundStyle(.white)
                .buttonBorderShape(.circle)
                .buttonSizing(.flexible)
                .frame(width: 104, height: 104)
        } else {
            content.buttonStyle(OnTheGoTransportButtonStyle())
        }
    }
}

private struct OnTheGoTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
