//
//  CommentsViewModel.swift
//  Yattee
//
//  Loads sorted comments and continuation pages for a single comments sheet.
//

import Foundation
import Observation

@MainActor
@Observable
final class CommentsViewModel {
    typealias FetchPage = @Sendable (String?, CommentSort) async throws -> CommentsPage

    private(set) var comments: [Comment] = []
    private(set) var state: CommentsLoadState = .idle
    private(set) var continuation: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private var fetchPage: FetchPage?
    @ObservationIgnored private var sort: CommentSort = .top
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var loadedContinuations: Set<String> = []

    // MARK: - Loading

    func load(sort: CommentSort, fetchPage: @escaping FetchPage) async {
        let requestID = UUID()
        self.requestID = requestID
        self.sort = sort
        self.fetchPage = fetchPage
        comments = []
        continuation = nil
        loadedContinuations = []
        errorMessage = nil
        state = .loading

        do {
            let page = try await fetchPage(nil, sort)
            guard self.requestID == requestID, !Task.isCancelled else { return }
            append(page)
            state = .loaded
        } catch {
            guard self.requestID == requestID, !Task.isCancelled else { return }
            state = (error as? APIError) == .commentsDisabled ? .disabled : .error
            errorMessage = error.localizedDescription
            LoggingService.shared.warning("Failed to load comments", category: .api, details: error.localizedDescription)
        }
    }

    func loadMore() async {
        guard state == .loaded || state == .error,
              let continuation, let fetchPage else { return }
        let requestID = self.requestID
        state = .loadingMore
        errorMessage = nil

        do {
            let page = try await fetchPage(continuation, sort)
            guard self.requestID == requestID else { return }
            guard !Task.isCancelled else {
                state = .loaded
                return
            }
            loadedContinuations.insert(continuation)
            append(page)
            state = .loaded
        } catch {
            guard self.requestID == requestID else { return }
            guard !Task.isCancelled else {
                state = .loaded
                return
            }
            state = .error
            errorMessage = error.localizedDescription
            LoggingService.shared.warning("Failed to load more comments", category: .api, details: error.localizedDescription)
        }
    }

    // MARK: - Pagination

    private func append(_ page: CommentsPage) {
        var ids = Set(comments.map(\.id))
        comments.append(contentsOf: page.comments.filter { ids.insert($0.id).inserted })
        // Some instances repeat the last token or return an empty token at the end.
        continuation = page.continuation.flatMap {
            $0.isEmpty || loadedContinuations.contains($0) ? nil : $0
        }
    }
}
