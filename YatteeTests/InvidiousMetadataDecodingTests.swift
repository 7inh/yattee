//
//  InvidiousMetadataDecodingTests.swift
//  Yattee
//
//  Optional upload dates and channel avatars must not break Invidious responses.
//

import Foundation
import Testing
@testable import Yattee

/// Serves local JSON through the real HTTPClient and endpoint decoders.
private final class InvidiousMetadataURLProtocol: URLProtocol, @unchecked Sendable {
    // Only the serialized suite below uses this protocol.
    nonisolated(unsafe) static var responseJSON = "{}"

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.responseJSON.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Invidious metadata decoding", .serialized)
struct InvidiousMetadataDecodingTests {
    private let instance = Instance(type: .invidious, url: URL(string: "https://invidious.example.com")!)
    private let timestamp: Int64 = 1_700_000_000

    private func makeAPI() -> InvidiousAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InvidiousMetadataURLProtocol.self]
        return InvidiousAPI(httpClient: HTTPClient(session: URLSession(configuration: configuration)))
    }

    private func videoJSON(id: String = "video", metadata: String = "") -> String {
        """
        {
            "type": "video", "videoId": "\(id)", "title": "Test video",
            "author": "Test channel", "authorId": "UCtest", "lengthSeconds": 120
            \(metadata.isEmpty ? "" : ", \(metadata)")
        }
        """
    }

    @Test("Video details retain recommendations with missing or string published fields")
    func recommendedVideosWithMissingAndStringPublished() async throws {
        let recommendations = [
            videoJSON(id: "missing"),
            videoJSON(id: "numeric-string", metadata: #""published": "1700000000""#),
            videoJSON(id: "relative-string", metadata: #""published": "2 days ago", "publishedText": "2 days ago""#)
        ].joined(separator: ",")
        InvidiousMetadataURLProtocol.responseJSON = videoJSON(metadata: "\"recommendedVideos\": [\(recommendations)]")

        let video = try await makeAPI().video(id: "video", instance: instance)
        let related = try #require(video.relatedVideos)
        #expect(related.map(\.id.videoID) == ["missing", "numeric-string", "relative-string"])
        #expect(related[0].publishedAt == nil)
        #expect(related[1].publishedAt == Date(timeIntervalSince1970: TimeInterval(timestamp)))
        #expect(related[2].publishedAt == nil)
        #expect(related[2].publishedText == "2 days ago")
    }

    @Test("All video endpoints accept numeric timestamp representations", arguments: [
        "1700000000", "1700000000.75", #""1700000000""#, #"" 1700000000.75 ""#
    ])
    func numericTimestamps(value: String) async throws {
        let videos = try await videosAcrossEndpoints(metadata: "\"published\": \(value), \"premiereTimestamp\": \(value)")
        let expected = Date(timeIntervalSince1970: TimeInterval(timestamp))
        for video in videos {
            #expect(video.publishedAt == expected)
        }
        // Auth playlist summaries and recommendations have no scheduled start field.
        #expect(videos.filter { $0.scheduledStartTime == expected }.count == 8)
    }

    @Test("Invalid dates and display text never discard videos", arguments: [
        "null", "true", "[]", "{}", #""2 days ago""#, #""""#, "1e100", #""NaN""#, #""Infinity""#
    ])
    func invalidDates(value: String) async throws {
        let videos = try await videosAcrossEndpoints(metadata: """
            "published": \(value), "premiereTimestamp": \(value), "publishedText": {"unexpected": true}
            """)
        for video in videos {
            #expect(video.publishedAt == nil)
            #expect(video.scheduledStartTime == nil)
            #expect(video.publishedText == nil)
        }
    }

    @Test("Malformed avatars do not fail video or channel decoding", arguments: [
        "null", "true", #""avatar.jpg""#, "{}", "[{}]",
        #"[{"url": 123}]"#, #"[{"url": "/avatar.jpg", "width": "bad"}]"#,
        #"[{"url": "/avatar.jpg"}, {"height": false}]"#
    ])
    func invalidAvatars(value: String) async throws {
        let videos = try await videosAcrossEndpoints(metadata: "\"authorThumbnails\": \(value)")
        for video in videos {
            #expect(video.author.thumbnailURL == nil)
        }

        let api = makeAPI()
        InvidiousMetadataURLProtocol.responseJSON = """
        {"authorId": "UCtest", "author": "Test channel", "authorThumbnails": \(value)}
        """
        let channel = try await api.channel(id: "UCtest", instance: instance)
        #expect(channel.thumbnailURL == nil)

        InvidiousMetadataURLProtocol.responseJSON = """
        [{"type": "channel", "authorId": "UCtest", "author": "Test channel", "authorThumbnails": \(value)}]
        """
        let search = try await api.search(query: "test", instance: instance, page: 1)
        #expect(search.channels.count == 1)
        #expect(search.channels.first?.thumbnailURL == nil)
    }

    @Test("Missing metadata stays absent and valid text and avatars survive")
    func missingAndValidMetadata() async throws {
        for video in try await videosAcrossEndpoints(metadata: "") {
            #expect(video.publishedAt == nil)
            #expect(video.publishedText == nil)
            #expect(video.scheduledStartTime == nil)
            #expect(video.author.thumbnailURL == nil)
        }

        for video in try await videosAcrossEndpoints(metadata: #""publishedText": "2 days ago", "authorThumbnails": [{"url": "/avatar.jpg", "width": 100}]"#) {
            #expect(video.publishedText == "2 days ago")
            #expect(video.author.thumbnailURL == URL(string: "https://invidious.example.com/avatar.jpg"))
        }
    }

    /// Exercise the private response models through each endpoint, including both
    /// feed arrays, playlist representations and parent/child video details.
    private func videosAcrossEndpoints(metadata: String) async throws -> [Video] {
        let api = makeAPI()
        let item = videoJSON(metadata: metadata)
        var videos: [Video] = []

        InvidiousMetadataURLProtocol.responseJSON = "[\(item)]"
        let trending = try await api.trending(instance: instance)
        let popular = try await api.popular(instance: instance)
        let search = try await api.search(query: "test", instance: instance, page: 1)
        #expect(trending.count == 1)
        #expect(popular.count == 1)
        #expect(search.videos.count == 1)
        videos += trending + popular + search.videos

        InvidiousMetadataURLProtocol.responseJSON = "{\"notifications\": [\(item)], \"videos\": [\(item)]}"
        let feed = try await api.feed(instance: instance, sid: "test")
        #expect(feed.videos.count == 2)
        videos += feed.videos

        InvidiousMetadataURLProtocol.responseJSON = "{\"videos\": [\(item)]}"
        let channel = try await api.channelVideos(id: "UCtest", instance: instance, continuation: nil)
        #expect(channel.videos.count == 1)
        videos += channel.videos

        // A zero total avoids fetching additional pages for this single-page fixture.
        let playlistJSON = """
        {"playlistId": "PLtest", "title": "Test playlist", "videoCount": 0, "updated": {}, "videos": [\(item)]}
        """
        InvidiousMetadataURLProtocol.responseJSON = playlistJSON
        let playlist = try await api.playlist(id: "PLtest", instance: instance)
        #expect(playlist.videos.count == 1)
        videos += playlist.videos

        InvidiousMetadataURLProtocol.responseJSON = "[\(playlistJSON)]"
        let authPlaylists = try await api.userPlaylists(instance: instance, sid: "test")
        #expect(authPlaylists.first?.videos.count == 1)
        videos += authPlaylists.flatMap(\.videos)

        InvidiousMetadataURLProtocol.responseJSON = videoJSON(metadata: """
            "recommendedVideos": [\(item)]\(metadata.isEmpty ? "" : ", \(metadata)")
            """)
        let details = try await api.video(id: "video", instance: instance)
        #expect(details.relatedVideos?.count == 1)
        videos += [details] + (details.relatedVideos ?? [])
        #expect(videos.count == 10)
        return videos
    }
}
