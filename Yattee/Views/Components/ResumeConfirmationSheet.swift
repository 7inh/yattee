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
    /// The sheet's top edge in screen space, live while it is dragged.
    @State private var sheetTop: CGFloat = 0
    /// The sheet's leading edge in screen space; a large sheet is inset.
    @State private var sheetLeft: CGFloat = 0
    @State private var didHandOff = false
    @State private var handOffTask: Task<Void, Never>?

    // MARK: Geometry

    private enum Metrics {
        static let thumbWidth: CGFloat = 96
        static let thumbHeight: CGFloat = 54
        static let headerTop: CGFloat = 32
        static let headerBottom: CGFloat = 20
        static let side: CGFloat = 20
        static let gap: CGFloat = 12
        /// The expanded player's layout, relative to the safe area top.
        static let playerSide: CGFloat = 16
        static let playerArtworkTop: CGFloat = 97
        static let playerTitleGap: CGFloat = 34
        static let playerAuthorGap: CGFloat = 34
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
                .opacity(Double(max(0, 1 - progress * 2.5)))

                morphingHeader(width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { _, frame in
            sheetTop = frame.minY
            sheetLeft = frame.minX
            sheetHeight = frame.height
            if frame.height > 0, frame.height < (restingHeight ?? .infinity) {
                restingHeight = frame.height
            }
            scheduleHandOffWhenSettled()
        }
        .presentationDetents([.height(fittingHeight), .large], selection: $selectedDetent)
        .presentationContentInteraction(.resizes)
        .presentationDragIndicator(.visible)
        .presentationBackground {
            ZStack {
                Rectangle().fill(.regularMaterial)
                // Reaches the player's background by the time the morph ends.
            Color(uiColor: .systemBackground).opacity(Double(min(1, progress * 1.2)))
            }
        }
        .onChange(of: selectedDetent) { _, _ in
            scheduleHandOffWhenSettled()
        }
        .accessibilityAction(named: Text(String(localized: "resume.action.continueAt \(resumeTime.formattedAsTimestamp)"))) {
            onContinue()
        }
    }

    /// Hands off once the sheet has snapped to the top and stopped moving:
    /// every frame of the snap pushes the hand-off back a little.
    private func scheduleHandOffWhenSettled() {
        handOffTask?.cancel()
        guard selectedDetent == .large, !didHandOff else { return }
        handOffTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            handOff()
        }
    }

    private func handOff() {
        guard !didHandOff, selectedDetent == .large else { return }
        didHandOff = true
        onSwipeToPlay()
    }

    // MARK: Morphing Header

    private func morphingHeader(width: CGFloat) -> some View {
        let t = progress
        // Targets are in screen space; convert to the sheet's current frame.
        let offsetY = -sheetTop
        let offsetX = -sheetLeft
        let screenWidth = keyWindow.bounds.width
        let artSide = screenWidth - Metrics.playerSide * 2
        let artTop = safeAreaTop + Metrics.playerArtworkTop + offsetY
        let titleTop = artTop + artSide + Metrics.playerTitleGap
        let authorTop = titleTop + Metrics.playerAuthorGap

        let thumbX = lerp(Metrics.side, Metrics.playerSide + offsetX, t)
        let thumbY = lerp(Metrics.headerTop, artTop, t)
        let thumbW = lerp(Metrics.thumbWidth, artSide, t)
        let thumbH = lerp(Metrics.thumbHeight, artSide, t)

        let textStartX = Metrics.side + Metrics.thumbWidth + Metrics.gap
        let textX = lerp(textStartX, Metrics.playerSide + offsetX, t)
        let textW = lerp(width - textStartX - Metrics.side, artSide, t)
        let titleY = lerp(Metrics.headerTop + 2, titleTop, t)
        let titleLines = t > 0.5 ? 1 : 2
        let authorY = t > 0.5 ? lerp(Metrics.headerTop + 38, authorTop, t) : Metrics.headerTop + 38

        return ZStack(alignment: .topLeading) {
            VideoThumbnailView(
                url: video.bestThumbnail?.url,
                fallbackURLs: video.thumbnailURLsByQuality
            )
            .aspectRatio(contentMode: .fill)
            .frame(width: thumbW, height: thumbH)
            .clipShape(RoundedRectangle(cornerRadius: lerp(6, 14, t), style: .continuous))
            .offset(x: thumbX, y: thumbY)
            .accessibilityHidden(true)

            Text(verbatim: video.title)
                .font(.system(size: lerp(15, 22, t), weight: t > 0.5 ? .semibold : .medium))
                .lineLimit(titleLines)
                .frame(width: textW, alignment: .leading)
                .offset(x: textX, y: titleY)

            Text(verbatim: video.author.name)
                .font(.system(size: lerp(12, 17, t)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: textW, alignment: .leading)
                .offset(x: textX, y: authorY)
                .opacity(t > 0.3 && t < 0.5 ? 0 : 1)
        }
        .accessibilityElement(children: .combine)
        .allowsHitTesting(false)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
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
