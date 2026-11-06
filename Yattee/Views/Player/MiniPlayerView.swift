//
//  MiniPlayerView.swift
//  Yattee
//
//  Compact audio player above the tab bar.
//

import Foundation
import SwiftUI
import NukeUI

@MainActor
struct MiniPlayerView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.playerTransitionNamespace) private var playerTransitionNamespace

    private var service: PlayerService? { appEnvironment?.playerService }
    private var state: PlayerState? { service?.state }
    private var artworkURLs: [URL] {
        guard let appEnvironment, let video = state?.currentVideo else { return [] }
        let local = appEnvironment.downloadManager.download(for: video.id)?.localThumbnailPath.map {
            appEnvironment.downloadManager.downloadsDirectory().appendingPathComponent($0)
        }
        return [local, appEnvironment.deArrowBrandingProvider.thumbnailURL(for: video)].compactMap { $0 }
            + video.thumbnailURLsByQuality
    }

    static let height: CGFloat = 64
    static let cornerRadius: CGFloat = 14
    static let horizontalInset: CGFloat = 20
    /// Distance from the bottom safe area to the card, clearing the floating tab bar.
    static let tabBarClearance: CGFloat = 64

    var body: some View {
        content(compact: false)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: Self.height)
            .overlay(alignment: .bottom) {
                progressLine
                    .padding(.horizontal, Self.cornerRadius)
                    .padding(.bottom, 1)
            }
            .miniPlayerBackground(cornerRadius: Self.cornerRadius)
    }

    private var isPlaying: Bool { state?.playbackState == .playing }

    fileprivate var progressLine: some View {
        GeometryReader { geo in
            let p = max(0, min(1, state?.progress ?? 0))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.red).frame(width: geo.size.width * p)
            }
        }
        .frame(height: 2.5)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    fileprivate func content(compact: Bool) -> some View {
        let art: CGFloat = compact ? 26 : 48
        return HStack(spacing: compact ? 8 : 10) {
            Button {
                appEnvironment?.navigationCoordinator.expandPlayer()
            } label: {
                HStack(spacing: compact ? 8 : 10) {
                    FallbackLazyImage(urls: artworkURLs) { imageState in
                        if let image = imageState.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary)
                                .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
                        }
                    }
                    .frame(width: art, height: art)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .playerTransitionSource(playerTransitionNamespace)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state?.currentVideo.map { appEnvironment?.deArrowBrandingProvider.title(for: $0) ?? $0.title } ?? "")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        if !compact {
                            Text(state?.currentVideo?.author.name ?? "")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel("player.miniPlayer")

            Button {
                service?.togglePlayPause()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace.magic(fallback: .replace.downUp)))
                    .animation(.snappy, value: isPlaying)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(state?.isTransportDisabled ?? true)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

private extension View {
    @ViewBuilder
    func miniPlayerBackground(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    /// Reserves room above the tab bar so scrolling content isn't hidden behind the mini player.
    func miniPlayerInset(_ isVisible: Bool) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if isVisible {
                Color.clear.frame(height: MiniPlayerView.height + 8)
            }
        }
    }
}
