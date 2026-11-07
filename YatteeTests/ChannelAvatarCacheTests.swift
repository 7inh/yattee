//
//  ChannelAvatarCacheTests.swift
//  YatteeTests
//
//  Verifies shared avatar requests, negative caching, and instance isolation.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Channel avatar cache")
struct ChannelAvatarCacheTests {
    private let instanceURL = URL(string: "https://invidious.example")!
    private let avatarURL = URL(string: "https://images.example/avatar.jpg")!

    @Test("Concurrent and subsequent cards share one channel lookup")
    func deduplicatesRequests() async throws {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .success(avatarURL))
        let urls = try await withThrowingTaskGroup(of: URL?.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    try await cache.thumbnailURL(channelID: "UCshared", instanceURL: instanceURL) {
                        try await loader.load()
                    }
                }
            }
            var results: [URL?] = []
            for try await url in group { results.append(url) }
            return results
        }
        #expect(urls.count == 20)
        #expect(urls.allSatisfy { $0 == avatarURL })
        let cached = try await cache.thumbnailURL(channelID: "UCshared", instanceURL: instanceURL) {
            try await loader.load()
        }
        #expect(cached == avatarURL)
        #expect(await loader.calls == 1)
    }

    @Test("Missing avatars are cached across cards")
    func cachesMissingAvatars() async throws {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .success(nil))
        for _ in 0..<3 {
            let url = try await cache.thumbnailURL(channelID: "UCmissing", instanceURL: instanceURL) {
                try await loader.load()
            }
            #expect(url == nil)
        }
        #expect(await loader.calls == 1)
    }

    @Test("Failures have a cooldown instead of retrying for each card")
    func cachesFailures() async {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .failure(URLError(.notConnectedToInternet)))
        for _ in 0..<3 {
            await #expect(throws: URLError.self) {
                try await cache.thumbnailURL(channelID: "UCoffline", instanceURL: instanceURL) {
                    try await loader.load()
                }
            }
        }
        #expect(await loader.calls == 1)
    }

    @Test("Channels and instance URLs have separate cache entries")
    func separatesChannelsAndInstances() async throws {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .success(avatarURL))
        for (id, url) in [
            ("UCfirst", instanceURL),
            ("UCsecond", instanceURL),
            ("UCfirst", URL(string: "https://other.example")!)
        ] {
            _ = try await cache.thumbnailURL(channelID: id, instanceURL: url) {
                try await loader.load()
            }
        }
        #expect(await loader.calls == 3)
    }

    @Test("A disappearing card cannot cancel another card's avatar")
    func waiterCancellation() async throws {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .success(avatarURL))
        let first = Task {
            try await cache.thumbnailURL(channelID: "UCshared", instanceURL: instanceURL) {
                try await loader.load()
            }
        }
        while await loader.calls == 0 { await Task.yield() }
        first.cancel()
        let second = try await cache.thumbnailURL(channelID: "UCshared", instanceURL: instanceURL) {
            try await loader.load()
        }
        #expect(second == avatarURL)
        #expect(try await first.value == avatarURL)
        #expect(await loader.calls == 1)
    }

    @Test("Unknown channel IDs do not make requests")
    func skipsEmptyIDs() async throws {
        let cache = ChannelAvatarCache()
        let loader = AvatarTestLoader(result: .success(avatarURL))
        let url = try await cache.thumbnailURL(channelID: "", instanceURL: instanceURL) {
            try await loader.load()
        }
        #expect(url == nil)
        #expect(await loader.calls == 0)
    }
}

private actor AvatarTestLoader {
    private(set) var calls = 0
    private let result: Result<URL?, URLError>

    init(result: Result<URL?, URLError>) {
        self.result = result
    }

    func load() async throws -> URL? {
        calls += 1
        try await Task.sleep(for: .milliseconds(30))
        return try result.get()
    }
}
