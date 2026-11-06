//
//  CompactPlayerCard.swift
//  Yattee
//
//  Shared compact playback card for the Home and full-screen players.
//

import Foundation
import SwiftUI
import NukeUI

@MainActor
struct CompactPlayerCard: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let playerService: PlayerService
    var artworkTransitionNamespace: Namespace.ID? = nil
    let actionLabel: LocalizedStringKey
    var actionHint: LocalizedStringKey = ""
    let onTap: () -> Void

    nonisolated static let height: CGFloat = 64
    nonisolated static let cornerRadius: CGFloat = 14

    private var state: PlayerState { playerService.state }
    private var isPlaying: Bool { state.isPlayingIntended }
    private var artworkURLs: [URL] {
        guard let appEnvironment, let video = state.currentVideo else { return [] }
        let local = appEnvironment.downloadManager.download(for: video.id)?.localThumbnailPath.map {
            appEnvironment.downloadManager.downloadsDirectory().appendingPathComponent($0)
        }
        return [local, appEnvironment.deArrowBrandingProvider.thumbnailURL(for: video)].compactMap { $0 }
            + video.thumbnailURLsByQuality
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.currentVideo.map { appEnvironment?.deArrowBrandingProvider.title(for: $0) ?? $0.title } ?? "")
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                        Text(state.currentVideo?.author.name ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .leading)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(actionLabel)
            .accessibilityHint(actionHint)

            Button {
                playerService.togglePlayPause()
            } label: {
                PlayPauseSymbol(isPlaying: isPlaying)
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlayPauseButtonStyle())
            .disabled(state.isPlayPauseDisabled || state.isControlsLocked)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .overlay(alignment: .bottom) {
            progressLine
                .padding(.horizontal, Self.cornerRadius)
                .padding(.bottom, 1)
                .allowsHitTesting(false)
        }
        .compactPlayerBackground()
    }

    // MARK: - Artwork and Progress

    private var artwork: some View {
        FallbackLazyImage(urls: artworkURLs) { imageState in
            if let image = imageState.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "music.note").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .playerTransitionSource(artworkTransitionNamespace)
    }

    private var progressLine: some View {
        GeometryReader { geometry in
            let progress = max(0, min(1, state.progress))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25))
                Capsule().fill(Color.red).frame(width: geometry.size.width * progress)
            }
        }
        .frame(height: 2.5)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func compactPlayerBackground() -> some View {
        let shape = RoundedRectangle(cornerRadius: CompactPlayerCard.cornerRadius, style: .continuous)
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}
