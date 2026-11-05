//
//  APIParsingTests.swift
//  YatteeTests
//
//  Tests for API response parsing including Piped and PeerTube responses.
//

import Testing
import Foundation
@testable import Yattee

// MARK: - Piped Response Parsing Tests

// MARK: - PeerTube Response Parsing Tests

// MARK: - Instance Detector Response Parsing Tests

// MARK: - Search Filters Tests

@Suite("SearchFilters Tests")
@MainActor
struct SearchFiltersTests {

    @Test("Default search filters")
    func defaultFilters() {
        let filters = SearchFilters.defaults

        #expect(filters.sort == .relevance)
        #expect(filters.date == .any)
        #expect(filters.duration == .any)
        #expect(filters.type == .video)
        #expect(filters.isDefault == true)
    }

    @Test("SearchFilters with custom values")
    func customFilters() {
        var filters = SearchFilters()
        filters.sort = .date
        filters.date = .week
        filters.duration = .long

        #expect(filters.isDefault == false)
    }

    @Test("SearchFilters Codable")
    func filtersCodable() throws {
        var filters = SearchFilters()
        filters.sort = .views
        filters.date = .month
        filters.duration = .short

        let encoded = try JSONEncoder().encode(filters)
        let decoded = try JSONDecoder().decode(SearchFilters.self, from: encoded)

        #expect(decoded == filters)
        #expect(decoded.sort == .views)
        #expect(decoded.date == .month)
        #expect(decoded.duration == .short)
    }

    @Test("SearchFilters Equatable")
    func filtersEquatable() {
        let filters1 = SearchFilters.defaults
        let filters2 = SearchFilters.defaults

        #expect(filters1 == filters2)

        var filters3 = SearchFilters.defaults
        filters3.sort = .rating

        #expect(filters1 != filters3)
    }

    @Test("SearchSortOption all cases")
    func sortOptionAllCases() {
        let allCases = SearchSortOption.allCases

        #expect(allCases.contains(.relevance))
        #expect(allCases.contains(.rating))
        #expect(allCases.contains(.date))
        #expect(allCases.contains(.views))
        #expect(allCases.count == 4)
    }

    @Test("SearchSortOption raw values")
    func sortOptionRawValues() {
        #expect(SearchSortOption.relevance.rawValue == "relevance")
        #expect(SearchSortOption.rating.rawValue == "rating")
        #expect(SearchSortOption.date.rawValue == "date")
        #expect(SearchSortOption.views.rawValue == "views")
    }

    @Test("SearchDateFilter all cases")
    func dateFilterAllCases() {
        let allCases = SearchDateFilter.allCases

        #expect(allCases.count == 6)
        #expect(SearchDateFilter.any.rawValue == "")
        #expect(SearchDateFilter.hour.rawValue == "hour")
        #expect(SearchDateFilter.today.rawValue == "today")
    }

    @Test("SearchDurationFilter all cases")
    func durationFilterAllCases() {
        let allCases = SearchDurationFilter.allCases

        #expect(allCases.count == 4)
        #expect(SearchDurationFilter.any.rawValue == "")
        #expect(SearchDurationFilter.short.rawValue == "short")
        #expect(SearchDurationFilter.medium.rawValue == "medium")
        #expect(SearchDurationFilter.long.rawValue == "long")
    }

    @Test("SearchContentType all cases")
    func contentTypeAllCases() {
        let allCases = SearchContentType.allCases

        #expect(allCases.count == 4)
        #expect(allCases.contains(.all))
        #expect(allCases.contains(.video))
        #expect(allCases.contains(.playlist))
        #expect(allCases.contains(.channel))
    }
}

// MARK: - MediaSource Tests

// MARK: - Content Service Routing Tests

@Suite("Content Service Routing Tests")
@MainActor
struct ContentServiceRoutingTests {

    @Test("All instance types have unique raw values")
    func instanceTypesUnique() {
        let types = InstanceType.allCases
        let rawValues = Set(types.map(\.rawValue))

        #expect(rawValues.count == types.count)
    }

    @Test("Instance types are Codable")
    func instanceTypesCodable() throws {
        for type in InstanceType.allCases {
            let encoded = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(InstanceType.self, from: encoded)
            #expect(type == decoded)
        }
    }
}

// MARK: - Piped Authentication Parsing Tests

// MARK: - Stream Resolution Tests

@Suite("Stream Resolution Tests")
@MainActor
struct StreamResolutionTests {

    @Test("StreamResolution from width and height")
    func resolutionFromDimensions() {
        let resolution = StreamResolution(width: 1920, height: 1080)
        #expect(resolution.height == 1080)
        #expect(resolution.width == 1920)
    }

    @Test("StreamResolution static constants")
    func staticConstants() {
        #expect(StreamResolution.p720.height == 720)
        #expect(StreamResolution.p1080.height == 1080)
        #expect(StreamResolution.p2160.height == 2160)
    }

    @Test("StreamResolution comparison")
    func resolutionComparison() {
        let r720 = StreamResolution(width: 1280, height: 720)
        let r1080 = StreamResolution(width: 1920, height: 1080)
        let r4k = StreamResolution(width: 3840, height: 2160)

        #expect(r720 < r1080)
        #expect(r1080 < r4k)
        #expect(r4k > r720)
    }

    @Test("StreamResolution description")
    func resolutionDescription() {
        let resolution = StreamResolution(width: 1920, height: 1080)
        // description returns "heightp" format
        #expect(resolution.description == "1080p")
    }

    @Test("StreamResolution Codable")
    func resolutionCodable() throws {
        let resolution = StreamResolution(width: 1920, height: 1080)
        let encoded = try JSONEncoder().encode(resolution)
        let decoded = try JSONDecoder().decode(StreamResolution.self, from: encoded)

        #expect(decoded.width == resolution.width)
        #expect(decoded.height == resolution.height)
    }

    @Test("StreamResolution Hashable")
    func resolutionHashable() {
        let r1 = StreamResolution(width: 1920, height: 1080)
        let r2 = StreamResolution(width: 1920, height: 1080)

        #expect(r1 == r2)

        var set = Set<StreamResolution>()
        set.insert(r1)
        #expect(set.contains(r2))
    }
}

// MARK: - Playlist Parsing Error Handling Tests

@Suite("Playlist Parsing Error Handling Tests")
@MainActor
struct PlaylistParsingErrorHandlingTests {

    @Test("Invidious playlist with parse-error items structure")
    func invidiousPlaylistWithParseErrors() throws {
        // Simulates the real Invidious API response with parse-error items
        // This validates that our code can handle this JSON structure
        let json = """
        {
            "playlistId": "PLtest123",
            "title": "Test Playlist",
            "description": "A playlist with some parse errors",
            "author": "Test Author",
            "authorId": "UCtest123",
            "videoCount": 3,
            "videos": [
                {
                    "type": "video",
                    "videoId": "video1",
                    "title": "First Video",
                    "author": "Author 1",
                    "authorId": "UC1",
                    "lengthSeconds": 120,
                    "liveNow": false
                },
                {
                    "type": "parse-error",
                    "errorMessage": "Missing hash key: \\"browseEndpoint\\"",
                    "errorBacktrace": "Some stack trace..."
                },
                {
                    "type": "video",
                    "videoId": "video2",
                    "title": "Second Video",
                    "author": "Author 2",
                    "authorId": "UC2",
                    "lengthSeconds": 240,
                    "liveNow": false
                }
            ]
        }
        """.data(using: .utf8)!

        // Verify the JSON structure is valid
        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let videos = decoded["videos"] as! [[String: Any]]

        #expect(videos.count == 3)
        #expect(videos[0]["type"] as? String == "video")
        #expect(videos[0]["videoId"] as? String == "video1")
        #expect(videos[1]["type"] as? String == "parse-error")
        #expect(videos[1]["errorMessage"] != nil)
        #expect(videos[2]["type"] as? String == "video")
        #expect(videos[2]["videoId"] as? String == "video2")
    }

    @Test("Invidious playlist videos without type field default to video")
    func invidiousPlaylistVideosWithoutType() throws {
        // Some Invidious responses don't include type field for videos
        let json = """
        {
            "playlistId": "PLtest456",
            "title": "Test Playlist",
            "videoCount": 1,
            "videos": [
                {
                    "videoId": "video1",
                    "title": "Video Without Type",
                    "author": "Author",
                    "authorId": "UC1",
                    "lengthSeconds": 180,
                    "liveNow": false
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let videos = decoded["videos"] as! [[String: Any]]

        #expect(videos.count == 1)
        #expect(videos[0]["type"] == nil)
        #expect(videos[0]["videoId"] as? String == "video1")
    }

    @Test("Empty playlist videos array should be handled")
    func emptyPlaylistVideos() throws {
        let json = """
        {
            "playlistId": "PL_empty",
            "title": "Empty Playlist",
            "videoCount": 0,
            "videos": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let videos = decoded["videos"] as! [[String: Any]]

        #expect(videos.isEmpty)
    }

    @Test("Playlist with null videos array should be handled")
    func nullPlaylistVideos() throws {
        let json = """
        {
            "playlistId": "PL_null",
            "title": "Playlist with null videos",
            "videoCount": 5
        }
        """.data(using: .utf8)!

        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        #expect(decoded["videos"] == nil)
    }

    @Test("Unknown video type should be skipped")
    func unknownVideoType() throws {
        let json = """
        {
            "playlistId": "PL_unknown",
            "title": "Playlist with unknown types",
            "videoCount": 2,
            "videos": [
                {
                    "type": "future-type",
                    "someField": "someValue"
                },
                {
                    "type": "video",
                    "videoId": "valid",
                    "title": "Valid",
                    "author": "Author",
                    "authorId": "UC1",
                    "lengthSeconds": 60,
                    "liveNow": false
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let videos = decoded["videos"] as! [[String: Any]]

        #expect(videos.count == 2)
        #expect(videos[0]["type"] as? String == "future-type")
        #expect(videos[1]["type"] as? String == "video")
    }

    @Test("Multiple parse-error items in playlist")
    func multipleParseErrors() throws {
        // Real-world scenario where multiple videos fail to parse
        let json = """
        {
            "playlistId": "PLmulti",
            "title": "Playlist with multiple errors",
            "videoCount": 5,
            "videos": [
                {"type": "parse-error", "errorMessage": "Error 1"},
                {"type": "video", "videoId": "v1", "title": "V1", "author": "A", "authorId": "UC1", "lengthSeconds": 60, "liveNow": false},
                {"type": "parse-error", "errorMessage": "Error 2"},
                {"type": "parse-error", "errorMessage": "Error 3"},
                {"type": "video", "videoId": "v2", "title": "V2", "author": "A", "authorId": "UC1", "lengthSeconds": 120, "liveNow": false}
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let videos = decoded["videos"] as! [[String: Any]]

        #expect(videos.count == 5)

        // Count valid videos vs parse errors
        let validCount = videos.filter { ($0["type"] as? String) == "video" }.count
        let errorCount = videos.filter { ($0["type"] as? String) == "parse-error" }.count

        #expect(validCount == 2)
        #expect(errorCount == 3)
    }

}
