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
    @Environment(\.scenePhase) private var scenePhase

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
    @State private var panelScrollOffset: CGFloat = 0
    @State private var isPanelAtTop = true
    @State private var playerContentHeight: CGFloat = 0
    @State private var playbackNoticesHeight: CGFloat = 0
    @State private var scrollGestureStartOffset: CGFloat = 0
    @State private var selectedPage = PlayerPage.artwork
    @State private var lyricsPageProgress: CGFloat = 0
    @State private var lyrics = LyricsViewModel()
    @State private var lyricsArtworkColor = LyricsArtworkColor.fallback
    @State private var isPaging = false

    private enum PlayerPage: Hashable, Sendable {
        case artwork
        case lyrics
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
        static let coverSeekTrackHeight: CGFloat = 5
        static let coverSeekScrubbingTrackHeight: CGFloat = 8
        static let seekHitHeight: CGFloat = 44
        static let transportHeight: CGFloat = 104
        static let queueMorphDistance: CGFloat = 140

        static func queueContentHeight(coverHeight: CGFloat, topSafeArea: CGFloat, noticesHeight: CGFloat) -> CGFloat {
            queueMorphDistance - headerHeight - topSafeArea + coverHeight
                + smallSpacing + transportHeight + noticesHeight + mediumSpacing
        }
    }

    private enum MenuLayout {
        static let width: CGFloat = 270
        static let rowHeight: CGFloat = 44
        static let horizontalPadding: CGFloat = 16
        static let iconWidth: CGFloat = 24
        static let iconSpacing: CGFloat = 12
    }

    private var state: PlayerState { playerService.state }
    private var showingLyrics: Bool { selectedPage == .lyrics }
    private var hasLyrics: Bool {
        lyrics.videoID == state.currentVideo?.id.videoID && !lyrics.tracks.isEmpty
    }
    private var isStickyPlayerVisible: Bool {
        guard !state.queue.isEmpty, state.currentVideo != nil, playerContentHeight > 0 else { return false }
        // The layout's bottom padding follows transport/notices. Use content
        // coordinates from the ScrollView, rather than a transformed child's
        // frame inside the custom morph layout, to detect the full queue state.
        return panelScrollOffset >= max(Layout.queueMorphDistance, playerContentHeight - Layout.mediumSpacing) - 1
    }
    private var queueMorphProgress: CGFloat {
        guard !state.queue.isEmpty, state.currentVideo != nil else { return 0 }
        return min(1, max(0, panelScrollOffset / Layout.queueMorphDistance))
    }
    private var visibleLyricsProgress: CGFloat {
        lyricsPageProgress * (1 - queueMorphProgress)
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
    private var isPlayPauseDisabled: Bool {
        state.isPlayPauseDisabled || state.isControlsLocked
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
            .environment(\.colorScheme, visibleLyricsProgress > 0.5 ? .dark : colorScheme)
            .background(panelBackground.ignoresSafeArea())
            .foregroundStyle(controlPrimaryColor)
            .tint(nowPlayingAccent)
            .interactiveDismissDisabled(!isPanelAtTop || isPaging)
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
                if !available {
                    isPaging = false
                    selectPage(.artwork, animated: false)
                }
            }
            .onChange(of: state.isControlsLocked) { _, locked in
                if locked { cancelPaging() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { cancelPaging() }
            }
            .onChange(of: queueMorphProgress > 0) { _, openingQueue in
                if openingQueue { cancelPaging() }
            }
            .onChange(of: isStickyPlayerVisible) { _, visible in
                LoggingService.shared.debug(
                    "Player queue sticky header: \(visible), offset=\(panelScrollOffset), contentHeight=\(playerContentHeight)",
                    category: .player
                )
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
        resolvedColor(from: normalColor, to: lyricsColor, progress: visibleLyricsProgress)
    }

    private func resolvedColor(from normalColor: Color, to overlayColor: Color, progress: CGFloat) -> Color {
        // Resolve before the panel's forced dark scheme. This is inexpensive
        // color interpolation; artwork sampling stays in the image-loading task.
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let normalColor = Color(normalColor.resolve(in: environment))
        return normalColor.mix(with: overlayColor, by: Double(progress))
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

    private func cancelPaging() {
        isPaging = false
        selectPage(selectedPage)
    }

    // Only the content area accepts paging; the shared header, controls and queue keep their gestures.
    private func lyricsPageGesture(width: CGFloat) -> LyricsPageDragGesture {
        LyricsPageDragGesture(
            isEnabled: hasLyrics && queueMorphProgress == 0 && !state.isControlsLocked && scenePhase == .active,
            onChanged: { translation in
                guard hasLyrics, queueMorphProgress == 0, !state.isControlsLocked else { return }
                if !isPaging {
                    isPaging = true
                    LoggingService.shared.debug(
                        "Player paging began: \(selectedPage), translation: \(translation)", category: .player
                    )
                }
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
                cancelPaging()
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
                guard queueMorphProgress == 0, !state.isControlsLocked else { return }
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
                .opacity(Double(visibleLyricsProgress))
        }
        .environment(\.colorScheme, colorScheme)
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            let viewportHeight = max(0, geometry.size.height - Layout.headerHeight)
            // Keep enough room below the cover for transport and queue rows,
            // including in landscape and on wider presentations.
            let coverHeight = min(geometry.size.width, (geometry.size.height + geometry.safeAreaInsets.top) * 0.5)
            let coverHeaderProgress = queueMorphProgress * min(1, max(0,
                (Layout.queueMorphDistance + coverHeight - geometry.safeAreaInsets.top - panelScrollOffset) / Layout.headerHeight
            ))
            // Measure the final layout independently of the in-flight morph.
            // Its current height shrinks while the cover morphs.
            let detents = PlayerPanelScrollDetents(
                halfOpenOffset: Layout.queueMorphDistance,
                fullQueueOffset: max(Layout.queueMorphDistance, Layout.queueContentHeight(
                    coverHeight: coverHeight,
                    topSafeArea: geometry.safeAreaInsets.top,
                    noticesHeight: playbackNoticesHeight
                ) - Layout.mediumSpacing)
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    playerContent(viewportHeight: viewportHeight, coverHeight: coverHeight, topSafeArea: geometry.safeAreaInsets.top)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            playerContentHeight = $0
                        }

                    if !state.queue.isEmpty {
                        inlineQueue
                            .frame(maxWidth: 560)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, Layout.horizontalPadding)
                            .padding(.top, Layout.mediumSpacing)
                            .padding(.bottom, Layout.mediumSpacing)
                            // A short queue still needs enough scroll range to
                            // move all player controls behind the sticky header.
                            .frame(minHeight: viewportHeight, alignment: .top)
                    }
                }
            }
            .scrollIndicators(.hidden)
            // The morphing cover can draw behind the reserved header and status bar.
            .scrollClipDisabled(!state.queue.isEmpty && state.currentVideo != nil)
            .scrollBounceBehavior(.basedOnSize)
            .scrollPosition($scrollPosition)
            .scrollTargetBehavior(QueueTopScrollTargetBehavior(
                isEnabled: !state.queue.isEmpty && state.currentVideo != nil,
                detents: detents
            ))
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let offset = context.geometry.contentOffset.y + context.geometry.contentInsets.top
                if newPhase == .tracking || (newPhase == .interacting && oldPhase != .tracking) {
                    scrollGestureStartOffset = max(0, offset)
                }
                guard oldPhase == .interacting, newPhase == .decelerating || newPhase == .idle,
                      !state.queue.isEmpty, state.currentVideo != nil,
                      let target = detents.targetOffset(
                          startOffset: scrollGestureStartOffset,
                          releaseOffset: offset,
                          velocity: context.velocity?.dy ?? 0
                      ) else { return }

                LoggingService.shared.debug(
                    "Player panel snap: start=\(scrollGestureStartOffset), release=\(offset), velocity=\(context.velocity?.dy ?? 0), target=\(target)",
                    category: .player
                )
                // Replace panel deceleration with a spring immediately on
                // release. Queue-only gestures retain native scrolling.
                withAnimation(pageSnapAnimation) {
                    if target == 0 {
                        scrollPosition.scrollTo(edge: .top)
                    } else {
                        scrollPosition.scrollTo(y: target - context.geometry.contentInsets.top)
                    }
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                panelScrollOffset = offset
                isPanelAtTop = offset <= 1
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: Layout.headerHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .top) {
                // Keep the pinned card above the full-bleed artwork even when
                // scrolling is allowed to draw beyond the viewport's bounds.
                playerHeader(coverProgress: coverHeaderProgress)
            }
        }
    }

    private func playerContent(viewportHeight: CGFloat, coverHeight: CGFloat, topSafeArea: CGFloat) -> some View {
        PlayerContentLayout(
            progress: queueMorphProgress,
            viewportHeight: viewportHeight,
            coverHeight: coverHeight,
            topSafeArea: topSafeArea
        ) {
            pagedContent
            videoInfo
            VStack(spacing: 0) {
                lyricsPageIndicator
            }
            .opacity(Double(1 - queueMorphProgress))
            .allowsHitTesting(queueMorphProgress == 0)
            .accessibilityHidden(queueMorphProgress > 0)
            seekTrack
                .id(state.currentVideo?.id)
            seekTimeLabels
                .opacity(Double(1 - queueMorphProgress))
            transportControls
            VStack(alignment: .leading, spacing: 0) {
                playbackNotices
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                playbackNoticesHeight = $0
            }
        }
    }

    /// Measures the normal player independently of scroll progress. Interpolating
    /// its frames keeps the same views mounted without measuring a shrinking
    /// frame to determine the next scroll threshold.
    private struct PlayerContentLayout: SwiftUI.Layout, Sendable {
        let progress: CGFloat
        let viewportHeight: CGFloat
        let coverHeight: CGFloat
        let topSafeArea: CGFloat

        // Matches the seven children in playerContent.
        private enum Element: Int, CaseIterable, Sendable {
            case pages, info, indicators, seek, time, transport, notices
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.replacingUnspecifiedDimensions().width
            return frames(width: width, subviews: subviews).size
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let result = frames(width: bounds.width, subviews: subviews)
            for (index, subview) in subviews.enumerated() {
                let frame = result.frames[index]
                subview.place(
                    at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(frame.size)
                )
            }
        }

        private func frames(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
            let contentWidth = min(560, max(0, width - Layout.horizontalPadding * 2))
            let contentX = (width - contentWidth) / 2
            let proposal = ProposedViewSize(width: contentWidth, height: nil)
            var normal: [CGRect] = []
            var y = Layout.mediumSpacing

            for element in Element.allCases {
                switch element {
                case .info, .transport: y += Layout.mediumSpacing
                case .seek: y += Layout.smallSpacing
                default: break
                }
                let height = element == .pages ? contentWidth : subviews[element.rawValue].sizeThatFits(proposal).height
                normal.append(CGRect(x: contentX, y: y, width: contentWidth, height: height))
                y += height
            }

            let naturalHeight = y + Layout.mediumSpacing
            let normalHeight = max(viewportHeight, naturalHeight)
            let centeringInset = (normalHeight - naturalHeight) / 2
            normal = normal.map { $0.offsetBy(dx: 0, dy: centeringInset) }

            // At the end of the morph the cover begins at the physical top of
            // the screen. Further scrolling carries it away with the controls.
            let coverTop = Layout.queueMorphDistance - Layout.headerHeight - topSafeArea
            let coverBottom = coverTop + coverHeight
            var queue = normal
            queue[Element.pages.rawValue] = CGRect(x: 0, y: coverTop, width: width, height: coverHeight)
            queue[Element.info.rawValue].origin.y = coverBottom - Layout.mediumSpacing - normal[Element.info.rawValue].height
            queue[Element.indicators.rawValue].origin.y = coverBottom
            queue[Element.seek.rawValue].origin.y = coverBottom - Layout.seekHitHeight / 2
            queue[Element.time.rawValue].origin.y = coverBottom
            queue[Element.transport.rawValue].origin.y = coverBottom + Layout.smallSpacing
            queue[Element.notices.rawValue].origin.y = queue[Element.transport.rawValue].maxY
            let queueHeight = Layout.queueContentHeight(
                coverHeight: coverHeight,
                topSafeArea: topSafeArea,
                noticesHeight: normal[Element.notices.rawValue].height
            )

            let frames = zip(normal, queue).map { start, end in
                CGRect(
                    x: interpolate(start.minX, end.minX),
                    y: interpolate(start.minY, end.minY),
                    width: interpolate(start.width, end.width),
                    height: interpolate(start.height, end.height)
                )
            }
            return (CGSize(width: width, height: interpolate(normalHeight, queueHeight)), frames)
        }

        private func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
            start + (end - start) * progress
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
        // The layout proposes the artwork's square normally, then the full-bleed
        // cover's bounds. Both pages stay mounted with the same shared controls.
        Color.clear
            .overlay {
                GeometryReader { geometry in
                    let progress = visibleLyricsProgress
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
                                isActive: progress > 0,
                                isPaging: isPaging,
                                allowsManualScrolling: state.queue.isEmpty,
                                onSeek: seek
                            )
                            .environment(\.colorScheme, .dark)
                            .scaleEffect(reduceMotion ? 1 : 0.95 + 0.05 * progress)
                            .opacity(Double(progress))
                            .offset(x: reduceMotion ? 0 : geometry.size.width * (1 - progress))
                            .allowsHitTesting(showingLyrics && queueMorphProgress == 0)
                            .accessibilityHidden(!showingLyrics || queueMorphProgress > 0)
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

    private func playerHeader(coverProgress: CGFloat) -> some View {
        ZStack {
            topBar(overlayProgress: max(visibleLyricsProgress, coverProgress))
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
        .background {
            // Once the image has scrolled away, keep rows behind an opaque
            // header, just as they were with the ScrollView's original clipping.
            panelBackground
                .opacity(isStickyPlayerVisible ? 1 : Double(queueMorphProgress - coverProgress))
                .ignoresSafeArea(edges: .top)
        }
        .animation(.snappy, value: isStickyPlayerVisible)
    }

    private func topBar(overlayProgress: CGFloat) -> some View {
        let foreground = resolvedColor(from: .primary, to: .white, progress: overlayProgress)

        return HStack {
            Button(action: onClose) {
                topBarSymbol("chevron.down", foreground: foreground)
            }
            .buttonStyle(.plain)
            .topBarCircle(colorScheme: colorScheme, overlayProgress: Double(overlayProgress))
            .accessibilityLabel(String(localized: "player.nowPlaying.close"))

            Spacer()

            Button {
                showingPlayerMenu = true
            } label: {
                topBarSymbol("ellipsis", foreground: foreground)
            }
            .buttonStyle(.plain)
            .topBarCircle(colorScheme: colorScheme, overlayProgress: Double(overlayProgress))
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
                    playerMenu(for: video)
                }
            }
            .disabled(state.currentVideo == nil)
            .accessibilityLabel(String(localized: "controls.button.more"))
        }
        .tint(foreground)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Layout.horizontalPadding)
        .padding(.vertical, Layout.smallSpacing)
    }

    private func topBarSymbol(_ name: String, foreground: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34, alignment: .center)
            .contentShape(Circle())
    }

    private func playerMenu(for video: Video) -> some View {
        ViewThatFits(in: .vertical) {
            playerMenuItems(for: video)
                .fixedSize(horizontal: false, vertical: true)

            // Preserve access to every action in landscape or with larger text.
            ScrollView {
                playerMenuItems(for: video)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: MenuLayout.width)
        .presentationCompactAdaptation(.popover)
        // Give the entire popover, including its arrow, one consistent surface.
        .presentationBackground(.thickMaterial)
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
                    HStack(spacing: MenuLayout.iconSpacing) {
                        Image(systemName: "character.bubble")
                            .frame(width: MenuLayout.iconWidth)
                            .accessibilityHidden(true)
                        Text("Lyrics language")
                        Spacer(minLength: 0)
                        Text(lyrics.selectedTrack?.label ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                    }
                    .frame(maxWidth: .infinity, minHeight: MenuLayout.rowHeight, alignment: .leading)
                    .padding(.horizontal, MenuLayout.horizontalPadding)
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
        .font(.body.weight(.regular))
        .foregroundStyle(.primary)
        .buttonStyle(OnTheGoMenuButtonStyle())
        .tint(nowPlayingAccent)
        .padding(.vertical, 6)
    }

    private var autoplayMenuRow: some View {
        let title = String(localized: "player.nowPlaying.autoplay")

        return HStack(spacing: 0) {
            Button {
                appEnvironment?.settingsManager.queueAutoPlayNext.toggle()
            } label: {
                playerMenuRow(title, systemImage: "infinity")
            }
            .accessibilityHidden(true)

            Toggle(title, isOn: Binding(
                get: { isAutoPlayNextEnabled },
                set: { appEnvironment?.settingsManager.queueAutoPlayNext = $0 }
            ))
            .toggleStyle(.switch)
            .controlSize(.regular)
            .labelsHidden()
            .tint(nowPlayingAccent)
            .fixedSize()
            .padding(.trailing, MenuLayout.horizontalPadding)
        }
        .frame(minHeight: MenuLayout.rowHeight)
        .disabled(state.isControlsLocked || appEnvironment == nil)
    }

    private func playerMenuRow(_ title: String, systemImage: String) -> some View {
        HStack(spacing: MenuLayout.iconSpacing) {
            Image(systemName: systemImage)
                .frame(width: MenuLayout.iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: MenuLayout.rowHeight, alignment: .leading)
        .padding(.horizontal, MenuLayout.horizontalPadding)
        .contentShape(Rectangle())
    }

    private var playerMenuSeparator: some View {
        Divider()
            .padding(.leading, MenuLayout.horizontalPadding + MenuLayout.iconWidth + MenuLayout.iconSpacing)
            .padding(.trailing, MenuLayout.horizontalPadding)
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
                        if !isPlayPauseDisabled, !state.isPlayingIntended {
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
            .overlay {
                artworkImage(placeholderSize: 64)
            }
            .overlay {
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.25), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .black.opacity(0.15), location: 0.5),
                    .init(color: .black.opacity(0.9), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .opacity(Double(queueMorphProgress))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16 * (1 - queueMorphProgress)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .foregroundStyle(controlPrimaryColor.mix(with: .white, by: Double(queueMorphProgress)))
                    .id(video.id)

                Text(video.author.name)
                    .font(.subheadline)
                    .foregroundStyle(controlSecondaryColor.mix(with: .white.opacity(0.8), by: Double(queueMorphProgress)))
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Seeking

    private var seekTrack: some View {
        GeometryReader { geometry in
            let trackWidth = max(1, geometry.size.width)
            let progress = duration > 0 ? CGFloat(displayedTime / duration) : 0
            let coverTrackHeight = scrubTime == nil ? Layout.coverSeekTrackHeight : Layout.coverSeekScrubbingTrackHeight
            let trackHeight = Layout.seekTrackHeight + (coverTrackHeight - Layout.seekTrackHeight) * queueMorphProgress
            let trackColor = controlSecondaryColor.opacity(0.25)
                .mix(with: .white.opacity(0.45), by: Double(queueMorphProgress))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(nowPlayingAccent)
                    .frame(width: trackWidth * progress, height: trackHeight)
                Circle()
                    .fill(nowPlayingAccent)
                    .frame(width: 20, height: 20)
                    .scaleEffect(scrubTime == nil ? 1 : 1.2)
                    .animation(.easeOut(duration: 0.15), value: scrubTime != nil)
                    .opacity(Double(1 - queueMorphProgress))
                    .offset(x: min(max(0, trackWidth * progress - 10), trackWidth - 20))
            }
            // Keep the full drag target even when the track sits on the cover's edge.
            .frame(width: trackWidth, height: Layout.seekHitHeight)
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
        .frame(height: Layout.seekHitHeight)
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
    }

    private var seekTimeLabels: some View {
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

    private var transportControls: some View {
        // Only visible content takes layout space; the four spacers share the remainder.
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
            .buttonStyle(PlayPauseButtonStyle())
            .disabled(isPlayPauseDisabled)
            .opacity(isPlayPauseDisabled ? 0.4 : 1)
            .accessibilityLabel(state.isPlayingIntended ? String(localized: "player.controls.pause") : String(localized: "player.controls.play"))
            Spacer(minLength: 0)
            transportButton("goforward.10", label: String(localized: "menu.playback.seekForward \(10)"), disabled: isSeekDisabled) {
                playerService.seekForward(by: 10)
            }
            Spacer(minLength: 0)
            sleepTimerMenu
        }
        .frame(maxWidth: .infinity)
        .frame(height: Layout.transportHeight)
    }

    private var playPauseLabel: some View {
        playPauseSymbol
            .font(.system(size: 44, weight: .bold))
            .foregroundStyle(controlPrimaryColor)
            .fixedSize()
            .contentShape(OnTheGoTransportHitArea(minimumSize: 56))
    }

    private var playPauseSymbol: some View {
        PlayPauseSymbol(isPlaying: state.isPlayingIntended)
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
                set: { playerService.setPlaybackRate($0) }
            )) {
                ForEach(PlaybackRate.allCases) { rate in
                    Text(rate.displayText).tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            transportValue(playbackSpeedText, color: state.rate != .x1 ? nowPlayingAccent : controlPrimaryColor)
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
                transportValue(sleepTimerText, color: nowPlayingAccent)
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
            .fixedSize()
            .contentShape(OnTheGoTransportHitArea())
    }

    private func transportValue(_ value: String, color: Color) -> some View {
        Text(verbatim: value)
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .contentShape(OnTheGoTransportHitArea())
    }

    private func transportSymbol(_ name: String) -> some View {
        Image(systemName: name)
            .symbolVariant(.none)
            .font(.system(size: 32, weight: .regular))
            .foregroundStyle(controlPrimaryColor)
            .fixedSize()
            .contentShape(OnTheGoTransportHitArea())
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

// MARK: - Queue Scroll Boundary

private struct QueueTopScrollTargetBehavior: ScrollTargetBehavior, Sendable {
    let isEnabled: Bool
    let detents: PlayerPanelScrollDetents

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        // Returning through a long queue must stop at its top first. A new
        // downward gesture can then collapse the panel.
        guard isEnabled else { return }
        let offset = detents.queueTargetOffset(
            startOffset: context.originalTarget.rect.minY,
            proposedOffset: target.rect.minY
        )
        guard offset != target.rect.minY else { return }
        target.rect.origin.y = offset
        target.anchor = .top
    }
}

// MARK: - Paging Gesture Arbitration

@MainActor
private struct LyricsPageDragGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.isEnabled = isEnabled
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Disabling an active pan cancels it, including when lyrics disappear
        // or the app leaves the foreground during a drag.
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            // Project a short flick ahead, just as DragGesture's predicted end
            // translation did, while keeping tracking tied to the actual finger.
            onEnded(translation + recognizer.velocity(in: recognizer.view).x * 0.2)
        case .cancelled, .failed:
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
            // Require a predominantly horizontal start. UIKit keeps this
            // decision for the touch and resets it on end, failure or cancel.
            return abs(translation.x) > abs(translation.y) * 1.5
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Only competing pans need our direction decision. Taps and other
            // recognizers must not acquire a blanket failure dependency.
            otherGestureRecognizer is UIPanGestureRecognizer
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
            .background(configuration.isPressed && isEnabled ? Color.primary.opacity(0.08) : .clear)
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
    func topBarCircle(colorScheme: ColorScheme, overlayProgress: Double) -> some View {
        self
            .frame(width: 34, height: 34)
            .modifier(OnTheGoTopBarStyleModifier(colorScheme: colorScheme, overlayProgress: overlayProgress))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct OnTheGoTopBarStyleModifier: ViewModifier {
    let colorScheme: ColorScheme
    let overlayProgress: Double

    func body(content: Content) -> some View {
        // Crossfade only the decoration: there is still one interactive button.
        content.background {
            ZStack {
                circleBackground
                    .environment(\.colorScheme, colorScheme)
                    .opacity(1 - overlayProgress)
                circleBackground
                    .environment(\.colorScheme, .dark)
                    .opacity(overlayProgress)
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

/// Expands small labels to a minimum tap target without adding layout space.
private struct OnTheGoTransportHitArea: Shape, Sendable {
    var minimumSize: CGFloat = 44

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(
            dx: -max(0, (minimumSize - rect.width) / 2),
            dy: -max(0, (minimumSize - rect.height) / 2)
        ))
    }
}

private extension View {
    func transportMenuStyle() -> some View {
        self
            .menuStyle(.button)
            .buttonStyle(OnTheGoTransportButtonStyle())
            .menuIndicator(.hidden)
            .menuOrder(.fixed)
    }
}

private struct OnTheGoTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
