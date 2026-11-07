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
    let isActive: Bool
    let isPaging: Bool
    let allowsManualScrolling: Bool
    let topInset: CGFloat
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
            let viewportHeight = max(1, geometry.size.height)
            let contentHeight = max(0, geometry.size.height - topInset)
            let restingOffset = topInset + contentHeight / 3
            let scrollAnchor = UnitPoint(x: 0.5, y: restingOffset / viewportHeight)
            let bottomFadeStart = 1 - contentHeight * 0.12 / viewportHeight
            let topFadeEnd = min(bottomFadeStart, (topInset + contentHeight * 0.08) / viewportHeight)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.lines.indices, id: \.self) { index in
                            let line = model.lines[index]
                            Button {
                                resumeFollowingAt = .now
                                lastScrolledIndex = nil
                                LoggingService.shared.debug("Lyrics seek to \(line.start)", category: .player)
                                onSeek(line.start)
                            } label: {
                                Text(line.text)
                                    .font(.system(size: 26, weight: .bold))
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.white.opacity(index == currentIndex ? 1 : 0.35))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(LyricsSeekButtonStyle())
                            .disabled(isSeekDisabled)
                            .accessibilityLabel(line.text)
                            .accessibilityHint("Seeks to \(line.start.formattedAsTimestamp)")
                            .accessibilityAddTraits(index == currentIndex ? [.isSelected] : [])
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 4)
                    // Preserve the resting line's position below the header
                    // while letting earlier lines scroll all the way behind it.
                    .padding(.top, restingOffset)
                    .padding(.bottom, contentHeight * 2 / 3)
                }
                .scrollIndicators(.hidden)
                // The viewport already includes the status bar; its space is
                // accounted for by topInset rather than an automatic inset.
                .ignoresSafeArea(.container, edges: .top)
                // With an inline queue, vertical drags belong to the panel so
                // they can reveal the queue even when they start on a lyric.
                // Programmatic playback following and line taps still work.
                .scrollDisabled(isPaging || !allowsManualScrolling)
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
                        .init(color: .black.opacity(0.15), location: topFadeEnd * 0.5),
                        .init(color: .black, location: topFadeEnd),
                        .init(color: .black, location: bottomFadeStart),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom)
                }
                .task(id: scenePhase == .active && isActive && !isPaging ? scrollAnchor.y : nil) {
                    // Keep the page mounted during transitions without polling
                    // or moving its scroll position while hidden or paging.
                    guard scenePhase == .active, isActive, !isPaging else { return }
                    while !Task.isCancelled {
                        followPlayback(using: proxy, anchor: scrollAnchor)
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

    private func followPlayback(using proxy: ScrollViewProxy, anchor: UnitPoint) {
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
            proxy.scrollTo(target, anchor: anchor)
        }
    }
}

// MARK: - Lyric Seeking

@MainActor
private struct LyricsSeekButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        // Require a tap so neither paging nor vertical scrolling can also
        // activate a line's seek button.
        configuration.label
            .onTapGesture {
                guard isEnabled else { return }
                configuration.trigger()
            }
            .accessibilityAction {
                guard isEnabled else { return }
                configuration.trigger()
            }
    }
}

// MARK: - Track Selection

@MainActor
struct LyricsTrackOptions: View {
    @Bindable var model: LyricsViewModel

    var body: some View {
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
    }
}
