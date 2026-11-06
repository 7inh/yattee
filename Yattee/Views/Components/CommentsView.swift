//
//  CommentsView.swift
//  Yattee
//
//  Shared comments sheet with sorting, inline replies, and infinite scrolling.
//

import Foundation
import SwiftUI

@MainActor
struct CommentsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss

    let video: Video
    var onShowDetails: (() -> Void)?

    @State private var model = CommentsViewModel()
    @State private var sort: CommentSort = .top
    @State private var retryID = UUID()
    @State private var instance: Instance?

    private struct LoadRequest: Equatable, Sendable {
        let videoID: VideoID
        let sort: CommentSort
        let retryID: UUID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sortChips

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.comments) { comment in
                        CommentView(
                            comment: comment,
                            videoID: video.id.videoID,
                            source: video.id.source,
                            instance: instance
                        )
                    }

                    if model.comments.isEmpty {
                        statusView
                    }

                    paginationFooter
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .id(sort)
        }
        .background(Color(.systemBackground))
        .foregroundStyle(.primary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: LoadRequest(videoID: video.id, sort: sort, retryID: retryID)) {
            let service = appEnvironment?.contentService
            let instance = appEnvironment?.instancesManager.instance(for: video)
            self.instance = instance
            let videoID = video.id.videoID
            await model.load(sort: sort) { continuation, sort in
                guard let service, let instance else { throw APIError.noInstance }
                return try await service.comments(videoID: videoID, instance: instance, continuation: continuation, sort: sort)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(String(localized: "videoInfo.section.comments"))
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let onShowDetails {
                Button(action: onShowDetails) {
                    Image(systemName: "info.circle")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Show details")
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close comments")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .padding(.bottom, 16)
    }

    private var sortChips: some View {
        HStack(spacing: 10) {
            ForEach(CommentSort.allCases, id: \.self) { option in
                Button { sort = option } label: {
                    Text(option.title)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .foregroundStyle(sort == option ? Color(.systemBackground) : .primary)
                        .background(sort == option ? Color.primary : Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sort == option ? .isSelected : [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    // MARK: - Loading States

    @ViewBuilder
    private var statusView: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        case .disabled:
            ContentUnavailableView("Comments are turned off", systemImage: "text.bubble")
        case .loaded where model.continuation == nil:
            ContentUnavailableView("No comments yet", systemImage: "text.bubble")
        case .error where model.continuation == nil:
            errorView {
                retryID = UUID()
            }
        default:
            EmptyView()
        }
    }

    private var paginationFooter: some View {
        VStack(spacing: 12) {
            if model.continuation != nil {
                if model.state == .error {
                    errorView { Task { await model.loadMore() } }
                } else {
                    ProgressView()
                        .padding(.vertical, 16)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: model.continuation) {
            await model.loadMore()
        }
    }

    private func errorView(retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(String(localized: "videoInfo.comments.error"))
                .font(.headline)
            if let message = model.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(String(localized: "common.retry"), action: retry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
