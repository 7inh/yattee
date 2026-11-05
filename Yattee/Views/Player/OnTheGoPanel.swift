//
//  OnTheGoPanel.swift
//  Yattee
//
//  Large playback controls presented in a native sheet below the iPhone video.
//

import Foundation
import SwiftUI

#if os(iOS)

private let onTheGoAccent = Color.red

@MainActor
struct OnTheGoPanel: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.presentAppSheet) private var presentAppSheet

    let playerService: PlayerService
    let onClose: () -> Void

    @GestureState private var scrubTime: TimeInterval? = nil
    @State private var pendingSeekTime: TimeInterval?
    @State private var transportFeedbackTrigger = false

    private enum Layout {
        static let smallSpacing: CGFloat = 8
        static let mediumSpacing: CGFloat = 16
        // Keeps the enlarged thumb inside the seek control at both endpoints.
        static let seekInset: CGFloat = 12
        static let seekTrackHeight: CGFloat = 6
    }

    private var state: PlayerState { playerService.state }
    private var sleepTimer: SleepTimer { .shared }
    private var isAutoPlayNextEnabled: Bool {
        appEnvironment?.settingsManager.queueAutoPlayNext ?? true
    }
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
    private var isHapticFeedbackEnabled: Bool {
        guard let settings = appEnvironment?.settingsManager else { return true }
        return settings.hapticFeedbackEnabled && settings.hapticFeedbackIntensity != .off
    }

    var body: some View {
        panelContent
            .foregroundStyle(.primary)
            .tint(onTheGoAccent)
            .sensoryFeedback(.impact(weight: .light), trigger: transportFeedbackTrigger) { _, _ in
                isHapticFeedbackEnabled
            }
            .onChange(of: state.currentVideo?.id) { _, _ in
                pendingSeekTime = nil
            }
    }

    private var panelContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    // Share extra height across all four gaps. Compact detents
                    // keep the gaps small; shorter sheets and large text scroll.
                    Spacer(minLength: Layout.smallSpacing)
                    videoInfo
                    Spacer(minLength: Layout.smallSpacing)
                    seekControls
                        .id(state.currentVideo?.id)
                    Spacer(minLength: Layout.smallSpacing)
                    transportControls
                    Spacer(minLength: Layout.smallSpacing)
                    accessoryBar
                }
                .padding(.horizontal, Layout.mediumSpacing)
                .padding(.vertical, Layout.smallSpacing)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Header and Video

    private var header: some View {
        HStack {
            Text(String(localized: "player.onTheGo.title"))
                .font(.headline.weight(.semibold))
            Spacer()
            closeButton
                .accessibilityLabel(String(localized: "player.onTheGo.close"))
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(Color(.secondarySystemBackground), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var videoInfo: some View {
        VStack(alignment: .leading, spacing: Layout.smallSpacing) {
            if let video = state.currentVideo {
                Text(appEnvironment?.deArrowBrandingProvider.title(for: video) ?? video.title)
                    .font(.title3.bold())
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(video.author.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Seeking

    private var seekControls: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geometry in
                let trackWidth = max(1, geometry.size.width - Layout.seekInset * 2)
                let progress = duration > 0 ? CGFloat(displayedTime / duration) : 0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: Layout.seekTrackHeight)
                    Capsule()
                        .fill(onTheGoAccent)
                        .frame(width: trackWidth * progress, height: Layout.seekTrackHeight)
                    Circle()
                        .fill(onTheGoAccent)
                        .frame(width: 20, height: 20)
                        .scaleEffect(scrubTime == nil ? 1 : 1.2)
                        .animation(.easeOut(duration: 0.15), value: scrubTime != nil)
                        .offset(x: trackWidth * progress - 10)
                }
                .frame(width: trackWidth, height: 44)
                .padding(.horizontal, Layout.seekInset)
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
            .frame(height: 44)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "player.onTheGo.playbackPosition"))
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

            HStack {
                if state.isLive {
                    Text(String(localized: "player.live"))
                } else {
                    Text(verbatim: displayedTime.formattedAsTimestamp)
                    Spacer(minLength: Layout.smallSpacing)
                    Text(verbatim: "-\(max(0, duration - displayedTime).formattedAsTimestamp)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private func boundedTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? min(max(0, time), duration) : 0
    }

    private func seekTime(at position: CGFloat, trackWidth: CGFloat) -> TimeInterval {
        boundedTime(Double((position - Layout.seekInset) / trackWidth) * duration)
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

    @ViewBuilder
    private var transportControls: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: Layout.mediumSpacing) {
                transportButtons
            }
        } else {
            transportButtons
        }
    }

    private var transportButtons: some View {
        HStack(spacing: 0) {
            transportButton("backward.end", label: String(localized: "menu.playback.previousVideo"), disabled: !state.hasPrevious || isTransportDisabled) {
                Task { await playerService.playPrevious() }
            }
            Spacer(minLength: 0)
            transportButton("gobackward.10", label: String(localized: "menu.playback.seekBackward \(10)"), disabled: isSeekDisabled) {
                playerService.seekBackward(by: 10)
            }
            Spacer(minLength: 0)
            Button {
                transportFeedbackTrigger.toggle()
                playerService.togglePlayPause()
            } label: {
                playPauseLabel
            }
            .modifier(OnTheGoTransportStyleModifier(isProminent: true))
            .disabled(isTransportDisabled)
            .accessibilityLabel(state.playbackState == .playing ? String(localized: "player.controls.pause") : String(localized: "player.controls.play"))
            Spacer(minLength: 0)
            transportButton("goforward.10", label: String(localized: "menu.playback.seekForward \(10)"), disabled: isSeekDisabled) {
                playerService.seekForward(by: 10)
            }
            Spacer(minLength: 0)
            transportButton("forward.end", label: String(localized: "menu.playback.nextVideo"), disabled: !state.hasNext || isTransportDisabled) {
                Task { await playerService.playNext() }
            }
        }
    }

    @ViewBuilder
    private var playPauseLabel: some View {
        if #available(iOS 26, *) {
            playPauseSymbol
                .font(.system(size: 36, weight: .semibold))
        } else {
            playPauseSymbol
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(onTheGoAccent, in: Circle())
                .opacity(isTransportDisabled ? 0.4 : 1)
                .contentShape(Circle())
        }
    }

    private var playPauseSymbol: some View {
        Image(systemName: state.playbackState == .playing ? "pause.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace))
            .animation(.easeInOut(duration: 0.2), value: state.playbackState == .playing)
    }

    private func transportButton(_ image: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            transportFeedbackTrigger.toggle()
            action()
        } label: {
            if #available(iOS 26, *) {
                Image(systemName: image)
                    .symbolVariant(.none)
                    .font(.system(size: 28, weight: .semibold))
            } else {
                Image(systemName: image)
                    .symbolVariant(.none)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(disabled ? Color(.tertiaryLabel) : Color(.label))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
        }
        .modifier(OnTheGoTransportStyleModifier())
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Accessories

    @ViewBuilder
    private var accessoryBar: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer {
                accessoryControls
                    .padding(.horizontal, Layout.smallSpacing)
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        } else {
            accessoryControls
                .padding(.horizontal, Layout.smallSpacing)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }

    private var accessoryControls: some View {
        HStack(spacing: 0) {
            Menu {
                PlaybackSpeedMenuContent(currentRate: state.rate) { rate in
                    state.rate = rate
                    playerService.currentBackend?.rate = Float(rate.rawValue)
                }
            } label: {
                accessoryLabel("gauge.with.needle", caption: state.rate.compactDisplayText, isActive: state.rate != .x1)
            }
            .frame(maxWidth: .infinity)
            .menuIndicator(.hidden)
            .tint(state.rate != .x1 ? onTheGoAccent : .primary)
            .disabled(state.isControlsLocked)
            .accessibilityLabel(String(localized: "controls.button.speed"))
            .accessibilityValue(state.rate.displayText)

            sleepTimerMenu
                .frame(maxWidth: .infinity)

            Button {
                appEnvironment?.settingsManager.queueAutoPlayNext.toggle()
            } label: {
                accessoryLabel(
                    "play.square.stack",
                    caption: String(localized: "player.onTheGo.autoplay"),
                    isActive: isAutoPlayNextEnabled,
                    iconColor: .secondary
                )
            }
            .frame(maxWidth: .infinity)
            .disabled(state.isControlsLocked || appEnvironment == nil)
            .accessibilityLabel(String(localized: "controls.button.autoPlayNext"))
            .accessibilityValue(isAutoPlayNextEnabled ? String(localized: "common.on") : String(localized: "common.off"))

            Button {
                presentAppSheet(.queue())
            } label: {
                accessoryLabel("list.bullet", caption: String(localized: "controls.button.queue"))
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel(String(localized: "controls.button.queue"))

            if let video = state.currentVideo, !video.isFromMediaSource,
               appEnvironment?.downloadManager.isDownloaded(video.id) != true,
               appEnvironment?.downloadManager.isDownloading(video.id) != true {
                Button {
                    presentAppSheet(.downloadOptions(video, streams: playerService.availableStreams, captions: playerService.availableCaptions, dislikeCount: state.dislikeCount))
                } label: {
                    accessoryLabel("arrow.down", caption: String(localized: "video.context.download"))
                }
                .frame(maxWidth: .infinity)
                .accessibilityLabel(String(localized: "video.context.download"))
            }
        }
        .buttonStyle(.plain)
    }

    private var sleepTimerMenu: some View {
        Menu {
            sleepTimerOption(String(localized: "common.off"), isSelected: sleepTimer.mode == .off) {
                sleepTimer.cancel()
            }
            ForEach(SleepTimer.durationOptions, id: \.self) { minutes in
                sleepTimerOption(String(localized: "\(minutes) minutes"), isSelected: sleepTimer.selectedMinutes == minutes) {
                    sleepTimer.start(minutes: minutes, playerService: playerService)
                }
            }
            sleepTimerOption(String(localized: "End of video"), isSelected: sleepTimer.mode == .endOfVideo) {
                sleepTimer.startEndOfVideo(playerService: playerService)
            }
            .disabled(state.currentVideo == nil)
        } label: {
            accessoryLabel(
                "moon.zzz",
                caption: sleepTimer.caption ?? String(localized: "player.onTheGo.sleep"),
                isActive: sleepTimer.isActive
            )
        }
        .menuIndicator(.hidden)
        .tint(sleepTimer.isActive ? onTheGoAccent : .primary)
        .disabled(state.isControlsLocked)
        .accessibilityLabel(String(localized: "player.onTheGo.sleepTimer"))
        .accessibilityValue(sleepTimer.caption ?? String(localized: "common.off"))
    }

    private func sleepTimerOption(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private func accessoryLabel(_ image: String, caption: String, isActive: Bool = false, iconColor: Color = .primary) -> some View {
        VStack(spacing: Layout.smallSpacing) {
            Image(systemName: image)
                .symbolVariant(.none)
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(isActive ? onTheGoAccent : iconColor)
                .frame(height: 28)

            Text(verbatim: caption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isActive ? onTheGoAccent : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.vertical, Layout.smallSpacing)
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
    }
}

// MARK: - Transport Styling

/// Native glass supplies press feedback on iOS 26; older systems use a scale effect.
private struct OnTheGoTransportStyleModifier: ViewModifier {
    var isProminent = false

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            Group {
                if isProminent {
                    content.buttonStyle(.glassProminent)
                        .tint(onTheGoAccent)
                        .foregroundStyle(.white)
                } else {
                    content.buttonStyle(.glass)
                }
            }
            .buttonBorderShape(.circle)
            .buttonSizing(.flexible)
            .frame(width: isProminent ? 88 : 56, height: isProminent ? 88 : 56)
        } else {
            content.buttonStyle(OnTheGoTransportButtonStyle())
        }
    }
}

private struct OnTheGoTransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

#endif
