//
//  VideoChannelAvatarView.swift
//  Yattee
//
//  Video card avatar using local channel metadata before a cached API lookup.
//

import Foundation
import SwiftUI

@MainActor
struct VideoChannelAvatarView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var loadedAuthor: Author?

    let video: Video
    var size: CGFloat = 36

    private struct Request: Equatable, Sendable {
        let author: Author
        let source: ContentSource
        let instance: Instance?
    }

    private var request: Request {
        Request(
            author: video.author,
            source: video.authorSource,
            instance: appEnvironment?.instancesManager.instance(for: video.authorSource)
        )
    }

    private var avatarAuthor: Author {
        guard video.author.thumbnailURL == nil,
              let loadedAuthor, loadedAuthor.id == video.author.id else { return video.author }
        return loadedAuthor
    }

    private var canOpenChannel: Bool {
        appEnvironment != nil && !video.author.id.isEmpty && video.author.hasRealChannelInfo
            && video.authorSource == .global(provider: ContentSource.youtubeProvider)
    }

    var body: some View {
        ChannelAvatarView(author: avatarAuthor, size: size, source: video.authorSource)
            .contentShape(Circle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(video.author.name))
            .if(canOpenChannel) { avatar in
                // Cards are already inside the playback button. A gesture on
                // its avatar takes priority without nesting another button.
                avatar.highPriorityGesture(TapGesture().onEnded { openChannel() })
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(Text("video.context.goToChannel"))
                    .accessibilityAction { openChannel() }
            }
            .task(id: request) { await loadAvatar(for: request) }
    }

    private func openChannel() {
        appEnvironment?.navigationCoordinator.navigateToChannel(for: video)
    }

    private func loadAvatar(for request: Request) async {
        loadedAuthor = nil
        guard request.author.thumbnailURL == nil, !request.author.id.isEmpty,
              request.source == .global(provider: ContentSource.youtubeProvider),
              let appEnvironment else { return }

        let author = request.author.enriched(using: appEnvironment.dataManager)
        if author.thumbnailURL != nil {
            loadedAuthor = author
            return
        }
        guard let instance = request.instance else { return }

        do {
            let url = try await appEnvironment.contentService.channelAvatarURL(id: author.id, instance: instance)
            guard !Task.isCancelled, let url else { return }
            loadedAuthor = author.enriched(from: CachedChannelData(
                name: author.name, thumbnailURL: url, bannerURL: nil, subscriberCount: nil
            ))
        } catch {
            // The shared loader logs failures once and caches them briefly.
            // ChannelAvatarView keeps its initial-letter placeholder.
        }
    }
}
