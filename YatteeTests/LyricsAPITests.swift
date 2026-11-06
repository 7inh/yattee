//
//  LyricsAPITests.swift
//  YatteeTests
//
//  Verifies Invidious caption URLs and the parsed-track memory cache.
//

import Foundation
import Testing

@testable import Yattee

@Suite("Lyrics caption API", .serialized)
struct LyricsAPITests {
    private func makeClient() -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LyricsURLProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }

    @Test("Lists captions through the caption endpoint and resolves track URLs")
    func listCaptions() async throws {
        let api = InvidiousAPI(httpClient: makeClient())
        let instance = Instance(type: .invidious, url: URL(string: "https://lyrics.example")!)
        let tracks = try await api.captions(videoID: "list", instance: instance)
        #expect(tracks.count == 2)
        #expect(tracks[0].url.absoluteString == "https://lyrics.example/api/v1/captions/list?label=English")
        #expect(tracks[1].url.absoluteString == "https://external.example/captions.vtt")
        #expect(LyricsURLProtocol.recorder.count(for: URL(string: "https://lyrics.example/api/v1/captions/list")!) == 1)
        let text = try await api.captionText(tracks[0])
        #expect(WebVTTParser.parse(text).map(\.text) == ["English"])
    }

    @Test("Reuses parsed tracks while keeping videos and track choices separate")
    func cacheParsedTracks() async throws {
        let content = ContentService(httpClient: makeClient())
        let instance = Instance(type: .invidious, url: URL(string: "https://lyrics.example")!)
        let english = Caption(label: "English", languageCode: "en", url: URL(string: "https://lyrics.example/api/v1/captions/cache?label=English")!)
        let french = Caption(label: "French", languageCode: "fr", url: URL(string: "https://lyrics.example/api/v1/captions/cache?label=French")!)
        let first = try await content.lyrics(videoID: "video-a", caption: english, instance: instance)
        let cached = try await content.lyrics(videoID: "video-a", caption: english, instance: instance)
        #expect(cached == first)
        #expect(LyricsURLProtocol.recorder.count(for: english.url) == 1)

        let otherTrack = try await content.lyrics(videoID: "video-a", caption: french, instance: instance)
        #expect(otherTrack.map(\.text) == ["French"])
        #expect(LyricsURLProtocol.recorder.count(for: french.url) == 1)

        _ = try await content.lyrics(videoID: "video-b", caption: english, instance: instance)
        #expect(LyricsURLProtocol.recorder.count(for: english.url) == 2)
    }
}

private final class LyricsRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func record(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    func count(for url: URL) -> Int {
        lock.withLock { urls.filter { $0 == url }.count }
    }
}

private final class LyricsURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = LyricsRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "lyrics.example" || request.url?.host == "external.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.recorder.record(url)
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let label = components?.queryItems?.first(where: { $0.name == "label" })?.value
        let isList = url.path == "/api/v1/captions/list" && label == nil
        let text: String
        if isList {
            text = """
            {"captions":[
                {"label":"English","languageCode":"en","url":"/api/v1/captions/list?label=English"},
                {"label":"French","languageCode":"fr","url":"https://external.example/captions.vtt"},
                {"label":"Invalid","languageCode":"xx","url":"javascript:invalid"}
            ]}
            """
        } else {
            text = "WEBVTT\n\n00:00.000 --> 00:02.000\n\(label ?? "External")"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": isList ? "application/json" : "text/vtt"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
