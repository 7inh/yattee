//
//  ChapterRow.swift
//  Yattee
//
//  Row for a video chapter in the player's Chapters tab. Tapping seeks to it.
//

import SwiftUI

struct ChapterRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let chapter: VideoChapter
    let index: Int
    let isActive: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    if isActive {
                        Image(systemName: "waveform")
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                            .symbolEffect(.variableColor.iterative, options: .repeating,
                                          isActive: isPlaying && !reduceMotion)
                    } else {
                        Text(verbatim: "\(index + 1)")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28)
                .accessibilityHidden(true)

                Text(chapter.title)
                    .font(.subheadline.weight(isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(chapter.formattedStartTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 4)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.accentColor.opacity(0.12))
                        .padding(.horizontal, -4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(chapter.title), \(chapter.formattedStartTime)")
        .accessibilityValue(isActive ? String(localized: "Playing") : "")
    }
}

#Preview {
    VStack(spacing: 4) {
        ChapterRow(chapter: VideoChapter(title: "Intro", startTime: 0), index: 0,
                   isActive: false, isPlaying: true, onTap: {})
        ChapterRow(chapter: VideoChapter(title: "Arriving in Funchal", startTime: 782), index: 1,
                   isActive: true, isPlaying: true, onTap: {})
    }
    .padding()
}
