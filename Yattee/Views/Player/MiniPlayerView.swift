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
        HStack(spacing: 12) {
            Button {
                appEnvironment?.navigationCoordinator.expandPlayer()
            } label: {
                HStack(spacing: 12) {
                    FallbackLazyImage(urls: artworkURLs) { imageState in
                        if let image = imageState.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note") }
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state?.currentVideo.map { appEnvironment?.deArrowBrandingProvider.title(for: $0) ?? $0.title } ?? "")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(state?.currentVideo?.author.name ?? "")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            Button {
                service?.togglePlayPause()
            } label: {
                Image(systemName: state?.playbackState == .playing ? "pause.fill" : "play.fill")
                    .frame(width: 44, height: 44)
            }
            .disabled(state?.isTransportDisabled ?? true)
            .accessibilityLabel(state?.playbackState == .playing ? "Pause" : "Play")
            Button {
                Task { await service?.playNext() }
            } label: {
                Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
            }
            .disabled(state?.hasNext != true)
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("player.miniPlayer")
    }
}
