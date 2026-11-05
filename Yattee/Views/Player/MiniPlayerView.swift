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
    var isTabAccessory = false

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

    var body: some View {
        if isTabAccessory, #available(iOS 26, *) {
            AccessoryContent(view: self)
        } else {
            content(compact: false)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    @available(iOS 26, *)
    private struct AccessoryContent: View {
        let view: MiniPlayerView
        @Environment(\.tabViewBottomAccessoryPlacement) private var placement

        var body: some View {
            view.content(compact: placement == .inline)
                .padding(.leading, 6)
                .padding(.trailing, 4)
        }
    }

    private var isPlaying: Bool { state?.playbackState == .playing }

    fileprivate func content(compact: Bool) -> some View {
        let art: CGFloat = compact ? 26 : 34
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
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 0) {
                        Text(state?.currentVideo.map { appEnvironment?.deArrowBrandingProvider.title(for: $0) ?? $0.title } ?? "")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !compact {
                            Text(state?.currentVideo?.author.name ?? "")
                                .font(.caption)
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
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .disabled(state?.isTransportDisabled ?? true)
            .accessibilityLabel(isPlaying ? "Pause" : "Play")

        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}
