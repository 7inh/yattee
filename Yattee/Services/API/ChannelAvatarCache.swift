//
//  ChannelAvatarCache.swift
//  Yattee
//
//  Bounded memory cache for lazy channel avatar lookups, including failures.
//

import Foundation

actor ChannelAvatarCache {
    private struct Key: Hashable, Sendable {
        let channelID: String
        let instanceURL: URL
    }

    private struct Entry: Sendable {
        let result: Result<URL?, Error>
        let expiresAt: Date
    }

    private var entries: [Key: Entry] = [:]
    private var requests: [Key: Task<URL?, Error>] = [:]

    /// Concurrent cards share one request. Scrolling a card offscreen does not
    /// cancel a request that other cards may still need.
    func thumbnailURL(
        channelID: String,
        instanceURL: URL,
        load: @escaping @Sendable () async throws -> URL?
    ) async throws -> URL? {
        guard !channelID.isEmpty else { return nil }
        let key = Key(channelID: channelID, instanceURL: instanceURL)
        if let entry = entries[key], entry.expiresAt > Date() {
            return try entry.result.get()
        }
        if let request = requests[key] {
            return try await request.value
        }

        let request = Task { try await load() }
        requests[key] = request
        let result = await request.result
        requests[key] = nil

        // Missing avatars and failed requests get a short cooldown so each
        // visible card cannot repeatedly hit a failing channel endpoint.
        let lifetime: TimeInterval
        switch result {
        case .success(.some): lifetime = 3600
        default: lifetime = 60
        }
        entries = entries.filter { $0.value.expiresAt > Date() }
        if entries.count >= 500, let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) {
            entries[oldest.key] = nil
        }
        entries[key] = Entry(result: result, expiresAt: Date().addingTimeInterval(lifetime))
        return try result.get()
    }
}
