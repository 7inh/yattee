//
//  HomeSuggestionsCache.swift
//  Yattee
//
//  In-memory Home suggestions from recent listening, fetched concurrently per seed.
//

import Foundation
import Observation

@MainActor
@Observable
final class HomeSuggestionsCache {
    static let shared = HomeSuggestionsCache()

    struct Request: Codable, Hashable, Sendable {
        let seedIDs: [String]
        let instance: Instance
    }

    private var cachedRequest: Request?
    private var relatedVideos: [[Video]] = []
    private var lastAttemptedRequest: Request?
    private var errorMessage: String?
    private var loadGeneration = 0

    // MARK: - Seeds and Ordering

    /// History is newest first. The current video is the newest listening seed,
    /// followed by up to five distinct history videos, without fetching it twice.
    nonisolated static func seedIDs(historyIDs: [String], currentVideoID: String?) -> [String] {
        var historySeen = Set<String>()
        let recent = historyIDs.filter { !$0.isEmpty && historySeen.insert($0).inserted }.prefix(5)
        var seen = Set<String>()
        return ([currentVideoID].compactMap { $0 } + recent).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
    }

    /// Take one eligible video per seed per round, preserving each seed's ranking.
    nonisolated static func interleave(_ groups: [[Video]], excluding excludedIDs: Set<String>) -> [Video] {
        var seen = excludedIDs
        var offsets = Array(repeating: 0, count: groups.count)
        var videos: [Video] = []
        while true {
            var addedVideo = false
            for index in groups.indices {
                while offsets[index] < groups[index].count {
                    let video = groups[index][offsets[index]]
                    offsets[index] += 1
                    guard seen.insert(video.id.videoID).inserted else { continue }
                    videos.append(video)
                    addedVideo = true
                    break
                }
            }
            if !addedVideo { return videos }
        }
    }

    // MARK: - Cache

    func videos(for request: Request?, excluding excludedIDs: Set<String>) -> [Video] {
        guard let request, request == cachedRequest else { return [] }
        return Self.interleave(relatedVideos, excluding: excludedIDs)
    }

    func error(for request: Request?) -> String? {
        guard let request, request == lastAttemptedRequest else { return nil }
        return errorMessage
    }

    /// Reuse the last batch until its seeds/instance change or the user refreshes.
    /// Keep unfiltered results so history changes can update exclusions without IO.
    func load(
        request: Request,
        forceRefresh: Bool = false,
        fetchRelatedVideos: @escaping @Sendable (String) async throws -> [Video]
    ) async {
        loadGeneration += 1
        let generation = loadGeneration
        lastAttemptedRequest = request
        errorMessage = nil
        guard forceRefresh || cachedRequest != request else { return }

        let results = await withTaskGroup(of: (Int, [Video]?, String?).self) { group in
            for (index, seedID) in request.seedIDs.enumerated() {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        return (index, try await fetchRelatedVideos(seedID), nil)
                    } catch {
                        guard !Task.isCancelled else { return (index, nil, nil) }
                        LoggingService.shared.warning(
                            "Home suggestions failed for \(seedID): \(error.localizedDescription)",
                            category: .general
                        )
                        return (index, nil, error.localizedDescription)
                    }
                }
            }
            var results = Array<(videos: [Video]?, error: String?)>(
                repeating: (nil, nil), count: request.seedIDs.count
            )
            for await (index, videos, error) in group {
                results[index] = (videos, error)
            }
            return results
        }

        // A cancelled or older request must not replace a newer listening batch.
        guard !Task.isCancelled, generation == loadGeneration else { return }
        if !results.isEmpty, results.allSatisfy({ $0.videos == nil }) {
            // Preserve cached suggestions if a manual refresh fails completely.
            errorMessage = results.compactMap(\.error).first
            return
        }
        relatedVideos = results.map { $0.videos ?? [] }
        cachedRequest = request
    }
}
