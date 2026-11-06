//
//  OnTheGoPanel.swift
//  Yattee
//
//  The full audio player, with album artwork and transport controls.
//

import Foundation
import SwiftUI
import UIKit
import Nuke
import NukeUI

private let nowPlayingAccent = Color.red

@MainActor
struct OnTheGoPanel: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.presentAppSheet) private var presentAppSheet
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let playerService: PlayerService
    let onClose: () -> Void

    @GestureState private var scrubTime: TimeInterval? = nil
    @State private var pendingSeekTime: TimeInterval?
    @State private var transportFeedbackTrigger = false
    @State private var showingPlayerMenu = false
    @State private var shareRequest = 0
    @State private var showingDetails = false
    @State private var showingComments = false
    @State private var showingCommentDetails = false
    @State private var showingDeleteDownloadConfirmation = false
    @State private var downloadToDelete: Download?
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var hasScrolledPastTransport = false
    @State private var selectedPage = PlayerPage.artwork
    @State private var lyricsPageProgress: CGFloat = 0
    @State private var lyrics = LyricsViewModel()
    @State private var lyricsArtworkColor = LyricsArtworkColor.fallback
    @State private var isPaging = false

    private enum PlayerPage: Hashable, Sendable {
        case artwork
        case lyrics
    }

    private enum ScrollCoordinateSpace: Hashable, Sendable {
        case player
    }

    private enum Layout {
        static let horizontalPadding: CGFloat = 16
        static let smallSpacing: CGFloat = 8
        static let mediumSpacing: CGFloat = 16
        // Reserve the same space for both headers to keep the scroll threshold stable.
        static let headerHeight = CompactPlayerCard.height + smallSpacing * 2
        // Keeps the enlarged thumb inside the seek control at both endpoints.
        static let seekInset: CGFloat = 12
        static let seekTrackHeight: CGFloat = 6
        static let transportHeight: CGFloat = 104
        static let transportMenuWidth: CGFloat = 56
    }

    private var state: PlayerState { playerService.state }
    private var showingLyrics: Bool { selectedPage == .lyrics }
    private var hasLyrics: Bool {
        lyrics.videoID == state.currentVideo?.id.videoID && !lyrics.tracks.isEmpty
    }
    private var isStickyPlayerVisible: Bool {
        hasScrolledPastTransport && state.currentVideo != nil
    }
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
            // System presentations use the nearer page's scheme. Visible controls
            // resolve their original colors separately so this never flips them.
            .environment(\.colorScheme, lyricsPageProgress > 0.5 ? .dark : colorScheme)
            .background(panelBackground.ignoresSafeArea())
            .foregroundStyle(controlPrimaryColor)
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
                isPaging = false
                selectPage(.artwork, animated: false)
                lyricsArtworkColor = .fallback
            }
            .onChange(of: hasLyrics) { _, available in
                if !available { selectPage(.artwork, animated: false) }
            }
            .onDisappear {
                isPaging = false
                selectPage(selectedPage, animated: false)
            }
            .onChange(of: selectedPage) { _, page in
                let backendID = playerService.currentBackend.map { String(describing: ObjectIdentifier($0)) } ?? "none"
                LoggingService.shared.debug(
                    "Player page: \(page), service: \(ObjectIdentifier(playerService)), backend: \(backendID), time: \(state.currentTime), state: \(state.playbackState)",
                    category: .player
                )
            }
            .task(id: state.currentVideo?.id) {
                let video = state.currentVideo
                await lyrics.loadTracks(
                    videoID: video?.id.videoID,
                    instance: video.flatMap { appEnvironment?.instancesManager.instance(for: $0) },
                    contentService: appEnvironment?.contentService
                )
            }
            .accessibilityAction(.escape, onClose)
    }

    // MARK: - Page Progress and Appearance

    private var pageSnapAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.38)
    }

    private var controlPrimaryColor: Color {
        pageColor(from: .primary, to: .white)
    }

    private var controlSecondaryColor: Color {
        pageColor(from: .secondary, to: .white.opacity(0.6))
    }

    private func pageColor(from normalColor: Color, to lyricsColor: Color) -> Color {
        // Resolve before the panel's forced dark scheme. This is inexpensive
        // color interpolation; artwork sampling stays in the image-loading task.
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let normalColor = Color(normalColor.resolve(in: environment))
        return normalColor.mix(with: lyricsColor, by: Double(lyricsPageProgress))
    }

    private func selectPage(_ page: PlayerPage, animated: Bool = true) {
        withAnimation(animated ? pageSnapAnimation : nil) {
            selectedPage = page
            lyricsPageProgress = page == .lyrics ? 1 : 0
        }
    }

    private func pageProgress(translation: CGFloat, width: CGFloat) -> CGFloat {
        let start: CGFloat = showingLyrics ? 1 : 0
        return min(1, max(0, start - translation / max(1, width)))
    }

    // Only the content area accepts paging; the shared header, controls and queue keep their gestures.
    private func lyricsPageGesture(width: CGFloat) -> LyricsPageDragGesture {
        LyricsPageDragGesture(
            onChanged: { translation in
                if !isPaging {
                    isPaging = true
                    LoggingService.shared.debug(
                        "Player paging began: \(selectedPage), translation: \(translation)", category: .player
                    )
                }
                guard hasLyrics, !state.isControlsLocked else { return }
                // Never ease or spring while tracking the finger.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    lyricsPageProgress = pageProgress(translation: translation, width: width)
                }
            },
            onEnded: { projectedTranslation in
                isPaging = false
                guard hasLyrics, !state.isControlsLocked else {
                    selectPage(selectedPage)
                    return
                }
                let projectedProgress = pageProgress(translation: projectedTranslation, width: width)
                selectPage(projectedProgress > 0.5 ? .lyrics : .artwork)
            },
            onCancelled: {
                isPaging = false
                selectPage(selectedPage)
                LoggingService.shared.debug("Player paging cancelled: \(selectedPage)", category: .player)
            }
        )
    }

    @ViewBuilder
    private var lyricsPageIndicator: some View {
        if hasLyrics {
            HStack(spacing: 6) {
                ForEach(0..<2) { page in
                    Circle()
                        .fill(controlPrimaryColor.opacity(page == 0
                            ? 0.85 - 0.6 * Double(lyricsPageProgress)
                            : 0.25 + 0.6 * Double(lyricsPageProgress)))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Layout.smallSpacing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Player pages")
            .accessibilityValue(showingLyrics ? "Lyrics" : "Artwork")
            .accessibilityAdjustableAction { direction in
                guard !state.isControlsLocked else { return }
                switch direction {
                case .increment: selectPage(.lyrics)
                case .decrement: selectPage(.artwork)
                @unknown default: break
                }
            }
        }
    }

    private var panelBackground: some View {
        ZStack {
            Color(.systemBackground)
            lyricsArtworkColor.color
                .animation(.easeInOut(duration: 0.4), value: lyricsArtworkColor)
                .opacity(Double(lyricsPageProgress))
        }
        .environment(\.colorScheme, colorScheme)
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    playerContent
                        .frame(minHeight: max(0, geometry.size.height - Layout.headerHeight), alignment: .center)

                    if !state.queue.isEmpty {
                        inlineQueue
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Layout.horizontalPadding)
                            .padding(.top, Layout.mediumSpacing)
                            .padding(.bottom, Layout.mediumSpacing)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($scrollPosition)
            .safeAreaInset(edge: .top, spacing: 0) {
                playerHeader
            }
            .coordinateSpace(name: ScrollCoordinateSpace.player)
        }
    }

    private var playerContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            pagedContent
                .padding(.bottom, Layout.mediumSpacing)
            playerControls
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.mediumSpacing)
    }

    private var playerControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            videoInfo
            lyricsPageIndicator
            seekControls
                .id(state.currentVideo?.id)
                .padding(.top, Layout.smallSpacing)
            transportControls
                .padding(.top, Layout.mediumSpacing)
                .onGeometryChange(for: Bool.self) { geometry in
                    // The viewport includes the reserved header above its visible content.
                    geometry.frame(in: .named(ScrollCoordinateSpace.player)).maxY <= Layout.headerHeight
                } action: { hasScrolledPastTransport = $0 }
            playbackNotices
        }
    }

    @ViewBuilder
    private var playbackNotices: some View {
        if case .failed(let error) = state.playbackState {
            Text(error.localizedDescription).font(.caption).foregroundStyle(controlSecondaryColor)
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

    // MARK: - Paged Content

    private var pagedContent: some View {
        // Both pages occupy the artwork's square, so paging cannot resize or replace the controls.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let progress = lyricsPageProgress
                    ZStack {
                        artwork
                            .environment(\.colorScheme, colorScheme)
                            .scaleEffect(reduceMotion ? 1 : 1 - 0.1 * progress)
                            .opacity(Double(1 - progress))
                            .offset(x: reduceMotion ? 0 : -geometry.size.width * progress)

                        if hasLyrics {
                            LyricsView(
                                model: lyrics,
                                playerState: state,
                                isSeekDisabled: isSeekDisabled,
                                isActive: progress > 0 || showingLyrics,
                                isPaging: isPaging,
                                onSeek: seek
                            )
                            .environment(\.colorScheme, .dark)
                            .scaleEffect(reduceMotion ? 1 : 0.95 + 0.05 * progress)
                            .opacity(Double(progress))
                            .offset(x: reduceMotion ? 0 : geometry.size.width * (1 - progress))
                            .allowsHitTesting(showingLyrics)
                            .accessibilityHidden(!showingLyrics)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .gesture(lyricsPageGesture(width: geometry.size.width))
                }
            }
            .clipped()
    }

    // MARK: - Top Bar

    private var playerHeader: some View {
        ZStack {
            topBar
                .opacity(isStickyPlayerVisible ? 0 : 1)
                .allowsHitTesting(!isStickyPlayerVisible)
                .accessibilityHidden(isStickyPlayerVisible)

            if isStickyPlayerVisible {
                CompactPlayerCard(
                    playerService: playerService,
                    actionLabel: "player.nowPlaying.title",
                    actionHint: "Returns to the player controls"
                ) {
                    withAnimation(.snappy) {
                        scrollPosition.scrollTo(edge: .top)
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Layout.horizontalPadding)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(height: CompactPlayerCard.height)
        .padding(.vertical, Layout.smallSpacing)
        .animation(.snappy, value: isStickyPlayerVisible)
    }

    private var topBar: some View {
        HStack {
            Button(action: onClose) {
                topBarSymbol("chevron.down")
            }
            .buttonStyle(.plain)
            .topBarCircle(colorScheme: colorScheme, lyricsProgress: Double(lyricsPageProgress))
            .accessibilityLabel(String(localized: "player.nowPlaying.close"))

            Spacer()

            Button {
                showingPlayerMenu = true
            } label: {
                topBarSymbol("ellipsis")
            }
            .buttonStyle(.plain)
            .topBarCircle(colorScheme: colorScheme, lyricsProgress: Double(lyricsPageProgress))
            .background {
                if let video = state.currentVideo {
                    // Keep the share presenter attached after the popover disappears.
                    ShareLink(item: appEnvironment?.shareURL(for: video) ?? video.shareURL) {
                        Color.clear
                    }
                    .buttonStyle(OnTheGoShareLinkStyle(request: shareRequest))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .popover(isPresented: $showingPlayerMenu, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                if let video = state.currentVideo {
                    playerMenuItems(for: video)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .disabled(state.currentVideo == nil)
            .accessibilityLabel(String(localized: "controls.button.more"))
        }
        .tint(controlPrimaryColor)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.smallSpacing)
    }

    private func topBarSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(controlPrimaryColor)
            .frame(width: 34, height: 34, alignment: .center)
            .contentShape(Circle())
    }

    @ViewBuilder
    private func playerMenuItems(for video: Video) -> some View {
        let shareURL = appEnvironment?.shareURL(for: video) ?? video.shareURL

        VStack(spacing: 0) {
            autoplayMenuRow

            playerMenuSeparator

            Button {
                dismissPlayerMenu { selectPage(showingLyrics ? .artwork : .lyrics) }
            } label: {
                playerMenuRow(String(localized: "Lyrics"), systemImage: showingLyrics ? "quote.bubble.fill" : "quote.bubble")
            }
            .disabled(!hasLyrics || state.isControlsLocked)
            .accessibilityValue(showingLyrics ? "On" : "Off")
            .contextMenu {
                if lyrics.tracks.count > 1 {
                    Section("Lyrics language") {
                        LyricsTrackOptions(model: lyrics)
                    }
                }
            }

            if lyrics.tracks.count > 1 {
                Menu {
                    LyricsTrackOptions(model: lyrics)
                } label: {
                    HStack(spacing: 8) {
                        Text("Lyrics language")
                        Spacer(minLength: 0)
                        Text(lyrics.selectedTrack?.label ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .accessibilityLabel("Lyrics language")
                .accessibilityValue(lyrics.selectedTrack?.label ?? "")
            }

            Button {
                dismissPlayerMenu { presentAppSheet(.queue()) }
            } label: {
                playerMenuRow(String(localized: "controls.button.queue"), systemImage: "list.bullet")
            }

            Button {
                dismissPlayerMenu { showingComments = true }
            } label: {
                playerMenuRow(String(localized: "videoInfo.section.comments"), systemImage: "text.bubble")
            }
            .disabled(!video.supportsComments)

            Button {
                dismissPlayerMenu { showingDetails = true }
            } label: {
                playerMenuRow(String(localized: "Details"), systemImage: "info.circle")
            }

            playerMenuSeparator

            downloadMenuItem(for: video)

            Button {
                dismissPlayerMenu { presentAppSheet(.addToPlaylist(video)) }
            } label: {
                playerMenuRow(String(localized: "video.context.addToPlaylist"), systemImage: "text.badge.plus")
            }

            Button {
                dismissPlayerMenu { shareRequest += 1 }
            } label: {
                playerMenuRow(String(localized: "video.context.share"), systemImage: "square.and.arrow.up")
            }

            Button {
                dismissPlayerMenu { UIPasteboard.general.string = shareURL.absoluteString }
            } label: {
                playerMenuRow(String(localized: "video.context.copyLink"), systemImage: "doc.on.doc")
            }

            if video.id.youtubeURL() != nil {
                Button {
                    dismissPlayerMenu {
                        if let url = video.id.youtubeURL(startTime: state.currentTime) {
                            openURL(url)
                        }
                    }
                } label: {
                    playerMenuRow(String(localized: "video.context.openInYouTube"), systemImage: "play.rectangle")
                }
            }

            Button {
                dismissPlayerMenu {
                    appEnvironment?.navigationCoordinator.navigateToChannel(for: video, collapsePlayer: true)
                }
            } label: {
                playerMenuRow(String(localized: "video.context.goToChannel"), systemImage: "person.circle")
            }
            .disabled(!video.author.hasRealChannelInfo)
        }
        .font(.body)
        .buttonStyle(OnTheGoMenuButtonStyle())
        .tint(nowPlayingAccent)
        .padding(.vertical, 8)
        .frame(width: 250)
    }

    private var autoplayMenuRow: some View {
        let title = String(localized: "player.nowPlaying.autoplay")

        return Button {
            appEnvironment?.settingsManager.queueAutoPlayNext.toggle()
        } label: {
            playerMenuRow(title, systemImage: "infinity")
                .padding(.trailing, 60)
                .contentShape(Rectangle())
        }
        .accessibilityHidden(true)
        .overlay(alignment: .trailing) {
            Toggle(title, isOn: Binding(
                get: { isAutoPlayNextEnabled },
                set: { appEnvironment?.settingsManager.queueAutoPlayNext = $0 }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .padding(.trailing, 16)
        }
        .disabled(state.isControlsLocked || appEnvironment == nil)
    }

    private func playerMenuRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private var playerMenuSeparator: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 8)
            .accessibilityHidden(true)
    }

    private func dismissPlayerMenu(perform action: @escaping @MainActor () -> Void) {
        showingPlayerMenu = false
        Task { @MainActor in
            // Let the popover finish dismissing before presenting sheets or sharing.
            try? await Task.sleep(for: .milliseconds(350))
            action()
        }
    }

    @ViewBuilder
    private func downloadMenuItem(for video: Video) -> some View {
        if let manager = appEnvironment?.downloadManager,
           manager.isDownloading(video.id), let download = manager.download(for: video.id) {
            Button(role: .destructive) {
                dismissPlayerMenu {
                    Task { await manager.cancel(download) }
                }
            } label: {
                playerMenuRow(String(localized: "video.context.cancelDownload"), systemImage: "xmark.circle")
            }
        } else if let manager = appEnvironment?.downloadManager,
                  manager.isDownloaded(video.id), let download = manager.download(for: video.id) {
            Button {
                dismissPlayerMenu {
                    downloadToDelete = download
                    showingDeleteDownloadConfirmation = true
                }
            } label: {
                playerMenuRow(String(localized: "video.context.downloaded"), systemImage: "checkmark.circle.fill")
            }
        } else {
            Button {
                dismissPlayerMenu {
                    presentAppSheet(.downloadOptions(video, streams: playerService.availableStreams, dislikeCount: state.dislikeCount))
                }
            } label: {
                playerMenuRow(String(localized: "video.context.download"), systemImage: "arrow.down.circle")
            }
        }
    }

    // MARK: - Inline Queue

    private var inlineQueue: some View {
        VStack(alignment: .leading, spacing: Layout.mediumSpacing) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .padding(.top, Layout.smallSpacing)
                .accessibilityHidden(true)

            inlineQueueItems
        }
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
                artworkImage(placeholderSize: 64)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private func artworkImage(placeholderSize: CGFloat) -> some View {
        let videoID = state.currentVideo?.id.videoID
        return FallbackLazyImage(urls: artworkURLs) { imageState in
            Group {
                if let image = imageState.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                        .overlay { Image(systemName: "music.note").font(.system(size: placeholderSize)).foregroundStyle(.secondary) }
                }
            }
            .task(id: imageState.imageContainer?.image) {
                guard let videoID, let container = imageState.imageContainer,
                      !container.isPreview, let image = container.image.cgImage else { return }
                let color = await LyricsArtworkColorCache.shared.color(for: videoID, image: image)
                guard !Task.isCancelled, state.currentVideo?.id.videoID == videoID else { return }
                lyricsArtworkColor = color
            }
        }
        .id(videoID)
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
                    .foregroundStyle(controlPrimaryColor)
                    .id(video.id)

                Text(video.author.name)
                    .font(.subheadline)
                    .foregroundStyle(controlSecondaryColor)
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
                        .fill(controlSecondaryColor.opacity(0.25))
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
            .foregroundStyle(controlSecondaryColor)
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
        GeometryReader { geometry in
            let centerY = geometry.size.height / 2
            let menuHalfWidth = Layout.transportMenuWidth / 2

            // Use the timeline's full width, with the middle controls at quarter points.
            // The edge menus' hit areas extend inward from the timeline endpoints.
            ZStack {
                playbackSpeedMenu
                    .position(x: menuHalfWidth, y: centerY)

                transportButton("gobackward.10", label: String(localized: "menu.playback.seekBackward \(10)"), disabled: isSeekDisabled) {
                    playerService.seekBackward(by: 10)
                }
                .position(x: geometry.size.width / 4, y: centerY)

                Button {
                    transportFeedbackTrigger.toggle()
                    playerService.togglePlayPause()
                } label: {
                    playPauseLabel
                }
                .modifier(OnTheGoPlayPauseStyleModifier())
                .environment(\.colorScheme, colorScheme)
                .disabled(isTransportDisabled)
                .accessibilityLabel(state.playbackState == .playing ? String(localized: "player.controls.pause") : String(localized: "player.controls.play"))
                .position(x: geometry.size.width / 2, y: centerY)

                transportButton("goforward.10", label: String(localized: "menu.playback.seekForward \(10)"), disabled: isSeekDisabled) {
                    playerService.seekForward(by: 10)
                }
                .position(x: geometry.size.width * 3 / 4, y: centerY)

                sleepTimerMenu
                    .position(x: geometry.size.width - menuHalfWidth, y: centerY)
            }
        }
        .frame(height: Layout.transportHeight)
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
                .frame(width: Layout.transportHeight, height: Layout.transportHeight)
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
            transportValue(playbackSpeedText, color: state.rate != .x1 ? nowPlayingAccent : controlPrimaryColor, alignment: .leading)
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
            if sleepTimer.mode == .off {
                sleepOffSymbol
            } else {
                transportValue(sleepTimerText, color: nowPlayingAccent, alignment: .trailing)
            }
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

    private var sleepOffSymbol: some View {
        Image(systemName: "moon.zzz")
            .font(.system(size: 22, weight: .regular))
            .foregroundStyle(controlPrimaryColor)
            .frame(width: Layout.transportMenuWidth, height: 44, alignment: .trailing)
            .contentShape(Rectangle())
    }

    private func transportValue(_ value: String, color: Color, alignment: Alignment) -> some View {
        Text(verbatim: value)
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: Layout.transportMenuWidth, height: 44, alignment: alignment)
            .contentShape(Rectangle())
    }

    private func transportSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolVariant(.none)
            .font(.system(size: 32, weight: .regular))
            .foregroundStyle(controlPrimaryColor)
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

// MARK: - Paging Gesture Arbitration

@MainActor
private struct LyricsPageDragGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {}

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            // Project a short flick ahead, just as DragGesture's predicted end
            // translation did, while keeping tracking tied to the actual finger.
            onEnded(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
        case .cancelled:
            onCancelled()
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let translation = pan.translation(in: pan.view)
            // Decide once, before recognition. Filtering inside onChanged is
            // too late to stop a ScrollView or native zoom back-swipe winning.
            // Reserve diagonal starts for paging too; only predominantly
            // vertical drags may reach scrolling or downward dismissal.
            return abs(translation.x) * 1.5 > abs(translation.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Both scroll pans and the presentation's dismiss/edge recognizers
            // must wait for our direction decision. A horizontal start belongs
            // to the pager for the entire touch, including at either endpoint;
            // vertical starts fail immediately and keep normal scroll/dismiss.
            true
        }
    }
}

// MARK: - Menu Styling

private struct OnTheGoMenuButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.role == .destructive ? nowPlayingAccent : .primary)
            .opacity(isEnabled ? 1 : 0.4)
            .background(configuration.isPressed && isEnabled ? Color.gray.opacity(0.15) : .clear)
    }
}

private struct OnTheGoShareLinkStyle: PrimitiveButtonStyle {
    let request: Int

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: request) { _, _ in
                configuration.trigger()
            }
    }
}

// MARK: - Top Bar Styling

private extension View {
    /// Glass is applied outside Button/Menu so both get an identical 34pt circle;
    /// the outer frame keeps a 44pt hit area.
    func topBarCircle(colorScheme: ColorScheme, lyricsProgress: Double) -> some View {
        self
            .frame(width: 34, height: 34)
            .modifier(OnTheGoTopBarStyleModifier(colorScheme: colorScheme, lyricsProgress: lyricsProgress))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct OnTheGoTopBarStyleModifier: ViewModifier {
    let colorScheme: ColorScheme
    let lyricsProgress: Double

    func body(content: Content) -> some View {
        // Crossfade only the decoration: there is still one interactive button.
        content.background {
            ZStack {
                circleBackground
                    .environment(\.colorScheme, colorScheme)
                    .opacity(1 - lyricsProgress)
                circleBackground
                    .environment(\.colorScheme, .dark)
                    .opacity(lyricsProgress)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var circleBackground: some View {
        if #available(iOS 26, *) {
            Circle().fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)
        } else {
            Circle().fill(.quaternary)
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
