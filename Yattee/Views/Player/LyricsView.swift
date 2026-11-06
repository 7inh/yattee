//
//  LyricsView.swift
//  Yattee
//
//  Scrollable, seekable captions synchronized with audio playback.
//

import Foundation
import SwiftUI

@MainActor
struct LyricsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var model: LyricsViewModel
    let playerState: PlayerState
    let isSeekDisabled: Bool
    let onSeek: (TimeInterval) -> Void

    @State private var currentIndex: Int?
    @State private var lastScrolledIndex: Int?
    @State private var resumeFollowingAt = ContinuousClock.now
    @State private var isManuallyScrolling = false

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Loading lyrics")
            } else if model.lines.isEmpty {
                VStack(spacing: 12) {
                    Text("No lyrics available")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                    if model.errorMessage != nil {
                        Button("Retry") {
                            Task { await model.loadLyrics() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .accessibilityHint(model.errorMessage ?? "")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                syncedLines
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: model.selectedTrack) {
            currentIndex = nil
            lastScrolledIndex = nil
            resumeFollowingAt = .now
            isManuallyScrolling = false
            await model.loadLyrics()
        }
    }

    // MARK: - Playback Following

    private var syncedLines: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.lines.indices, id: \.self) { index in
                            let line = model.lines[index]
                            Button {
                                resumeFollowingAt = .now
                                lastScrolledIndex = nil
                                onSeek(line.start)
                            } label: {
                                Text(line.text)
                                    .font(.system(size: 26, weight: .bold))
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.white.opacity(index == currentIndex ? 1 : 0.35))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSeekDisabled)
                            .accessibilityLabel(line.text)
                            .accessibilityHint("Seeks to \(line.start.formattedAsTimestamp)")
                            .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, geometry.size.height / 3)
                    .padding(.bottom, geometry.size.height * 2 / 3)
                }
                .scrollIndicators(.hidden)
                .onChange(of: geometry.size) { _, _ in
                    lastScrolledIndex = nil
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        isManuallyScrolling = true
                        lastScrolledIndex = nil
                    } else if phase == .idle, isManuallyScrolling {
                        isManuallyScrolling = false
                        resumeFollowingAt = .now.advanced(by: .seconds(3))
                    }
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.08),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    while !Task.isCancelled {
                        followPlayback(using: proxy)
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            return
                        }
                    }
                }
            }
        }
    }

    private func followPlayback(using proxy: ScrollViewProxy) {
        guard playerState.publishesTimeUpdates else { return }
        let index = LyricLine.currentIndex(at: playerState.untrackedCurrentTime, in: model.lines)
        if currentIndex != index {
            withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.2)) {
                currentIndex = index
            }
        }
        // Show the first line before the first cue starts; gaps retain the scroll position.
        let target = index ?? (playerState.untrackedCurrentTime < (model.lines.first?.start ?? 0) ? 0 : nil)
        guard !isManuallyScrolling, ContinuousClock.now >= resumeFollowingAt,
              let target, target != lastScrolledIndex else { return }
        lastScrolledIndex = target
        withAnimation(.easeInOut(duration: reduceMotion ? 0 : 0.4)) {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 1.0 / 3))
        }
    }
}

// MARK: - Track Selection

@MainActor
struct LyricsTrackPicker: View {
    @Bindable var model: LyricsViewModel

    var body: some View {
        Menu {
            ForEach(model.tracks) { track in
                Button {
                    model.selectedTrack = track
                } label: {
                    if track == model.selectedTrack {
                        Label(track.label, systemImage: "checkmark")
                    } else {
                        Text(track.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.selectedTrack?.displayName ?? String(localized: "Captions"))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.7))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel("Caption track")
        .accessibilityValue(model.selectedTrack?.label ?? "")
    }
}
