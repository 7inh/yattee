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

    private func performPendingAction() {
        // Swipe and external-navigation dismissals have no pending playback action.
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

// MARK: - Sheet Content

private struct ResumeConfirmationSheet: View {
    let video: Video
    let resumeTime: TimeInterval
    let onContinue: () -> Void
    let onStartOver: () -> Void

    @State private var fittingHeight: CGFloat = 260

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                videoHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 20)

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
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height.rounded(.up)
            } action: { _, height in
                fittingHeight = height
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(fittingHeight)])
        .presentationDragIndicator(.visible)
    }

    private var videoHeader: some View {
        HStack(spacing: 12) {
            VideoThumbnailView(
                url: video.bestThumbnail?.url,
                fallbackURLs: video.thumbnailURLsByQuality
            )
            .frame(width: 96, height: 54)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: video.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Text(verbatim: video.author.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
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
