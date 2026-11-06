//
//  HomeSuggestionsCacheTests.swift
//  Yattee
//
//  Listening seed selection, concurrent recommendations, ordering, and cache lifetime.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Home Listening Suggestions")
@MainActor
struct HomeSuggestionsCacheTests {
    private let instance = Instance(type: .invidious, url: URL(string: "https://invidious.example.com")!)

    private func request(_ seedIDs: [String]) -> HomeSuggestionsCache.Request {
        HomeSuggestionsCache.Request(seedIDs: seedIDs, instance: instance)
    }

    private func videoIDs(_ cache: HomeSuggestionsCache, for request: HomeSuggestionsCache.Request) -> [String] {
        cache.videos(for: request, excluding: []).map { $0.id.videoID }
    }

    @Test("Use five distinct recent history videos plus the current video, once")
    func listeningSeeds() {
        let history = ["one", "one", "two", "three", "four", "five", "six"]
        #expect(HomeSuggestionsCache.seedIDs(historyIDs: history, currentVideoID: "playing")
            == ["playing", "one", "two", "three", "four", "five"])
        #expect(HomeSuggestionsCache.seedIDs(historyIDs: history, currentVideoID: "two")
            == ["two", "one", "three", "four", "five"])
        #expect(HomeSuggestionsCache.seedIDs(historyIDs: [], currentVideoID: nil).isEmpty)
        #expect(HomeSuggestionsCache.seedIDs(historyIDs: [], currentVideoID: "playing") == ["playing"])
    }

    @Test("Interleave eligible results by seed rank, deduplicate, and exhaust uneven lists")
    func interleaving() {
        let groups = [
            ["watched", "new-first", "shared", "new-last"],
            ["playing", "old-first", "shared", "old-last"],
            []
        ].map { $0.map { Video.metadataPlaceholder(for: $0) } }
        let videos = HomeSuggestionsCache.interleave(groups, excluding: ["watched", "playing"])
        #expect(videos.map { $0.id.videoID } == ["new-first", "old-first", "shared", "old-last", "new-last"])
        #expect(HomeSuggestionsCache.interleave([], excluding: []).isEmpty)
    }

    @Test("Fetch seeds concurrently and keep successful batches in seed order", .timeLimit(.minutes(1)))
    func concurrentPartialFailure() async {
        let cache = HomeSuggestionsCache()
        let request = request(["new", "failed", "old"])
        // None can finish before all three start, so sequential fetching cannot pass.
        let fixture = RelatedVideosFixture(
            responses: ["new": ["a", "shared", "c"], "old": ["b", "shared", "d"]],
            failedIDs: ["failed"],
            batchSize: 3
        )
        await cache.load(request: request) { try await fixture.fetch($0) }
        #expect(videoIDs(cache, for: request) == ["a", "b", "shared", "d", "c"])
        #expect(cache.error(for: request) == nil)
        #expect(Set(await fixture.requestedIDs) == ["new", "failed", "old"])
    }

    @Test("Returning to Home reuses suggestions, exclusions stay fresh, and pull-to-refresh fetches again")
    func cacheAndRefresh() async {
        let cache = HomeSuggestionsCache()
        let request = request(["seed"])
        let fixture = RelatedVideosFixture(responses: ["seed": ["a", "b"]])
        await cache.load(request: request) { try await fixture.fetch($0) }
        await cache.load(request: request) { try await fixture.fetch($0) }
        #expect(await fixture.requestedIDs == ["seed"])
        #expect(cache.videos(for: request, excluding: ["a"]).map { $0.id.videoID } == ["b"])

        await cache.load(request: request, forceRefresh: true) { try await fixture.fetch($0) }
        #expect(await fixture.requestedIDs == ["seed", "seed"])
    }

    @Test("An empty history makes no requests and successful empty recommendations are cached")
    func emptyResults() async {
        let cache = HomeSuggestionsCache()
        let fixture = RelatedVideosFixture(responses: [:])
        let empty = request([])
        await cache.load(request: empty) { try await fixture.fetch($0) }
        #expect(await fixture.requestedIDs.isEmpty)
        #expect(videoIDs(cache, for: empty).isEmpty)

        let seeded = request(["seed"])
        await cache.load(request: seeded) { try await fixture.fetch($0) }
        await cache.load(request: seeded) { try await fixture.fetch($0) }
        #expect(await fixture.requestedIDs == ["seed"])
        #expect(videoIDs(cache, for: seeded).isEmpty)
        #expect(cache.error(for: seeded) == nil)
    }

    @Test("A failed refresh preserves suggestions and an uncached failed batch can retry")
    func totalFailure() async {
        let cache = HomeSuggestionsCache()
        let request = request(["seed"])
        await cache.load(request: request) { _ in [Video.metadataPlaceholder(for: "cached")] }
        await cache.load(request: request, forceRefresh: true) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(videoIDs(cache, for: request) == ["cached"])
        #expect(cache.error(for: request) != nil)

        let changed = self.request(["new-seed"])
        await cache.load(request: changed) { _ in throw URLError(.notConnectedToInternet) }
        #expect(videoIDs(cache, for: changed).isEmpty)
        #expect(cache.error(for: changed) != nil)
        await cache.load(request: changed) { _ in [Video.metadataPlaceholder(for: "retried")] }
        #expect(videoIDs(cache, for: changed) == ["retried"])
        #expect(cache.error(for: changed) == nil)
    }

    @Test("Changing the Invidious instance refreshes the batch")
    func instanceChange() async {
        let cache = HomeSuggestionsCache()
        let original = request(["seed"])
        await cache.load(request: original) { _ in [Video.metadataPlaceholder(for: "original")] }
        let changed = HomeSuggestionsCache.Request(
            seedIDs: original.seedIDs,
            instance: Instance(id: instance.id, type: .invidious, url: URL(string: "https://other.example.com")!)
        )
        #expect(videoIDs(cache, for: changed).isEmpty)
        await cache.load(request: changed) { _ in [Video.metadataPlaceholder(for: "changed")] }
        #expect(videoIDs(cache, for: changed) == ["changed"])
    }

    @Test("An older in-flight batch cannot overwrite newer suggestions", .timeLimit(.minutes(1)))
    func supersededRequest() async {
        let cache = HomeSuggestionsCache()
        let original = request(["old"])
        let changed = request(["new"])
        let (started, signalStarted) = AsyncStream<Void>.makeStream()
        let (released, signalRelease) = AsyncStream<Void>.makeStream()
        let oldLoad = Task {
            await cache.load(request: original) { _ in
                signalStarted.yield(())
                signalStarted.finish()
                for await _ in released { break }
                return [Video.metadataPlaceholder(for: "old-result")]
            }
        }
        for await _ in started { break }
        await cache.load(request: changed) { _ in [Video.metadataPlaceholder(for: "new-result")] }
        signalRelease.yield(())
        signalRelease.finish()
        await oldLoad.value
        #expect(videoIDs(cache, for: changed) == ["new-result"])
        #expect(videoIDs(cache, for: original).isEmpty)
    }
}

// MARK: - Concurrent Fetch Fixture

private actor RelatedVideosFixture {
    let responses: [String: [String]]
    let failedIDs: Set<String>
    let batchSize: Int
    private(set) var requestedIDs: [String] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(responses: [String: [String]], failedIDs: Set<String> = [], batchSize: Int = 1) {
        self.responses = responses
        self.failedIDs = failedIDs
        self.batchSize = batchSize
    }

    func fetch(_ seedID: String) async throws -> [Video] {
        requestedIDs.append(seedID)
        if requestedIDs.count < batchSize {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        if failedIDs.contains(seedID) { throw URLError(.notConnectedToInternet) }
        return (responses[seedID] ?? []).map { Video.metadataPlaceholder(for: $0) }
    }
}
