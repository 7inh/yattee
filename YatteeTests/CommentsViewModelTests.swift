//
//  CommentsViewModelTests.swift
//  Yattee
//
//  Comments pagination, retries, cancellation, and concurrent sort changes.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Comments loading")
@MainActor
struct CommentsViewModelTests {
    private func comment(_ id: String) -> Yattee.Comment {
        Yattee.Comment(id: id, author: Author(id: "author", name: "@listener"), content: id)
    }

    @Test("Pages keep the selected sort, deduplicate IDs, and stop repeated continuations")
    func pagination() async {
        let first = comment("first")
        let second = comment("second")
        let fixture = CommentsPagesFixture([
            .success(CommentsPage(comments: [first, first], continuation: "next")),
            .success(CommentsPage(comments: [first, second, second], continuation: "next"))
        ])
        let model = CommentsViewModel()
        await model.load(sort: .newest) { try await fixture.fetch($0, sort: $1) }
        await model.loadMore()
        await model.loadMore()

        #expect(model.comments.map(\.id) == ["first", "second"])
        #expect(model.continuation == nil)
        #expect(model.state == .loaded)
        #expect(await fixture.requests == [
            .init(continuation: nil, sort: .newest),
            .init(continuation: "next", sort: .newest)
        ])
    }

    @Test("Pagination failure preserves rows and its token for a successful retry")
    func paginationRetry() async {
        let fixture = CommentsPagesFixture([
            .success(CommentsPage(comments: [comment("first")], continuation: "next")),
            .failure(.timeout),
            .success(CommentsPage(comments: [comment("second")], continuation: nil))
        ])
        let model = CommentsViewModel()
        await model.load(sort: .top) { try await fixture.fetch($0, sort: $1) }
        await model.loadMore()
        #expect(model.state == .error)
        #expect(model.comments.map(\.id) == ["first"])
        #expect(model.continuation == "next")
        #expect(model.errorMessage != nil)

        await model.loadMore()
        #expect(model.state == .loaded)
        #expect(model.comments.map(\.id) == ["first", "second"])
        #expect(model.continuation == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("A late response from the previous sort cannot replace the new sort", .timeLimit(.minutes(1)))
    func staleInitialPage() async {
        let gate = CommentsPageGate()
        let model = CommentsViewModel()
        let oldLoad = Task {
            await model.load(sort: .top) { _, _ in await gate.fetch() }
        }
        await gate.waitUntilStarted()

        let newestPage = CommentsPage(comments: [comment("newest")], continuation: "new-next")
        await model.load(sort: .newest) { _, _ in newestPage }
        await gate.finish(CommentsPage(comments: [comment("old")], continuation: "old-next"))
        await oldLoad.value

        #expect(model.comments.map(\.id) == ["newest"])
        #expect(model.continuation == "new-next")
        #expect(model.state == .loaded)
    }

    @Test("A late continuation page cannot append to a different sort", .timeLimit(.minutes(1)))
    func staleContinuationPage() async {
        let gate = CommentsPageGate()
        let model = CommentsViewModel()
        let topPage = CommentsPage(comments: [comment("top")], continuation: "old-next")
        await model.load(sort: .top) { continuation, _ in
            if continuation == nil { return topPage }
            return await gate.fetch()
        }
        let oldLoad = Task { await model.loadMore() }
        await gate.waitUntilStarted()

        let newestPage = CommentsPage(comments: [comment("newest")], continuation: nil)
        await model.load(sort: .newest) { _, _ in newestPage }
        await gate.finish(CommentsPage(comments: [comment("old")], continuation: "old-next"))
        await oldLoad.value

        #expect(model.comments.map(\.id) == ["newest"])
        #expect(model.continuation == nil)
        #expect(model.state == .loaded)
    }

    @Test("Cancellation leaves pagination ready to load when the footer appears again", .timeLimit(.minutes(1)))
    func cancelledContinuation() async {
        let gate = CommentsPageGate()
        let model = CommentsViewModel()
        let firstPage = CommentsPage(comments: [comment("first")], continuation: "next")
        await model.load(sort: .top) { continuation, _ in
            if continuation == nil { return firstPage }
            return await gate.fetch()
        }
        let load = Task { await model.loadMore() }
        await gate.waitUntilStarted()
        load.cancel()
        await gate.finish(CommentsPage(comments: [comment("cancelled")], continuation: nil))
        await load.value

        #expect(model.state == .loaded)
        #expect(model.comments.map(\.id) == ["first"])
        #expect(model.continuation == "next")
        #expect(model.errorMessage == nil)
    }

    @Test("Disabled comments, empty comments, and recoverable initial errors have separate states")
    func initialStates() async {
        let model = CommentsViewModel()
        await model.load(sort: .top) { _, _ in throw APIError.commentsDisabled }
        #expect(model.state == .disabled)

        await model.load(sort: .top) { _, _ in throw APIError.noConnection }
        #expect(model.state == .error)
        #expect(model.errorMessage != nil)

        await model.load(sort: .top) { _, _ in CommentsPage(comments: [], continuation: "") }
        #expect(model.state == .loaded)
        #expect(model.comments.isEmpty)
        #expect(model.continuation == nil)
        #expect(model.errorMessage == nil)
    }

    @Test("Older serialized comments decode without edited metadata")
    func editedMetadataCompatibility() throws {
        let original = comment("saved")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "isEdited")
        let oldData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(Yattee.Comment.self, from: oldData)
        #expect(decoded.isEdited == nil)

        let edited = Yattee.Comment(id: "edited", author: original.author, content: "Updated", isEdited: true)
        #expect(try JSONDecoder().decode(Yattee.Comment.self, from: JSONEncoder().encode(edited)).isEdited == true)
    }
}

private actor CommentsPagesFixture {
    struct Request: Equatable, Sendable {
        let continuation: String?
        let sort: CommentSort
    }

    private var pages: [Result<CommentsPage, APIError>]
    private(set) var requests: [Request] = []

    init(_ pages: [Result<CommentsPage, APIError>]) {
        self.pages = pages
    }

    func fetch(_ continuation: String?, sort: CommentSort) throws -> CommentsPage {
        requests.append(Request(continuation: continuation, sort: sort))
        guard !pages.isEmpty else { throw APIError.unknown("Unexpected comments request") }
        return try pages.removeFirst().get()
    }
}

private actor CommentsPageGate {
    private var pending: CheckedContinuation<CommentsPage, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func fetch() async -> CommentsPage {
        await withCheckedContinuation { continuation in
            pending = continuation
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    func waitUntilStarted() async {
        guard pending == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish(_ page: CommentsPage) {
        pending?.resume(returning: page)
        pending = nil
    }
}
