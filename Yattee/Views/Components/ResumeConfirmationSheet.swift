//
//  ResumeConfirmationSheet.swift
//  Yattee
//
//  Fitting-height bottom sheet for resuming a partially watched video.
//

import Foundation
import SwiftUI

private struct ResumeConfirmationItem: Identifiable, Sendable {
    let video: Video
    let resumeTime: TimeInterval

    var id: VideoID { video.id }
}

// MARK: - Presentation

private struct ResumeConfirmationSheetModifier: ViewModifier {
    let video: Video?
    @Binding var resumeTime: TimeInterval?
    let onContinue: (TimeInterval) -> Void
    let onStartOver: () -> Void

    @Environment(\.appEnvironment) private var appEnvironment
    @State private var pendingAction: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .sheet(item: presentedResume, onDismiss: performPendingAction) { item in
                ResumeConfirmationSheet(
                    video: item.video,
                    resumeTime: item.resumeTime,
                    onContinue: {
                        dismissThen { onContinue(item.resumeTime) }
                    },
                    onSwipeToPlay: {
                        dismissImmediatelyThen { onContinue(item.resumeTime) }
                    },
                    onStartOver: {
                        dismissThen(onStartOver)
                    }
                )
            }
            .dismissesOnExternalNavigation(isPresented)
    }

    private var presentedResume: Binding<ResumeConfirmationItem?> {
        Binding(
            get: {
                guard let video, let resumeTime else { return nil }
                return ResumeConfirmationItem(video: video, resumeTime: resumeTime)
            },
            set: { resumeTime = $0?.resumeTime }
        )
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { resumeTime != nil },
            set: { presented in
                if !presented {
                    resumeTime = nil
                }
            }
        )
    }

    private func dismissThen(_ action: @escaping () -> Void) {
        pendingAction = action
        resumeTime = nil
    }

    /// Removes the sheet without its slide-down, so the player's own opening
    /// animation is the only motion after a swipe up — no sheet going down
    /// while the player comes up.
    private func dismissImmediatelyThen(_ action: @escaping () -> Void) {
        // The sheet has already morphed into the player's layout, so the
        // player appears in place instead of zooming in.
        let coordinator = appEnvironment?.navigationCoordinator
        pendingAction = {
            coordinator?.skipNextPlayerExpandAnimation = true
            action()
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            resumeTime = nil
        }
    }

    private func performPendingAction() {
        // Swipe and external-navigation dismissals have no pending playback action.
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

// MARK: - Sheet Content

/// The resume choices, and a swipe-to-play gesture: dragging the sheet up
/// morphs its header into the expanded player's artwork and title, following
/// the finger, and reaching the top hands off to the real player.
private struct ResumeConfirmationSheet: View {
    let video: Video
    let resumeTime: TimeInterval
    let onContinue: () -> Void
    let onSwipeToPlay: () -> Void
    let onStartOver: () -> Void

    @State private var fittingHeight: CGFloat = 260
    @State private var selectedDetent: PresentationDetent = .height(260)
    /// The sheet's leading edge in screen space; a large sheet is inset.
    @State private var sheetLeft: CGFloat = 0
    @State private var didHandOff = false
    @State private var handOffTask: Task<Void, Never>?
    /// The morph as drawn: follows `progress` under the finger, and is
    /// animated to the end when the sheet snaps up. The snap lays the content
    /// out at its final size at once, so `progress` alone would jump there.
    @State private var morphT: CGFloat = 0
    /// Where the large sheet's top really stops, once seen.
    @State private var measuredLargeTop: CGFloat?

    // MARK: Geometry

    private enum Metrics {
        static let thumbWidth: CGFloat = 96
        static let thumbHeight: CGFloat = 54
        static let headerTop: CGFloat = 32
        static let headerBottom: CGFloat = 20
        static let side: CGFloat = 20
        static let gap: CGFloat = 12
    }

    /// A little below where the large sheet's top stops, so the morph is
    /// complete before the snap ends and holds its (screen-space) targets.
    private var largeTop: CGFloat { safeAreaTop + 24 }

    /// The sheet's live height, and the smallest it has been — its resting
    /// size. Sliding in or being dragged down moves the sheet without
    /// changing its height, so only a drag up counts as progress.
    @State private var sheetHeight: CGFloat = 0
    @State private var restingHeight: CGFloat?

    /// 0 at the resting height, 1 at the top.
    private var progress: CGFloat {
        guard let restingHeight else { return 0 }
        let largeHeight = keyWindow.bounds.height - largeTop
        guard largeHeight > restingHeight + 1 else { return 0 }
        return min(1, max(0, (sheetHeight - restingHeight) / (largeHeight - restingHeight)))
    }

    private var keyWindow: UIWindow {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? UIWindow()
    }

    private var safeAreaTop: CGFloat { keyWindow.safeAreaInsets.top }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: Metrics.headerTop + Metrics.thumbHeight + Metrics.headerBottom)
                    actions
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height.rounded(.up)
                } action: { _, height in
                    fittingHeight = height
                    if selectedDetent != .large { selectedDetent = .height(height) }
                }
                .opacity(Double(max(0, 1 - morphT * 2.5)))

                ResumeMorphHeader(
                    video: video,
                    t: morphT,
                    width: width,
                    // Targets are in screen space, measured from where the
                    // sheet's top ends up, so the content rides the sheet.
                    sheetFinalTop: measuredLargeTop ?? safeAreaTop + 10,
                    sheetLeft: sheetLeft,
                    safeAreaTop: safeAreaTop,
                    screenWidth: keyWindow.bounds.width
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { _, frame in
            sheetLeft = frame.minX
            sheetHeight = frame.height
            if frame.height > 0, frame.height < (restingHeight ?? .infinity) {
                restingHeight = frame.height
            }
            if selectedDetent == .large {
                measuredLargeTop = frame.minY
            } else {
                morphT = progress
            }
        }
        .presentationDetents([.height(fittingHeight), .large], selection: $selectedDetent)
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        // Drawn by the content rather than `presentationBackground`, which
        // lags behind a drag: the color moves with the finger from the first
        // point, reaching the player's background before the top.
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                // The player's base-level background: inside a sheet
                // `.systemBackground` resolves to the elevated gray instead.
                Color(uiColor: UIColor { traits in
                    UIColor.systemBackground.resolvedColor(
                        with: traits.modifyingTraits { $0.userInterfaceLevel = .base }
                    )
                })
                .opacity(Double(morphT))
            }
            .ignoresSafeArea()
        }
        .presentationBackground(.clear)
        .onChange(of: selectedDetent) { _, detent in
            guard detent == .large else {
                withAnimation(.smooth(duration: 0.35)) { morphT = 0 }
                return
            }
            // Finish the morph alongside the system's snap, then hand off.
            withAnimation(.smooth(duration: Self.snapDuration)) { morphT = 1 }
            scheduleHandOff()
        }
        .accessibilityAction(named: Text(String(localized: "resume.action.continueAt \(resumeTime.formattedAsTimestamp)"))) {
            onContinue()
        }
    }

    /// Roughly the system's detent snap.
    private static let snapDuration: TimeInterval = 0.4

    /// Hands off once the morph has finished alongside the snap.
    private func scheduleHandOff() {
        handOffTask?.cancel()
        guard !didHandOff else { return }
        handOffTask = Task {
            try? await Task.sleep(for: .seconds(Self.snapDuration + 0.05))
            guard !Task.isCancelled else { return }
            handOff()
        }
    }

    private func handOff() {
        guard !didHandOff, selectedDetent == .large else { return }
        didHandOff = true
        onSwipeToPlay()
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: 0) {
            Divider()

            actionRow(
                String(localized: "resume.action.continueAt \(resumeTime.formattedAsTimestamp)"),
                systemImage: "play.fill",
                action: onContinue
            )

            Divider()
                .padding(.leading, 56)

            actionRow(
                String(localized: "resume.action.startFromBeginning"),
                systemImage: "arrow.counterclockwise",
                action: onStartOver
            )
        }
        .padding(.bottom, 24)
    }

    private func actionRow(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Morphing Header

/// The video header, interpolated from its place in the sheet to the expanded
/// player's artwork and title. `Animatable`, so an animated `t` lays it out
/// afresh every frame — fonts and frames included.
private struct ResumeMorphHeader: View, Animatable {
    let video: Video
    var t: CGFloat
    let width: CGFloat
    let sheetFinalTop: CGFloat
    let sheetLeft: CGFloat
    let safeAreaTop: CGFloat
    let screenWidth: CGFloat

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    private enum Metrics {
        static let thumbWidth: CGFloat = 96
        static let thumbHeight: CGFloat = 54
        static let headerTop: CGFloat = 32
        static let side: CGFloat = 20
        static let gap: CGFloat = 12
        /// The expanded player's layout, relative to the safe area top.
        static let playerSide: CGFloat = 16
        static let playerArtworkTop: CGFloat = 96
        static let playerTitleGap: CGFloat = 16
        static let playerAuthorGap: CGFloat = 34
    }

    var body: some View {
        let offsetY = -sheetFinalTop
        let offsetX = -sheetLeft
        let artSide = screenWidth - Metrics.playerSide * 2
        let artTop = safeAreaTop + Metrics.playerArtworkTop + offsetY
        let titleGap = Metrics.playerTitleGap

        let thumbX = lerp(Metrics.side, Metrics.playerSide + offsetX, t)
        let thumbY = lerp(Metrics.headerTop, artTop, t)
        let thumbW = lerp(Metrics.thumbWidth, artSide, t)
        let thumbH = lerp(Metrics.thumbHeight, artSide, t)

        let textStartX = Metrics.side + Metrics.thumbWidth + Metrics.gap
        let textX = lerp(textStartX, Metrics.playerSide + offsetX, t)
        let textW = lerp(width - textStartX - Metrics.side, artSide, t)
        // The artwork widens over the title's column early, so the title
        // drops below it within the first quarter, then rides under it.
        let titleY = lerp(Metrics.headerTop + 2, thumbY + thumbH + titleGap, min(1, t * 4))
        let authorY = titleY + lerp(36, Metrics.playerAuthorGap, t)

        ZStack(alignment: .topLeading) {
            // A fixed box with the image filling it: the thumbnail view keeps
            // its own aspect ratio and would otherwise overflow the frame.
            Color.clear
                .frame(width: thumbW, height: thumbH)
                .overlay {
                    VideoThumbnailView(
                        url: video.bestThumbnail?.url,
                        fallbackURLs: video.thumbnailURLsByQuality
                    )
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: max(thumbW, thumbH * 16 / 9), height: max(thumbH, thumbW * 9 / 16))
                }
                .clipShape(RoundedRectangle(cornerRadius: lerp(6, 14, t), style: .continuous))
                .offset(x: thumbX, y: thumbY)
                .accessibilityHidden(true)

            Text(verbatim: video.title)
                .font(.system(size: lerp(15, 20, t), weight: t > 0.5 ? .bold : .medium))
                .lineLimit(t > 0.5 ? 1 : 2)
                .frame(width: textW, alignment: .leading)
                .offset(x: textX, y: titleY)

            Text(verbatim: video.author.name)
                .font(.system(size: lerp(12, 15, t)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: textW, alignment: .leading)
                .offset(x: textX, y: authorY)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }
}

// MARK: - View Extension

extension View {
    /// Offers native resume choices, using the timestamp captured when playback was requested.
    func resumeConfirmationSheet(
        video: Video?,
        resumeTime: Binding<TimeInterval?>,
        onContinue: @escaping (TimeInterval) -> Void,
        onStartOver: @escaping () -> Void
    ) -> some View {
        modifier(ResumeConfirmationSheetModifier(
            video: video,
            resumeTime: resumeTime,
            onContinue: onContinue,
            onStartOver: onStartOver
        ))
    }
}
