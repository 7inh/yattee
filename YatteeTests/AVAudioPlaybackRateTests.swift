//
//  AVAudioPlaybackRateTests.swift
//  Yattee
//
//  Exercises native M4A speed, pitch configuration and transport persistence.
//

import Foundation
import AVFoundation
import Testing
@testable import Yattee

@Suite("Native audio playback speed", .serialized)
@MainActor
struct AVAudioPlaybackRateTests {
    @Test("Indexed M4A plays above 2x without the HLS adapter", arguments: [PlaybackRate.x25, .x3])
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
        // The native file is playable even if an API also supplies DASH ranges.
        // Those ranges must not force a native rendition through the HLS adapter.
        return Stream(url: url, format: "m4a", isAudioOnly: true, mimeType: "audio/mp4",
                      initRange: "0-722", indexRange: "723-766")
    }
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
