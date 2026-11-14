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
#if DEBUG
import OSLog
#endif

private let nowPlayingAccent = Color.red

#if DEBUG
private let panelDetentsLogger = Logger(subsystem: "stream.yattee.app", category: "PanelDetents")
#endif

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

    @State private var scrubTime: TimeInterval?
    /// Controls fade in when the player is presented in place by the resume
    /// sheet's swipe, whose morph already drew the artwork and title.
    @State private var chromeOpacity: Double?
    @State private var pendingSeekTime: TimeInterval?
    @State private var transportFeedbackTrigger = false
    @State private var showingPlayerMenu = false
    @State private var shareRequest = 0
    @State private var showingDetails = false
    @State private var showingComments = false
    @State private var showingCommentDetails = false
    @State private var showingDeleteDownloadConfirmation = false
    @State private var downloadToDelete: Download?
    @State private var detent = PanelDetent.normal
    @State private var dragOffset: CGFloat = 0
    @State private var panelDrag: PanelDrag?
    @GestureState private var isDraggingPanel = false
    @State private var queueScrollPosition = ScrollPosition(y: 0)
    @State private var isQueueAtTop = true
    @State private var isQueueScrolling = false
    @State private var queueDragStartedAtTop: Bool?
    @State private var queueTapSuppressedUntil = ContinuousClock.now
    @State private var panelCoverGeometry = PlayerPanelCoverGeometry(
        screenHeight: 0, topSafeArea: 0, headerHeight: Layout.headerHeight, noticesHeight: 0
    )
    @State private var playbackNoticesHeight: CGFloat = 0
    @State private var selectedPage = PlayerPage.artwork
    @State private var lyricsPageProgress: CGFloat = 0
    @State private var lyricsBottomInset: CGFloat = 0
    @State private var lyrics = LyricsViewModel()
    @State private var lyricsArtworkColor = LyricsArtworkColor.fallback
    @State private var isPaging = false
    @State private var queueTab = QueueTab.upNext

    /// Tabs above the pull-up list. Chapters only appears when the video has them.
    private enum QueueTab: Hashable, Sendable {
        case upNext
        case chapters
    }

    private enum PlayerPage: Hashable, Sendable {
        case artwork
        case lyrics
    }

    private enum Layout {
        static let horizontalPadding: CGFloat = 16
        static let smallSpacing: CGFloat = 8
        static let mediumSpacing: CGFloat = 16
        static let pageIndicatorSize: CGFloat = 6
        // Both headers occupy the same fixed space above the player or queue.
        static let headerHeight = CompactPlayerCard.height + smallSpacing * 2
        // Keeps the enlarged thumb inside the seek control at both endpoints.
        static let seekInset: CGFloat = 12
        static let seekTrackHeight: CGFloat = 6
        static let coverSeekTrackHeight: CGFloat = 5
        static let coverSeekScrubbingTrackHeight: CGFloat = 8
        static let coverSeekBottomInset: CGFloat = 16
        static let coverInfoSeekSpacing: CGFloat = 10
        static let seekHitHeight: CGFloat = 44
        static let transportHeight: CGFloat = 104
        static let queueTabsHeight: CGFloat = 32
        static let queueTabsBottomSpacing: CGFloat = 8

        static func contentWidth(for panelWidth: CGFloat) -> CGFloat {
            min(560, max(0, panelWidth - horizontalPadding * 2))
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
    private var showsQueueTabs: Bool { !state.chapters.isEmpty }
    private var visibleQueueTab: QueueTab { showsQueueTabs ? queueTab : .upNext }
    private var queueTabsInset: CGFloat {
        showsQueueTabs ? Layout.queueTabsHeight + Layout.queueTabsBottomSpacing : 0
    }
    private var hasLyrics: Bool {
        lyrics.videoID == state.currentVideo?.id.videoID && !lyrics.tracks.isEmpty
    }
    private var panelProgress: CGFloat {
        panelCoverGeometry.detents.progress(from: panelDrag?.start ?? detent, translation: dragOffset)
    }
    private var isStickyPlayerVisible: Bool { panelProgress >= 2 }
    private var isPanelDismissalAllowed: Bool {
        detent == .normal && (panelDrag?.start ?? detent) == .normal
    }
    private var queueMorphProgress: CGFloat { min(1, max(0, panelProgress)) }
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

    private var effectiveChromeOpacity: Double {
        chromeOpacity ?? (appEnvironment?.navigationCoordinator.playerChromeFadesIn == true ? 0 : 1)
    }

    var body: some View {
        panelContent
            .onAppear {
                guard let coordinator = appEnvironment?.navigationCoordinator,
                      coordinator.playerChromeFadesIn else { return }
                coordinator.playerChromeFadesIn = false
                chromeOpacity = 0
                withAnimation(.easeOut(duration: 0.3).delay(0.05)) { chromeOpacity = 1 }
            }
            // System presentations use the nearer page's scheme. Visible controls
            // resolve their original colors separately so this never flips them.
            .environment(\.colorScheme, visibleLyricsProgress > 0.5 ? .dark : colorScheme)
            .background(panelBackground.ignoresSafeArea())
            .foregroundStyle(controlPrimaryColor)
            .tint(nowPlayingAccent)
            .interactiveDismissDisabled(!isPanelDismissalAllowed || isPaging)
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
                scrubTime = nil
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
                if phase != .active {
                    scrubTime = nil
                    cancelPaging()
                    if let drag = panelDrag { settlePanel(at: drag.start) }
                }
            }
            .onChange(of: queueMorphProgress > 0) { _, openingQueue in
                if openingQueue { cancelPaging() }
            }
            .onChange(of: isDraggingPanel) { _, dragging in
                // GestureState also resets when the system cancels a gesture.
                if !dragging {
                    suppressQueueRowTaps()
                    if let drag = panelDrag {
                        settlePanel(at: drag.start)
                    }
                }
            }
            .onChange(of: detent) { _, target in
                if target != .fullQueue {
                    queueScrollPosition.scrollTo(y: 0)
                }
                if target != .normal {
                    showingDetails = false
                }
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
    private func lyricsPageGesture(width: CGFloat) -> PlayerHorizontalDragGesture {
        PlayerHorizontalDragGesture(
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

    /// Always laid out, and faded in once lyrics exist: inserting it later
    /// shifted the artwork and controls a few points after the player opened.
    private var lyricsPageIndicator: some View {
        Group {
            HStack(spacing: 6) {
                ForEach(0..<2) { page in
                    Circle()
                        .fill(controlPrimaryColor.opacity(page == 0
                            ? 0.85 - 0.6 * Double(lyricsPageProgress)
                            : 0.25 + 0.6 * Double(lyricsPageProgress)))
                        .frame(width: Layout.pageIndicatorSize, height: Layout.pageIndicatorSize)
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
        .opacity(hasLyrics ? 1 : 0)
        .allowsHitTesting(hasLyrics)
        .accessibilityHidden(!hasLyrics)
        .animation(.easeOut(duration: 0.25), value: hasLyrics)
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

    // MARK: - Panel Detents and Gesture Routing

    private enum PanelCoordinateSpace: Hashable, Sendable {
        case panel
    }

    private struct PanelDrag: Sendable {
        enum Route: Equatable, Sendable {
            case panel, queue, horizontal, dismissal
        }

        let start: PanelDetent
        let route: Route
    }

    private var panelSnapAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.88)
    }

    private func panelDragGesture(queueRowsTop: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .named(PanelCoordinateSpace.panel))
            .updating($isDraggingPanel) { _, dragging, _ in dragging = true }
            .onChanged { value in
                if panelDrag == nil {
                    suppressQueueRowTaps()
                    let translation = value.translation
                    let route: PanelDrag.Route
                    if abs(translation.height) <= abs(translation.width) || isPaging {
                        route = .horizontal
                    } else if detent == .fullQueue, value.startLocation.y >= queueRowsTop,
                              !(queueDragStartedAtTop ?? isQueueAtTop) || translation.height <= 0 {
                        // Lock list ownership for this entire touch. Reaching
                        // the top during a list drag requires a new pull to B.
                        route = .queue
                    } else if detent == .normal, translation.height > 0 {
                        // Keep dismissal from A separate from detent snapping.
                        route = .dismissal
                    } else {
                        route = .panel
                    }
                    panelDrag = PanelDrag(start: detent, route: route)
                }
                guard panelDrag?.route == .panel else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                suppressQueueRowTaps()
                guard let drag = panelDrag else { return }
                // Our pan can prevent the native zoom pan from beginning even
                // on the dismissal route. Fall back to the chevron's action.
                let shouldDismiss = drag.route == .dismissal && value.translation.height > 0 && (
                    value.translation.height > 120 || value.velocity.height > 800
                )
                let target = drag.route == .panel ? panelCoverGeometry.detents.target(
                    from: drag.start,
                    translation: value.translation.height,
                    predictedTranslation: value.predictedEndTranslation.height
                ) : drag.start
                #if DEBUG
                panelDetentsLogger.notice(
                    "Player panel gesture ended: start=\(String(describing: drag.start), privacy: .public), translation=\(value.translation.height), predicted=\(value.predictedEndTranslation.height), target=\(String(describing: target), privacy: .public), route=\(String(describing: drag.route), privacy: .public)"
                )
                #endif
                settlePanel(at: target)
                if drag.route == .dismissal {
                    LoggingService.shared.debug(
                        "Player dismissal drag ended: translation=\(value.translation.height), velocity=\(value.velocity.height), dismiss=\(shouldDismiss)",
                        category: .player
                    )
                }
                if shouldDismiss { onClose() }
            }
    }

    private func settlePanel(at target: PanelDetent) {
        #if DEBUG
        if target == .fullQueue {
            let layout = panelCoverGeometry.layout(progress: 2, normalPlayerHeight: 0)
            LoggingService.shared.debug(
                "Player full queue layout: cardBottom=\(Layout.headerHeight - Layout.smallSpacing), handleTop=\(layout.queueHandleTop), rowsTop=\(layout.queueRowsTop)",
                category: .player
            )
        }
        #endif
        withAnimation(panelSnapAnimation) {
            detent = target
            dragOffset = 0
            panelDrag = nil
        }
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            let coverGeometry = PlayerPanelCoverGeometry(
                screenHeight: geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom,
                topSafeArea: geometry.safeAreaInsets.top,
                headerHeight: Layout.headerHeight,
                noticesHeight: playbackNoticesHeight
            )
            let progress = coverGeometry.detents.progress(from: panelDrag?.start ?? detent, translation: dragOffset)
            let layout = coverGeometry.layout(progress: progress, normalPlayerHeight: 0)
            ZStack(alignment: .top) {
                playerContent(
                    panelSize: geometry.size, progress: progress, coverGeometry: coverGeometry
                )
                playerHeader(coverProgress: layout.coverHeaderProgress, queueProgress: layout.queueProgress)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .coordinateSpace(name: PanelCoordinateSpace.panel)
            // Keep paging/scrubbing simultaneous. Native dismissal stays enabled
            // in A, with a release fallback if our direction-locked pan wins.
            .simultaneousGesture(panelDragGesture(
                queueRowsTop: layout.queueRowsTop + queueTabsInset
            ))
            .onChange(of: coverGeometry, initial: true) { _, value in
                panelCoverGeometry = value
            }
        }
    }

    private func playerContent(
        panelSize: CGSize, progress: CGFloat, coverGeometry: PlayerPanelCoverGeometry
    ) -> some View {
        let layout = coverGeometry.layout(progress: progress, normalPlayerHeight: 0)
        let normalArtworkHeight = Layout.contentWidth(for: panelSize.width)
        let artworkHeight = normalArtworkHeight
            + (coverGeometry.coverHeight - normalArtworkHeight) * layout.morphProgress
        return PlayerContentLayout(
            progress: progress,
            panelHeight: panelSize.height,
            coverGeometry: coverGeometry
        ) {
            artworkPage(artworkHeight: artworkHeight)
                .allowsHitTesting(!isStickyPlayerVisible)
                .accessibilityHidden(isStickyPlayerVisible)
            lyricsPage(
                topInset: (Layout.headerHeight + coverGeometry.topSafeArea) * (1 - layout.morphProgress),
                bottomInset: lyricsBottomInset
            )
                .allowsHitTesting(showingLyrics && queueMorphProgress == 0)
                .accessibilityHidden(!showingLyrics || queueMorphProgress > 0)
            videoInfo
                .opacity(Double(1 - visibleLyricsProgress))
                // Details belongs to the player screen only, not the pulled-up queue.
                .allowsHitTesting(queueMorphProgress == 0 && visibleLyricsProgress < 0.5)
                .accessibilityHidden(isStickyPlayerVisible || visibleLyricsProgress >= 0.5)
            // Cover the entire dots/timeline region, including gaps and disabled
            // controls. The controls above this barrier retain their own gestures.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {}
                .allowsHitTesting(showingLyrics && queueMorphProgress == 0)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    lyricsBottomInset = $0
                }
            VStack(spacing: 0) {
                lyricsPageIndicator
            }
            .opacity(Double(1 - queueMorphProgress) * effectiveChromeOpacity)
            .allowsHitTesting(queueMorphProgress == 0)
            .accessibilityHidden(queueMorphProgress > 0)
            seekTrack
                .id(state.currentVideo?.id)
                .opacity(effectiveChromeOpacity)
                .allowsHitTesting(!isStickyPlayerVisible)
                .accessibilityHidden(isStickyPlayerVisible)
            seekTimeLabels
                .opacity(Double(1 - queueMorphProgress) * effectiveChromeOpacity)
                .accessibilityHidden(queueMorphProgress > 0)
            transportControls
                .opacity(effectiveChromeOpacity)
                .allowsHitTesting(!isStickyPlayerVisible)
                .accessibilityHidden(isStickyPlayerVisible)
            VStack(alignment: .leading, spacing: 0) {
                playbackNotices
            }
            .allowsHitTesting(!isStickyPlayerVisible)
            .accessibilityHidden(isStickyPlayerVisible)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                playbackNoticesHeight = $0
            }
            inlineQueue(handleBottomSpacing: layout.queueHandleBottomSpacing)
                .opacity(state.currentVideo != nil || !state.queue.isEmpty ? 1 : 0)
                .padding(.horizontal, Layout.horizontalPadding)
        }
    }

    /// Measures the normal player once per layout, then places the same player
    /// views and the independent queue viewport using continuous detent progress.
    private struct PlayerContentLayout: SwiftUI.Layout, Sendable {
        var progress: CGFloat
        let panelHeight: CGFloat
        let coverGeometry: PlayerPanelCoverGeometry

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        // The player children are followed by the queue viewport.
        private enum Element: Int, CaseIterable, Sendable {
            case artwork, lyrics, info, timelineBarrier, indicators, seek, time, transport, notices
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
            let contentWidth = Layout.contentWidth(for: width)
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
                let height: CGFloat
                switch element {
                case .artwork: height = contentWidth
                case .lyrics, .timelineBarrier: height = 0
                case .transport: height = Layout.transportHeight
                default: height = subviews[element.rawValue].sizeThatFits(proposal).height
                }
                normal.append(CGRect(x: contentX, y: y, width: contentWidth, height: height))
                y += height
            }

            let naturalHeight = y + Layout.mediumSpacing
            let normalHeight = max(panelHeight - Layout.headerHeight, naturalHeight)
            let centeringInset = (normalHeight - naturalHeight) / 2
            normal = normal.map { $0.offsetBy(dx: 0, dy: centeringInset) }

            // Keep all shared controls anchored to the square artwork layout.
            // Lyrics extend behind the header, dots and timeline, ending at the
            // transport row without changing any shared control frame.
            normal[Element.artwork.rawValue] = CGRect(
                x: contentX, y: 0, width: contentWidth, height: normal[Element.info.rawValue].minY
            )
            let lyricsTopInset = Layout.headerHeight + coverGeometry.topSafeArea
            let lyricsBottom = normal[Element.transport.rawValue].minY
            normal[Element.lyrics.rawValue] = CGRect(
                x: contentX, y: -lyricsTopInset, width: contentWidth,
                height: lyricsBottom + lyricsTopInset
            )
            // Measure the reclaimed region so the resting line stays anchored
            // above the dots even when the time labels' height changes.
            let timelineTop = normal[Element.indicators.rawValue].minY
            normal[Element.timelineBarrier.rawValue] = CGRect(
                x: contentX, y: timelineTop, width: contentWidth,
                height: lyricsBottom - timelineTop
            )

            let layout = coverGeometry.layout(progress: progress, normalPlayerHeight: normalHeight)
            // B's artwork starts at the physical top. B-to-C translates the
            // completed cover and controls away without resizing them.
            let coverBottom = coverGeometry.coverHeight
            var queue = normal
            queue[Element.artwork.rawValue] = CGRect(x: 0, y: 0, width: width, height: coverGeometry.coverHeight)
            queue[Element.lyrics.rawValue] = queue[Element.artwork.rawValue]
            queue[Element.timelineBarrier.rawValue] = CGRect(x: contentX, y: coverBottom, width: contentWidth, height: 0)
            // Anchor the visible track inside the gradient, then stack the
            // title/channel above it without changing the scrub target's size.
            let coverSeekCenterY = coverBottom - Layout.coverSeekBottomInset - Layout.coverSeekTrackHeight / 2
            queue[Element.info.rawValue].origin.y = coverSeekCenterY - Layout.coverSeekTrackHeight / 2
                - Layout.coverInfoSeekSpacing - normal[Element.info.rawValue].height
            queue[Element.indicators.rawValue].origin.y = coverBottom
            queue[Element.seek.rawValue].origin.y = coverSeekCenterY - Layout.seekHitHeight / 2
            queue[Element.time.rawValue].origin.y = coverBottom
            queue[Element.transport.rawValue].origin.y = coverGeometry.transportTop
            queue[Element.transport.rawValue].size.height = PlayerPanelCoverGeometry.transportHeight
            queue[Element.notices.rawValue].origin.y = queue[Element.transport.rawValue].maxY
            var frames = zip(normal, queue).map { start, end in
                CGRect(
                    x: interpolate(start.minX, end.minX, progress: layout.morphProgress),
                    y: layout.playerOriginY + interpolate(start.minY, end.minY, progress: layout.morphProgress),
                    width: interpolate(start.width, end.width, progress: layout.morphProgress),
                    height: interpolate(start.height, end.height, progress: layout.morphProgress)
                )
            }
            frames.append(CGRect(x: 0, y: layout.queueTop, width: width, height: max(0, panelHeight - layout.queueTop)))
            return (CGSize(width: width, height: panelHeight), frames)
        }

        private func interpolate(_ start: CGFloat, _ end: CGFloat, progress: CGFloat) -> CGFloat {
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

    private func artworkPage(artworkHeight: CGFloat) -> some View {
        pageViewport { size in
            let progress = visibleLyricsProgress
            artwork
                .frame(height: artworkHeight)
                .environment(\.colorScheme, colorScheme)
                .scaleEffect(reduceMotion ? 1 : 1 - 0.1 * progress)
                .opacity(Double(1 - progress))
                .offset(x: reduceMotion ? 0 : -size.width * progress)
                .padding(.bottom, Layout.mediumSpacing * (1 - queueMorphProgress))
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }

    private func lyricsPage(topInset: CGFloat, bottomInset: CGFloat) -> some View {
        pageViewport { size in
            if hasLyrics {
                let progress = visibleLyricsProgress
                LyricsView(
                    model: lyrics,
                    playerState: state,
                    isSeekDisabled: isSeekDisabled,
                    isActive: progress > 0,
                    isPaging: isPaging,
                    allowsManualScrolling: state.currentVideo == nil,
                    topInset: topInset,
                    bottomInset: bottomInset,
                    onSeek: seek
                )
                .environment(\.colorScheme, .dark)
                .scaleEffect(reduceMotion ? 1 : 0.95 + 0.05 * progress)
                .opacity(Double(progress))
                .offset(x: reduceMotion ? 0 : size.width * (1 - progress))
            }
        }
    }

    private func pageViewport<Content: View>(@ViewBuilder content: @escaping (CGSize) -> Content) -> some View {
        Color.clear
            .overlay {
                GeometryReader { geometry in
                    content(geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .contentShape(Rectangle())
                        .gesture(lyricsPageGesture(width: geometry.size.width))
                }
            }
            .clipped()
    }

    // MARK: - Top Bar

    private func playerHeader(coverProgress: CGFloat, queueProgress: CGFloat) -> some View {
        ZStack {
            topBar(overlayProgress: max(visibleLyricsProgress, coverProgress))
                .opacity(Double(1 - queueProgress) * effectiveChromeOpacity)
                .allowsHitTesting(!isStickyPlayerVisible)
                .accessibilityHidden(isStickyPlayerVisible)

            CompactPlayerCard(
                playerService: playerService,
                actionLabel: "player.nowPlaying.title",
                actionHint: "Returns to the player controls"
            ) {
                settlePanel(at: .normal)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Layout.horizontalPadding)
            .opacity(Double(queueProgress))
            .offset(y: -16 * (1 - queueProgress))
            .allowsHitTesting(isStickyPlayerVisible)
            .accessibilityHidden(!isStickyPlayerVisible)
        }
        .frame(height: CompactPlayerCard.height)
        .padding(.vertical, Layout.smallSpacing)
        .background {
            panelBackground
                .opacity(Double(max(queueProgress, queueMorphProgress - coverProgress)))
                .ignoresSafeArea(edges: .top)
        }
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

            lyricsHeaderInfo
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .clipped()
                .opacity(Double(visibleLyricsProgress))
                .allowsHitTesting(visibleLyricsProgress >= 0.5)
                .accessibilityHidden(visibleLyricsProgress < 0.5)

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

    private var lyricsHeaderInfo: some View {
        Button {
            showingDetails = true
        } label: {
            VStack(spacing: 2) {
                Text(videoTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(controlPrimaryColor)

                Text(state.currentVideo?.author.name ?? "")
                    .font(.caption)
                    .foregroundStyle(controlSecondaryColor)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.currentVideo == nil)
        .accessibilityLabel(videoTitle)
        .accessibilityHint("Shows details")
    }

    private func topBarSymbol(_ name: String, foreground: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(foreground)
            .frame(width: 44, height: 44, alignment: .center)
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

            audioTrackMenuRow

            if showsQueueTabs {
                Button {
                    dismissPlayerMenu {
                        queueTab = .chapters
                        settlePanel(at: .fullQueue)
                    }
                } label: {
                    playerMenuRow(String(localized: "Chapters"), systemImage: "list.bullet.rectangle")
                }
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

    /// Voice picker (original / dubbed / AI dub). Shown only when the video has 2+ voices.
    @ViewBuilder
    private var audioTrackMenuRow: some View {
        let options = playerService.audioTrackOptions
        if options.count > 1 {
            let current = options.first { $0.matches(state.currentStream) }
            Menu {
                Picker("Audio", selection: Binding(
                    get: { current?.id },
                    set: { id in
                        guard let option = options.first(where: { $0.id == id }) else { return }
                        dismissPlayerMenu {
                            Task { await playerService.switchAudioTrack(to: option) }
                        }
                    }
                )) {
                    ForEach(options) { option in
                        Text(option.label).tag(Optional(option.id))
                    }
                }
            } label: {
                HStack(spacing: MenuLayout.iconSpacing) {
                    Image(systemName: "waveform")
                        .frame(width: MenuLayout.iconWidth)
                        .accessibilityHidden(true)
                    Text("Audio")
                    Spacer(minLength: 0)
                    Text(current?.languageName ?? "")
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
            .disabled(state.isControlsLocked)
            .accessibilityLabel("Audio")
            .accessibilityValue(current?.label ?? "")
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

    private func suppressQueueRowTaps() {
        // A simultaneous pan can finish before a moving row's Button fires.
        // Keep its release suppressed even after the drag state has reset.
        queueTapSuppressedUntil = ContinuousClock.now.advanced(by: .milliseconds(250))
    }

    private func canActivateQueueRow() -> Bool {
        guard !isDraggingPanel, panelDrag == nil, !isQueueScrolling,
              ContinuousClock.now >= queueTapSuppressedUntil else {
            LoggingService.shared.debug(
                "Ignored queue row tap during or just after a player/queue drag",
                category: .player
            )
            return false
        }
        return true
    }

    private func inlineQueue(handleBottomSpacing: CGFloat) -> some View {
        VStack(spacing: 0) {
            // The grabber is outside the rows' ScrollView so it can always
            // collapse C, including while the rows are scrolled down.
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: PlayerPanelCoverGeometry.queueHandleHeight)
                .frame(maxWidth: .infinity)
                .padding(.top, PlayerPanelCoverGeometry.queueHandleTopSpacing)
                .padding(.bottom, handleBottomSpacing)
                .contentShape(Rectangle())
                .accessibilityLabel("Player queue handle")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: settlePanel(at: .fullQueue)
                    case .decrement: settlePanel(at: detent == .fullQueue ? .halfOpen : .normal)
                    @unknown default: break
                    }
                }

            if showsQueueTabs {
                Picker("List", selection: $queueTab) {
                    Text("Up Next").tag(QueueTab.upNext)
                    Text("Chapters").tag(QueueTab.chapters)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560, minHeight: Layout.queueTabsHeight, maxHeight: Layout.queueTabsHeight)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Layout.queueTabsBottomSpacing)
            }

            ScrollView {
                Group {
                    if visibleQueueTab == .chapters {
                        inlineChapterItems
                    } else {
                        inlineQueueItems
                    }
                }
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
                .padding(.bottom, Layout.mediumSpacing)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(detent != .fullQueue || panelDrag?.route == .panel)
            .scrollPosition($queueScrollPosition)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y <= 0 } action: { _, atTop in
                isQueueAtTop = atTop
            }
            .onScrollPhaseChange { oldPhase, phase, context in
                isQueueScrolling = phase.isScrolling
                if oldPhase.isScrolling || phase.isScrolling {
                    suppressQueueRowTaps()
                }
                if phase == .tracking {
                    queueDragStartedAtTop = context.geometry.contentOffset.y <= 0
                } else if phase == .idle {
                    queueDragStartedAtTop = nil
                }
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onChange(of: visibleQueueTab) { _, tab in
            // Pin the chapter before the playing one to the top so the playing
            // chapter is always fully visible, whatever the viewport height is
            // mid-animation (a .center anchor computed while the panel is still
            // growing leaves it half hidden under the tabs).
            let chapters = state.chapters
            if tab == .chapters,
               let activeIndex = chapters.firstIndex(where: { $0.id == state.activeChapterID }),
               activeIndex > 0 {
                queueScrollPosition.scrollTo(id: chapters[activeIndex - 1].id, anchor: .top)
            } else {
                queueScrollPosition.scrollTo(edge: .top)
            }
        }
    }

    private var inlineChapterItems: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(state.chapters.enumerated()), id: \.element.id) { index, chapter in
                ChapterRow(
                    chapter: chapter,
                    index: index,
                    isActive: chapter.id == state.activeChapterID,
                    isPlaying: state.playbackState == .playing,
                    onTap: {
                        guard canActivateQueueRow() else { return }
                        seek(to: chapter.startTime)
                    }
                )
                .id(chapter.id)
            }
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
                        guard canActivateQueueRow() else { return }
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
                        guard canActivateQueueRow() else { return }
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
                        Text(video.title)
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)

                        Button {
                            onClose()
                            appEnvironment?.navigationCoordinator.navigateToChannel(for: video, collapsePlayer: true)
                        } label: {
                            HStack {
                                Text(video.author.name)
                                Spacer()
                                Image(systemName: "chevron.forward")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)

                        Text(DescriptionText.attributed(video.description ?? "", linkColor: .red))
                            .handleTimestampLinks(using: playerService)
                            .textSelection(.enabled)
                    }
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel(String(localized: "common.close"))
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
            // Keep the full drag target around the thin visible track.
            .frame(width: trackWidth, height: Layout.seekHitHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                PlayerHorizontalDragGesture(
                    isEnabled: !isSeekDisabled && scenePhase == .active,
                    coordinate: .location,
                    onChanged: { position in
                        if scrubTime == nil {
                            LoggingService.shared.debug("Player seek: horizontal drag began", category: .player)
                        }
                        scrubTime = seekTime(at: position, trackWidth: trackWidth)
                    },
                    onEnded: { position in
                        scrubTime = nil
                        seek(to: seekTime(at: position, trackWidth: trackWidth))
                    },
                    onCancelled: { scrubTime = nil }
                )
            )
            .simultaneousGesture(
                SpatialTapGesture()
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
        .frame(height: Layout.transportHeight + (PlayerPanelCoverGeometry.transportHeight - Layout.transportHeight) * queueMorphProgress)
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

// MARK: - Horizontal Gesture Arbitration

@MainActor
private struct PlayerHorizontalDragGesture: UIGestureRecognizerRepresentable {
    enum Coordinate: Sendable {
        case projectedTranslation
        case location
    }

    let isEnabled: Bool
    var coordinate: Coordinate = .projectedTranslation
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
        // Disabling an active pan cancels paging/scrubbing, including when
        // controls become unavailable or the app leaves the foreground.
        if recognizer.isEnabled != isEnabled {
            recognizer.isEnabled = isEnabled
        }
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view).x
        let location = recognizer.location(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(coordinate == .location ? location : translation)
        case .ended:
            // Project a short flick ahead, just as DragGesture's predicted end
            // translation did, while keeping tracking tied to the actual finger.
            onEnded(coordinate == .location ? location : translation + recognizer.velocity(in: recognizer.view).x * 0.2)
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
            .frame(width: 44, height: 44)
            .modifier(OnTheGoTopBarStyleModifier(colorScheme: colorScheme, overlayProgress: overlayProgress))
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
