//
//  OnTheGoPanel.swift
//  Yattee
//
//  Large playback controls shown below the video on iPhone in portrait.
//

import Foundation
import SwiftUI

#if os(iOS)

@MainActor
struct OnTheGoPanel: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.presentAppSheet) private var presentAppSheet

    let playerService: PlayerService
    let onClose: () -> Void

    @GestureState private var scrubTime: TimeInterval? = nil
    @State private var pendingSeekTime: TimeInterval?

    private var state: PlayerState { playerService.state }
    private var duration: TimeInterval {
        state.duration.isFinite ? max(0, state.duration) : 0
    }
    private var displayedTime: TimeInterval {
        boundedTime(scrubTime ?? pendingSeekTime ?? state.currentTime)
    }
    private var isTransportDisabled: Bool {
        state.isTransportDisabled || state.isControlsLocked
    }
    private var isSeekDisabled: Bool {
        isTransportDisabled || state.isLive || duration <= 0
    }
    private var timeLabel: String {
        state.isLive ? state.formattedDuration : "\(displayedTime.formattedAsTimestamp) / \(duration.formattedAsTimestamp)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        videoInfo
                        Spacer(minLength: 24)
                        seekControls
                            .id(state.currentVideo?.id)
                        Spacer(minLength: 24)
                        transportControls
                        Spacer(minLength: 24)
                        accessoryControls
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 32)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(.primary)
        .background(Color(.systemBackground))
        .onChange(of: state.currentVideo?.id) { _, _ in
            pendingSeekTime = nil
        }
    }

    // MARK: - Header and Video

    private var header: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 40, height: 4)
                .accessibilityHidden(true)

            HStack {
                Text("On-the-go")
                    .font(.title2.bold())
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 22, weight: .medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close On-the-go")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var videoInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let video = state.currentVideo {
                Text(appEnvironment?.deArrowBrandingProvider.title(for: video) ?? video.title)
                    .font(.title2.bold())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(video.author.name)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Seeking

    private var seekControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(timeLabel)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                let trackWidth = max(1, geometry.size.width - 28)
                let progress = duration > 0 ? CGFloat(displayedTime / duration) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 8)
                    Capsule()
                        .fill(Color.red)
                        .frame(width: trackWidth * progress, height: 8)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                        .offset(x: trackWidth * progress - 14)
                }
                .frame(width: trackWidth, height: 48)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .updating($scrubTime) { value, time, _ in
                            guard !isSeekDisabled else { return }
                            time = seekTime(at: value.location.x, trackWidth: trackWidth)
                        }
                        .onEnded { value in
                            seek(to: seekTime(at: value.location.x, trackWidth: trackWidth))
                        }
                )
            }
            .frame(height: 48)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
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
    }

    private func boundedTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? min(max(0, time), duration) : 0
    }

    private func seekTime(at position: CGFloat, trackWidth: CGFloat) -> TimeInterval {
        boundedTime(Double((position - 14) / trackWidth) * duration)
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
        HStack(spacing: 0) {
            transportButton("backward.end.fill", label: String(localized: "menu.playback.previousVideo"), disabled: !state.hasPrevious || isTransportDisabled) {
                Task { await playerService.playPrevious() }
            }
            Spacer(minLength: 0)
            transportButton("gobackward.10", label: String(localized: "menu.playback.seekBackward \(10)"), disabled: isSeekDisabled) {
                playerService.seekBackward(by: 10)
            }
            Spacer(minLength: 0)
            Button {
                playerService.togglePlayPause()
            } label: {
                Image(systemName: state.playbackState == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .frame(width: 88, height: 88)
                    .background(Color(.systemGray5), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(isTransportDisabled)
            .opacity(isTransportDisabled ? 0.4 : 1)
            .accessibilityLabel(state.playbackState == .playing ? Text("Pause") : Text("Play"))
            Spacer(minLength: 0)
            transportButton("goforward.10", label: String(localized: "menu.playback.seekForward \(10)"), disabled: isSeekDisabled) {
                playerService.seekForward(by: 10)
            }
            Spacer(minLength: 0)
            transportButton("forward.end.fill", label: String(localized: "menu.playback.nextVideo"), disabled: !state.hasNext || isTransportDisabled) {
                Task { await playerService.playNext() }
            }
        }
    }

    private func transportButton(_ image: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .font(.system(size: 40))
                .frame(width: 60, height: 60)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .accessibilityLabel(label)
    }

    // MARK: - Accessories

    private var accessoryControls: some View {
        HStack {
            Spacer(minLength: 0)
            Menu {
                PlaybackSpeedMenuContent(currentRate: state.rate) { rate in
                    state.rate = rate
                    playerService.currentBackend?.rate = Float(rate.rawValue)
                }
            } label: {
                accessoryIcon("gauge.with.needle")
            }
            .menuIndicator(.hidden)
            .tint(.primary)
            .disabled(state.isControlsLocked)
            .accessibilityLabel(String(localized: "controls.button.speed"))
            .accessibilityValue(state.rate.displayText)

            Spacer(minLength: 0)
            Button {
                presentAppSheet(.queue())
            } label: {
                accessoryIcon("list.bullet")
            }
            .accessibilityLabel(String(localized: "controls.button.queue"))

            if let video = state.currentVideo, !video.isFromMediaSource,
               appEnvironment?.downloadManager.isDownloaded(video.id) != true,
               appEnvironment?.downloadManager.isDownloading(video.id) != true {
                Spacer(minLength: 0)
                Button {
                    presentAppSheet(.downloadOptions(video, streams: playerService.availableStreams, captions: playerService.availableCaptions, dislikeCount: state.dislikeCount))
                } label: {
                    accessoryIcon("arrow.down")
                }
                .accessibilityLabel(String(localized: "video.context.download"))
            }
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
    }

    private func accessoryIcon(_ image: String) -> some View {
        Image(systemName: image)
            .font(.system(size: 30))
            .frame(width: 60, height: 60)
            .contentShape(Rectangle())
    }
}

#endif
