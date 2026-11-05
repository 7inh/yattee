//
//  RemotePlaylistEntryTests.swift
//  YatteeTests
//
//  A remote playlist row has to survive being named: the token that identifies
//  it must come back from parsing intact, and a row the server refuses to name
//  must never look addressable.
//

import Testing
import Foundation
@testable import Yattee

// MARK: - Helpers

private let testBaseURL = URL(string: "https://invidious.example.com")!
private let pipedBaseURL = URL(string: "https://piped.example.com")!

/// Builds one video object of an Invidious authenticated playlist page.
private func invidiousVideoJSON(
    videoId: String,
    title: String,
    index: Int?,
    indexId: String?
) -> String {
    var fields: [String] = [
        "\"type\": \"video\"",
        "\"videoId\": \"\(videoId)\"",
        "\"title\": \"\(title)\"",
        "\"author\": \"Test Channel\"",
        "\"authorId\": \"UCtest\"",
        "\"authorUrl\": \"/channel/UCtest\"",
        "\"lengthSeconds\": 120",
        "\"videoThumbnails\": []"
    ]
    if let index {
        fields.append("\"index\": \(index)")
    }
    if let indexId {
        fields.append("\"indexId\": \"\(indexId)\"")
    }
    return "{\(fields.joined(separator: ", "))}"
}

/// Builds one page of `/api/v1/auth/playlists/{id}`.
private func invidiousPageJSON(
    playlistID: String = "IVPLtest",
    videoCount: Int,
    videos: [String],
    isListed: Bool? = nil
) -> Data {
    let listedField = isListed.map { ",\n        \"isListed\": \($0)" } ?? ""
    return """
    {
        "type": "invidiousPlaylist",
        "title": "Watch Later",
        "playlistId": "\(playlistID)",
        "author": "arek",
        "authorId": "UCowner",
        "description": "A private playlist",
        "videoCount": \(videoCount)\(listedField),
        "videos": [\(videos.joined(separator: ", "))]
    }
    """.data(using: .utf8)!
}

/// Builds one video object of a Piped playlist response.
private func pipedStreamJSON(videoId: String, title: String) -> String {
    """
    {
        "url": "/watch?v=\(videoId)",
        "title": "\(title)",
        "uploaderName": "Test Channel",
        "uploaderUrl": "/channel/UCtest",
        "duration": 120,
        "thumbnail": "https://piped.example.com/thumb.jpg"
    }
    """
}

/// A stream row Piped sent that the app cannot turn into a video — it still
/// occupies a server position, and removals are addressed by that position.
private let pipedMalformedStreamJSON = """
{
    "type": "channel",
    "name": "Not a video at all"
}
"""

/// Builds the first page of `/playlists/{id}`.
private func pipedFirstPageJSON(streams: [String], nextpage: String? = nil) -> Data {
    let nextpageValue = nextpage.map { "\"\($0)\"" } ?? "null"
    return """
    {
        "name": "My Piped Playlist",
        "description": "Playlist description",
        "uploader": "arek",
        "uploaderUrl": "/channel/UCowner",
        "videos": \(streams.count),
        "relatedStreams": [\(streams.joined(separator: ", "))],
        "nextpage": \(nextpageValue)
    }
    """.data(using: .utf8)!
}

/// Builds a `/nextpage/playlists/{id}` page.
private func pipedNextPageJSON(streams: [String], nextpage: String? = nil) -> Data {
    let nextpageValue = nextpage.map { "\"\($0)\"" } ?? "null"
    return """
    {
        "relatedStreams": [\(streams.joined(separator: ", "))],
        "nextpage": \(nextpageValue)
    }
    """.data(using: .utf8)!
}

// MARK: - Invidious

@Suite("Invidious Remote Playlist Snapshot")
struct InvidiousRemotePlaylistSnapshotTests {

    @Test("Every indexed row keeps its indexId and its server position")
    func snapshotRetainsIndexTokens() throws {
        let page = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1"),
            invidiousVideoJSON(videoId: "ccc", title: "Third", index: 2, indexId: "TOKEN2")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.count == 3)
        #expect(snapshot.entries.count == 3)
        #expect(snapshot.entries.map(\.position) == [0, 1, 2])
        #expect(snapshot.entries.map(\.video.id.videoID) == ["aaa", "bbb", "ccc"])
        #expect(snapshot.entries.map(\.id) == [
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN0"),
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN1"),
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN2")
        ])
    }

    @Test("The same video twice is two entries, not one")
    func duplicateVideoYieldsDistinctEntries() throws {
        let page = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "other", title: "Other", index: 1, indexId: "TOKEN1"),
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 2, indexId: "TOKEN2")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.count == 3)
        #expect(snapshot.entries.count == 3)

        let duplicates = snapshot.entries.filter { $0.video.id.videoID == "dup" }
        #expect(duplicates.count == 2)
        #expect(duplicates[0].id != duplicates[1].id)
        #expect(duplicates.map(\.position) == [0, 2])
        // Video hashes by id alone; the entry id is what keeps the two apart.
        #expect(duplicates[0].video == duplicates[1].video)
        #expect(Set(snapshot.entries).count == 3)
    }

    @Test("A row without an indexId is displayed but never addressable")
    func rowWithoutIndexIDIsDisplayOnly() throws {
        let page = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "nameless", title: "Unnamed", index: 1, indexId: nil),
            invidiousVideoJSON(videoId: "ccc", title: "Third", index: 2, indexId: "TOKEN2")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.map(\.id.videoID) == ["aaa", "nameless", "ccc"])
        #expect(snapshot.entries.map(\.video.id.videoID) == ["aaa", "ccc"])
        #expect(snapshot.entries.map(\.position) == [0, 2])
        // The unnamed row is skipped, not squeezed out: the rows that follow it
        // keep the display positions they are actually drawn at.
        #expect(snapshot.entries.map(\.displayRow) == [0, 2])
    }

    @Test("A nameless duplicate never borrows the entry of its twin")
    func namelessDuplicateKeepsItsTwinsEntry() throws {
        // The same video twice, and only the second row has an identity. Pairing
        // rows to entries by video id would hand row 0 the entry that belongs to
        // row 1, so removing the first would delete the second.
        let page = invidiousPageJSON(videoCount: 2, videos: [
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 0, indexId: nil),
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 1, indexId: "TOKEN1")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.map(\.id.videoID) == ["dup", "dup"])
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries[0].id == .invidious(playlistID: "IVPLtest", indexID: "TOKEN1"))
        #expect(snapshot.entries[0].position == 1)
        // The row the server named is row 1, and no entry claims row 0.
        #expect(snapshot.entries[0].displayRow == 1)
        #expect(!snapshot.entries.contains { $0.displayRow == 0 })
    }

    @Test("A row without an index is display-only and sorts last")
    func rowWithoutIndexSortsLast() throws {
        let page = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "floating", title: "Unindexed", index: nil, indexId: "TOKENX"),
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.map(\.id.videoID) == ["aaa", "bbb", "floating"])
        #expect(snapshot.entries.map(\.video.id.videoID) == ["aaa", "bbb"])
    }

    @Test("Overlapping pages collapse by index, keeping the first copy")
    func overlappingPagesDedupeByIndex() throws {
        let firstPage = invidiousPageJSON(videoCount: 4, videos: [
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1"),
            invidiousVideoJSON(videoId: "ccc", title: "Third", index: 2, indexId: "TOKEN2")
        ])
        let secondPage = invidiousPageJSON(videoCount: 4, videos: [
            invidiousVideoJSON(videoId: "ccc", title: "Third", index: 2, indexId: "TOKEN2"),
            invidiousVideoJSON(videoId: "ddd", title: "Fourth", index: 3, indexId: "TOKEN3")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [firstPage, secondPage],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.videos.map(\.id.videoID) == ["aaa", "bbb", "ccc", "ddd"])
        #expect(snapshot.entries.map(\.position) == [0, 1, 2, 3])
        #expect(snapshot.entries.map(\.id) == [
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN0"),
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN1"),
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN2"),
            .invidious(playlistID: "IVPLtest", indexID: "TOKEN3")
        ])
    }

    @Test("Dedupe never collapses a repeated video across pages")
    func dedupeKeepsRepeatedVideoAcrossPages() throws {
        let firstPage = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 0, indexId: "TOKEN0"),
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1")
        ])
        let secondPage = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1"),
            invidiousVideoJSON(videoId: "dup", title: "Duplicated", index: 2, indexId: "TOKEN2")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [firstPage, secondPage],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.entries.count == 3)
        #expect(snapshot.entries.map(\.video.id.videoID) == ["dup", "bbb", "dup"])
        #expect(snapshot.entries.map(\.position) == [0, 1, 2])
    }

    @Test("Out-of-order pages are sorted back into index order")
    func pagesArrivingOutOfOrderAreSorted() throws {
        let firstPage = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "ccc", title: "Third", index: 2, indexId: "TOKEN2"),
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0")
        ])
        let secondPage = invidiousPageJSON(videoCount: 3, videos: [
            invidiousVideoJSON(videoId: "bbb", title: "Second", index: 1, indexId: "TOKEN1")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [firstPage, secondPage],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.entries.map(\.position) == [0, 1, 2])
        #expect(snapshot.playlist.videos.map(\.id.videoID) == ["aaa", "bbb", "ccc"])
    }

    @Test("Playlist metadata comes from the first page")
    func playlistMetadataSurvives() throws {
        let page = invidiousPageJSON(videoCount: 1, videos: [
            invidiousVideoJSON(videoId: "aaa", title: "First", index: 0, indexId: "TOKEN0")
        ])

        let snapshot = try InvidiousAPI.authPlaylistSnapshot(
            fromPageJSON: [page],
            playlistID: "IVPLtest",
            baseURL: testBaseURL
        )

        #expect(snapshot.playlist.title == "Watch Later")
        #expect(snapshot.playlist.description == "A private playlist")
        #expect(snapshot.playlist.videoCount == 1)
        #expect(snapshot.playlist.id.playlistID == "IVPLtest")
    }

    @Test("The listed flag is carried through, and its absence is not a no")
    func snapshotCarriesVisibility() throws {
        func snapshot(isListed: Bool?) throws -> RemotePlaylistSnapshot {
            try InvidiousAPI.authPlaylistSnapshot(
                fromPageJSON: [invidiousPageJSON(videoCount: 0, videos: [], isListed: isListed)],
                playlistID: "IVPLtest",
                baseURL: testBaseURL
            )
        }

        // `true` is exactly public. `false` is unlisted *or* private — Invidious
        // serialises `privacy.public?` and nothing else — and a page that says
        // nothing leaves the visibility unknown rather than not-listed, which is
        // what stops an edit from sending a guess back.
        #expect(try snapshot(isListed: true).isListed == true)
        #expect(try snapshot(isListed: false).isListed == false)
        #expect(try snapshot(isListed: nil).isListed == nil)
    }

    @Test("An empty page set is a decoding failure, not an empty playlist")
    func emptyPageSetThrows() {
        #expect(throws: APIError.self) {
            try InvidiousAPI.authPlaylistSnapshot(
                fromPageJSON: [],
                playlistID: "IVPLtest",
                baseURL: testBaseURL
            )
        }
    }
}

// MARK: - Piped

// MARK: - Entry identity

@Suite("Remote Playlist Entry ID")
struct RemotePlaylistEntryIDTests {

    @Test("The same indexId in two playlists is two different entries")
    func indexIDsDoNotCollideAcrossPlaylists() {
        let left = RemotePlaylistEntryID.invidious(playlistID: "one", indexID: "TOKEN")
        let right = RemotePlaylistEntryID.invidious(playlistID: "two", indexID: "TOKEN")

        #expect(left != right)
        #expect(Set([left, right]).count == 2)
    }

    @Test("Entries differing only by identity stay distinct")
    func entriesWithSameVideoStayDistinct() {
        let video = Video(
            id: .global("aaa"),
            title: "Same video",
            description: nil,
            author: Author(id: "UCtest", name: "Test Channel"),
            duration: 120,
            publishedAt: nil,
            publishedText: nil,
            viewCount: nil,
            likeCount: nil,
            thumbnails: [],
            isLive: false,
            isUpcoming: false,
            scheduledStartTime: nil
        )

        let first = RemotePlaylistEntry(
            id: .invidious(playlistID: "one", indexID: "TOKEN0"),
            video: video,
            position: 0,
            displayRow: 0
        )
        let second = RemotePlaylistEntry(
            id: .invidious(playlistID: "one", indexID: "TOKEN2"),
            video: video,
            position: 2,
            displayRow: 2
        )

        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }
}
