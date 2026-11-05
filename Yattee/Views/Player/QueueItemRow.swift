//
//  QueueItemRow.swift
//  Yattee
//
//  Compact queue row with playback status and swipe-to-remove action.
//

import Foundation
import SwiftUI

struct QueueItemRow: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let queuedVideo: QueuedVideo
    let isCurrentlyPlaying: Bool
    let onRemove: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                DeArrowVideoThumbnail(
                    video: queuedVideo.video,
                    cornerRadius: 6
                )
                .frame(width: 64, height: 36)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(queuedVideo.video.displayTitle(using: appEnvironment?.deArrowBrandingProvider))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(isCurrentlyPlaying ? Color.red : Color.primary)

                    Text(verbatim: "\(queuedVideo.video.author.name) · \(queuedVideo.video.formattedDuration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrentlyPlaying {
                    Image(systemName: "waveform")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .accessibilityLabel(String(localized: "queue.section.nowPlaying"))
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowSeparator(.hidden)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label(String(localized: "queue.item.remove"), systemImage: "trash")
            }
        }
    }
}
