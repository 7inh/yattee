//
//  QueueItemRow.swift
//  Yattee
//
//  Shared compact queue row for the player and queue management sheet.
//

import Foundation
import SwiftUI

struct QueueItemRow: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let video: Video
    let isCurrentlyPlaying: Bool
    var onRemove: (() -> Void)? = nil
    var onReorder: (() -> Void)? = nil
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    DeArrowVideoThumbnail(video: video, cornerRadius: 6)
                        .frame(width: 64, height: 36)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(video.displayTitle(using: appEnvironment?.deArrowBrandingProvider))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                            .foregroundStyle(.primary)

                        Text(verbatim: "\(video.author.name) • \(video.formattedDuration)")
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
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }

            if let onReorder {
                Button(action: onReorder) {
                    Image(systemName: "line.3.horizontal")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "Reorder queue"))
                .accessibilityHint(String(localized: "Opens queue management"))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .background(isCurrentlyPlaying ? Color.primary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            if let onRemove {
                Button(String(localized: "Remove from queue"), systemImage: "trash", role: .destructive, action: onRemove)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label(String(localized: "queue.item.remove"), systemImage: "trash")
                }
            }
        }
    }
}
