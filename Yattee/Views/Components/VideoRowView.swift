//
//  VideoRowView.swift
//  Yattee
//
//  A video row for list layouts.
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A video row for list layouts.
///
/// Automatically handles DeArrow integration for titles and thumbnails.
/// Download status is automatically shown from the download manager.
/// On iOS/macOS, supports configurable tap zones for thumbnail and text area.
struct VideoRowView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.videoQueueContext) private var videoQueueContext

    let video: Video
    var style: VideoRowStyle = .regular
    var watchProgress: Double? = nil
    var showSourceBadge: Bool = false
    /// Custom metadata text to show instead of views/date (e.g., remaining time).
    var customMetadata: String? = nil
    /// Optional index number to display before thumbnail (for playlists).
    var index: Int? = nil
    /// When true, disables internal tap handling so parent view can handle all taps.
    var disableInternalTapHandling: Bool = false
    /// When false, hides the thumbnail (e.g. details panel related page setting).
    var showThumbnail: Bool = true

    /// Indexed rows are playlist rows; other platforms retain their usual layout.
    private var usesCompactPlaylistLayout: Bool {
        index != nil
    }

    // Platform-specific fonts
    private var titleFont: Font {
        .subheadline
    }
    private var authorFont: Font {
        style == .compact ? .caption2 : .caption
    }
    private var metadataFont: Font {
        style == .compact ? .caption2 : .caption2
    }

    private var usesPhoneLayout: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var thumbnailTapAction: VideoTapAction {
        .playVideo
    }

    private var textAreaTapAction: VideoTapAction {
        .playVideo
    }

    private var accessibilityLabelText: String {
        var parts = [video.displayTitle(using: appEnvironment?.deArrowBrandingProvider), video.author.name]
        let duration = video.formattedDuration
        if !duration.isEmpty {
            parts.append(duration)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: usesCompactPlaylistLayout ? 8 : 12) {
            // Index number (for playlists)
            if let index {
                Text("\(index)")
                    .font(usesCompactPlaylistLayout ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: usesCompactPlaylistLayout ? 20 : 32)
            }

            // Thumbnail
            if showThumbnail {
                thumbnailView
                    .zoomTransitionSource(id: video.id)
            }

            // Info
            infoView
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("video.row.\(video.id.videoID)")
        .accessibilityLabel(accessibilityLabelText)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        DeArrowVideoThumbnail(
            video: video,
            cornerRadius: style == .compact ? 4 : style == .regular ? 6 : 8,
            watchProgress: watchProgress,
            duration: style == .compact ? nil : video.formattedDuration
        )
        .frame(
            width: style.thumbnailWidth,
            height: usesCompactPlaylistLayout ? style.thumbnailWidth * 9 / 16 : style.thumbnailHeight
        )
        .contentShape(Rectangle())
        .if(thumbnailTapAction != .playVideo && !disableInternalTapHandling) { view in
            view.highPriorityGesture(
                TapGesture().onEnded {
                    handleTapAction(thumbnailTapAction)
                }
            )
        }
    }

    @ViewBuilder
    private var infoView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(video.displayTitle(using: appEnvironment?.deArrowBrandingProvider))
                .font(titleFont)
                .lineLimit(style == .large ? 3 : style == .regular ? 2 : 1)

            if usesCompactPlaylistLayout {
                Text(playlistMetadataText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(usesPhoneLayout ? 2 : 1)
            } else {
                standardMetadata
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .if(textAreaTapAction != .playVideo && !disableInternalTapHandling) { view in
            view.highPriorityGesture(
                TapGesture().onEnded {
                    handleTapAction(textAreaTapAction)
                }
            )
        }
    }

    private var playlistMetadataText: String {
        let metadata = customMetadata.map { custom in
            [custom, usesPhoneLayout ? video.formattedPublishedDate : nil].compactMap { $0 }
        } ?? [video.formattedViewCount, video.formattedPublishedDate].compactMap { $0 }
        return ([video.author.name] + metadata).filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private var standardMetadata: some View {
        HStack(spacing: 4) {
            if style == .compact {
                // In compact mode, show author and duration inline with dot separator
                let duration = video.formattedDuration
                if !duration.isEmpty {
                    Text("\(video.author.name) · \(duration)")
                        .font(authorFont)
                        .foregroundStyle(.secondary)
                } else {
                    Text(video.author.name)
                        .font(authorFont)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(video.author.name)
                    .font(authorFont)
                    .foregroundStyle(.secondary)
            }

            if showSourceBadge {
                SourceBadge(source: video.id.source)
            }
        }

        if style != .compact || usesPhoneLayout {
            if let custom = customMetadata {
                Text([custom, usesPhoneLayout ? video.formattedPublishedDate : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(metadataFont)
                    .foregroundStyle(.tertiary)
            } else if video.viewCount != nil || video.formattedPublishedDate != nil {
                VideoMetadataLine(viewCount: video.formattedViewCount, publishedText: video.formattedPublishedDate)
                    .font(metadataFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func handleTapAction(_ action: VideoTapAction) {
        guard let env = appEnvironment else { return }

        switch action {
        case .playVideo:
            // This should not be called since we only add gesture for non-playVideo actions
            // The .tappableVideo() modifier will handle playVideo actions
            break
        case .openInfo:
            env.navigationCoordinator.navigate(to: .video(.loaded(video), queueContext: videoQueueContext))
        case .none:
            break
        }
    }
}

// MARK: - Preview

#Preview("Row") {
    VideoRowView(
        video: .preview,
        watchProgress: 0.6,
        showSourceBadge: true
    )
    .padding()
}
