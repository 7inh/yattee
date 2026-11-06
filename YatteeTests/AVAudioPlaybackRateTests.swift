//
//  AVAudioPlaybackRateTests.swift
//  Yattee
//
//  Exercises remote DASH adaptation, native audio speed and transport persistence.
//

import Foundation
import AVFoundation
import Testing
@testable import Yattee

@Suite("Audio asset selection and playback speed", .serialized)
@MainActor
struct AVAudioPlaybackRateTests {
    @Test("Local M4A preserves every speed without the HLS adapter", arguments: PlaybackRate.allCases)
    func highSpeedPlayback(rate: PlaybackRate) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try makeAudio(in: directory, name: "first")
        let second = try makeAudio(in: directory, name: "second")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedAudioIndexRequest.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let player = AVPlayer()
        player.isMuted = true
        let backend = AVAudioBackend(player: player, dashPlaylistLoader: DASHAudioPlaylistLoader(session: session))
        defer { backend.stop() }

        // Choose a speed before loading, just as PlayerService does on track changes.
        backend.rate = Float(rate.rawValue)
        try await backend.load(stream: first, audioStream: nil, autoplay: false)
        #expect((player.currentItem?.asset as? AVURLAsset)?.url == first.url)
        #expect(player.currentItem?.audioTimePitchAlgorithm == .spectral)
        #expect(player.rate == 0)
        #expect(player.defaultRate == Float(rate.rawValue))

        backend.play()
        try await expectActiveRate(rate, player: player)

        // Changing speed while paused must retain the selection without starting audio.
        backend.pause()
        backend.rate = 1
        backend.rate = Float(rate.rawValue)
        #expect(player.rate == 0)
        backend.play()
        try await expectActiveRate(rate, player: player)

        // Loading another item must preserve both the speed and pitch correction.
        try await backend.load(stream: second, audioStream: nil, autoplay: false)
        #expect((player.currentItem?.asset as? AVURLAsset)?.url == second.url)
        #expect(player.currentItem?.audioTimePitchAlgorithm == .spectral)
        #expect(backend.rate == Float(rate.rawValue))
        #expect(player.defaultRate == Float(rate.rawValue))
        #expect(player.rate == 0)
        await backend.seek(to: 10, showLoading: false)
        #expect(abs(player.currentTime().seconds - 10) < 0.1)
        #expect(player.rate == 0)
        backend.play()
        try await expectActiveRate(rate, player: player)
    }

    @Test("Remote indexed M4A uses HLS at every speed, including through a proxy", arguments: PlaybackRate.allCases)
    func remoteDASHUsesHLS(rate: PlaybackRate) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioIndexResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let backend = AVAudioBackend(dashPlaylistLoader: DASHAudioPlaylistLoader(session: session))
        defer { backend.stop() }
        backend.rate = Float(rate.rawValue)

        // The proxy URL has no extension; API format/ranges identify the asset
        // even when MIME metadata is missing or generic. Never probe it natively.
        for mimeType: String? in [nil, "application/octet-stream", "audio/mp4; codecs=\"mp4a.40.2\""] {
            let stream = Yattee.Stream(url: URL(string: "https://audio.invalid/proxy/videoplayback?itag=140")!,
                                       format: "m4a", isAudioOnly: true, mimeType: mimeType,
                                       httpHeaders: ["X-Audio-Test": "index"],
                                       initRange: "0-722", indexRange: "723-766")
            let asset = try await backend.makeAudioAsset(for: stream)
            #expect(asset.url.scheme == "yattee-audio")
            #expect(asset.url.pathExtension == "m3u8")
            #expect(asset.resourceLoader.delegate != nil)
        }
    }

    @Test("A rejected DASH range fails instead of retrying the broken native path")
    func rejectedDASHRangeFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AudioIndexResponse.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let player = AVPlayer()
        let backend = AVAudioBackend(player: player, dashPlaylistLoader: DASHAudioPlaylistLoader(session: session))
        defer { backend.stop() }
        let stream = Yattee.Stream(url: URL(string: "https://audio.invalid/reject-range")!,
                                   format: "m4a", isAudioOnly: true, mimeType: "audio/mp4",
                                   initRange: "0-722", indexRange: "723-766")

        await #expect(throws: BackendError.loadFailed(DASHAudioError.invalidResponse.localizedDescription)) {
            try await backend.load(stream: stream, audioStream: nil, autoplay: false)
        }
        #expect(player.currentItem == nil)
    }

    private func expectActiveRate(_ rate: PlaybackRate, player: AVPlayer) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if player.timeControlStatus == .playing,
               let timebase = player.currentItem?.timebase,
               abs(CMTimebaseGetRate(timebase) - rate.rawValue) < 0.01 {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(player.timeControlStatus == .playing)
        let item = try #require(player.currentItem)
        let timebase = try #require(item.timebase)
        // AVPlayer.rate expresses intent. The item's timebase reports the active rate.
        #expect(abs(CMTimebaseGetRate(timebase) - rate.rawValue) < 0.01)
    }

    private func makeAudio(in directory: URL, name: String) throws -> Yattee.Stream {
        let url = directory.appendingPathComponent("\(name).m4a")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 720_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 24_000)) * 0.1
            }
            try file.write(from: buffer)
        }
        // Downloaded files may retain API DASH ranges. Local M4A must stay native.
        return Stream(url: url, format: "m4a", isAudioOnly: true, mimeType: "audio/mp4",
                      initRange: "0-722", indexRange: "723-766")
    }
}

private final class AudioIndexResponse: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let rejectsRange = url.path == "/reject-range"
        if !rejectsRange {
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=723-766")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            #expect(request.value(forHTTPHeaderField: "X-Audio-Test") == "index")
        }
        // A single sidx reference: 100 bytes of media, lasting one second.
        let words: [UInt32] = [44, 0x73696478, 0, 1, 1_000, 0, 0, 1, 100, 1_000, 0x90000000]
        let data = Data(words.flatMap { word in
            [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> $0) }
        })
        let response = HTTPURLResponse(url: url, statusCode: rejectsRange ? 200 : 206,
                                       httpVersion: "HTTP/1.1", headerFields: [
                                           "Content-Range": "bytes 723-766/867",
                                           "Content-Length": "44"
                                       ])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class UnexpectedAudioIndexRequest: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Issue.record("A playable native M4A must not fetch a DASH index or become HLS.")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}
