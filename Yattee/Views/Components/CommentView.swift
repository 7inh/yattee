//
//  CommentView.swift
//  Yattee
//
//  Read-only comment row with expandable text and inline continuation replies.
//

import Foundation
import SwiftUI
import NukeUI

@MainActor
struct CommentView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    let comment: Comment
    let videoID: String?
    let source: ContentSource?
    let isReply: Bool
    let showAvatar: Bool
    let instance: Instance?

    @State private var isContentExpanded = false
    @State private var fullTextHeight: CGFloat = 0
    @State private var collapsedTextHeight: CGFloat = 0
    @State private var replies: [Comment] = []
    @State private var isLoadingReplies = false
    @State private var showReplies = false
    @State private var hasLoadedReplies = false
    @State private var repliesContinuation: String?
    @State private var replyError: String?
    @State private var replyInstance: Instance?
    @State private var loadedReplyTokens: Set<String> = []

    private var accentColor: Color { appEnvironment?.settingsManager.resolvedAccentColor ?? .accentColor }
    private var resolvedInstance: Instance? {
        instance ?? source.flatMap { appEnvironment?.instancesManager.instance(for: $0) }
    }
    private var canLoadReplies: Bool {
        videoID != nil && comment.repliesContinuation?.isEmpty == false
    }

    init(comment: Comment, videoID: String? = nil, source: ContentSource? = nil, isReply: Bool = false, showAvatar: Bool = true, instance: Instance? = nil) {
        self.comment = comment
        self.videoID = videoID
        self.source = source
        self.isReply = isReply
        self.showAvatar = showAvatar
        self.instance = instance
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if showAvatar {
                    authorAvatar
                }
                VStack(alignment: .leading, spacing: 6) {
                    authorInfo
                    commentContent
                    metadataRow
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showReplies {
                repliesSection
                    .padding(.leading, showAvatar ? 48 : 16)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Author

    private var authorAvatar: some View {
        LazyImage(url: comment.author.thumbnailURL) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(.quaternary)
                    .overlay {
                        Text(String(comment.author.name.drop(while: { $0 == "@" || $0.isWhitespace }).prefix(1)).uppercased())
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: isReply ? 28 : 36, height: isReply ? 28 : 36)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }

    private var authorMetadata: String {
        let name = comment.author.name
        var text = name.hasPrefix("@") ? name : "@\(name)"
        if let published = comment.formattedPublishedDate {
            text += " • \(published)"
        }
        if comment.isEdited == true && !text.localizedCaseInsensitiveContains("(edited)") {
            text += " \(String(localized: "(edited)"))"
        }
        return text
    }

    private var authorInfo: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: authorMetadata)
            if comment.isCreatorComment {
                Image(systemName: "checkmark.seal.fill")
                    .accessibilityLabel("Creator")
            }
            if comment.isPinned {
                Image(systemName: "pin.fill")
                    .accessibilityLabel("Pinned comment")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Content and Counts

    private var commentText: Text {
        Text(DescriptionText.attributed(comment.content, linkColor: accentColor))
    }

    private var commentContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            commentText
                .lineLimit(isContentExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .handleTimestampLinks(using: appEnvironment?.playerService)
                .background {
                    commentText
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullTextHeight = $0 }
                }
                .background {
                    commentText
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedTextHeight = $0 }
                }

            if fullTextHeight > collapsedTextHeight + 1 && collapsedTextHeight > 0 {
                Button {
                    isContentExpanded.toggle()
                } label: {
                    Text(isContentExpanded ? "Show less" : "Read more")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(isReply ? .subheadline : .body)
    }

    private var metadataRow: some View {
        HStack(spacing: 16) {
            if let likeCount = comment.likeCount {
                Label(CountFormatter.compact(max(0, likeCount)), systemImage: "hand.thumbsup")
                    .foregroundStyle(.secondary)
            }
            if comment.hasCreatorHeart {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Hearted by creator")
            }
            if !isReply && comment.replyCount > 0 {
                if canLoadReplies {
                    Button {
                        showReplies.toggle()
                        if showReplies && !hasLoadedReplies {
                            Task { await loadReplies() }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(replyCountText)
                            Image(systemName: showReplies ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accentColor)
                    .accessibilityValue(showReplies ? "Expanded" : "Collapsed")
                } else {
                    Text(replyCountText).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private var replyCountText: String {
        comment.replyCount == 1 ? String(localized: "1 reply") : String(localized: "\(comment.replyCount) replies")
    }

    // MARK: - Replies

    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(replies) { reply in
                CommentView(comment: reply, source: source, isReply: true, showAvatar: showAvatar, instance: replyInstance)
            }
            if isLoadingReplies {
                ProgressView().padding(.vertical, 8)
            } else if let replyError {
                Text(replyError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(String(localized: "common.retry")) {
                    Task { await loadReplies() }
                }
                .buttonStyle(.plain)
            } else if repliesContinuation != nil {
                Button(String(localized: "comments.loadMoreReplies")) {
                    Task { await loadReplies() }
                }
                .buttonStyle(.plain)
            } else if hasLoadedReplies && replies.isEmpty {
                Text("No replies available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadReplies() async {
        guard !isLoadingReplies else { return }
        let continuation = hasLoadedReplies ? repliesContinuation : comment.repliesContinuation
        guard let videoID, let continuation, !continuation.isEmpty else { return }
        guard let service = appEnvironment?.contentService,
              let instance = replyInstance ?? resolvedInstance else {
            replyError = APIError.noInstance.localizedDescription
            return
        }
        replyInstance = instance
        isLoadingReplies = true
        replyError = nil
        defer { isLoadingReplies = false }

        do {
            let page = try await service.comments(videoID: videoID, instance: instance, continuation: continuation)
            guard !Task.isCancelled else { return }
            var ids = Set(replies.map(\.id))
            replies.append(contentsOf: page.comments.filter { ids.insert($0.id).inserted })
            hasLoadedReplies = true
            loadedReplyTokens.insert(continuation)
            repliesContinuation = page.continuation.flatMap {
                $0.isEmpty || loadedReplyTokens.contains($0) ? nil : $0
            }
        } catch {
            guard !Task.isCancelled else { return }
            replyError = error.localizedDescription
            LoggingService.shared.warning("Failed to load comment replies", category: .api, details: error.localizedDescription)
        }
    }
}
