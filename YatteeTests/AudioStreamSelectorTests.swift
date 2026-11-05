//
//  AudioStreamSelectorTests.swift
//  YatteeTests
//
//  Guards audio-only playback against video and unsupported container fallbacks.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Audio stream selection")
struct AudioStreamSelectorTests {
    @Test("AAC wins over higher bitrate Opus, including when codec metadata is missing")
    func selectsAAC() {
        let aac = Stream(url: URL(string: "https://example.com/audio?itag=140")!,
                         format: "unknown", bitrate: 128_000, isAudioOnly: true,
                         mimeType: "audio/mp4; codecs=\"mp4a.40.2\"")
        let opus = Stream(url: URL(string: "https://example.com/audio.webm")!,
                          format: "webm", bitrate: 256_000, isAudioOnly: true,
                          mimeType: "audio/webm")
        #expect(AudioStreamSelector.select(from: [opus, aac]) == aac)
        #expect(!opus.isNativelyPlayable)
    }

    @Test("Video, relabeled muxed files, masters, DASH and Opus never become fallbacks")
    func rejectsVideoAndUnsupportedAudio() {
        let muxed = Stream.preview
        let opus = Stream(url: URL(string: "https://example.com/audio.m4a")!,
                          format: "m4a", audioCodec: "opus", isAudioOnly: true)
        let dash = Stream(url: URL(string: "https://example.com/audio.mpd")!,
                          format: "dash", audioCodec: "aac", isAudioOnly: true)
        let streams = [muxed, muxed.audioOnlyVariant(), .videoOnlyPreview, .hlsPreview, opus, dash]
        #expect(streams.allSatisfy { !$0.isAVPlayerAudioPlayable })
        #expect(AudioStreamSelector.select(from: streams) == nil)
        #expect(AudioStreamSelector.select(from: []) == nil)
    }

    @Test("Only explicitly audio-only HLS is accepted")
    func acceptsAudioHLS() {
        let audio = Stream(url: URL(string: "https://example.com/audio.m3u8")!,
                           format: "hls", isAudioOnly: true, isLive: true,
                           mimeType: "application/vnd.apple.mpegurl")
        #expect(AudioStreamSelector.select(from: [.hlsPreview, audio]) == audio)
        #expect(AudioStreamSelector.select(from: [audio, .audioPreview]) == .audioPreview)
    }

    @Test("Language and original-track preferences apply only to playable audio")
    func honorsLanguageAndOriginal() {
        let english = Stream.audioPreview
        let spanish = Stream(url: URL(string: "https://example.com/spanish.m4a")!,
                             format: "m4a", audioCodec: "aac", bitrate: 192_000,
                             isAudioOnly: true, audioLanguage: "es")
        let unsupportedSpanish = Stream(url: URL(string: "https://example.com/spanish.webm")!,
                                        format: "webm", audioCodec: "opus", bitrate: 256_000,
                                        isAudioOnly: true, audioLanguage: "es")
        let streams = [unsupportedSpanish, spanish, english]
        #expect(AudioStreamSelector.select(from: streams) == english)
        #expect(AudioStreamSelector.select(from: streams, preferredLanguage: "es") == spanish)
        #expect(AudioStreamSelector.select(from: [unsupportedSpanish, english], preferredLanguage: "es") == english)
    }

    @Test("Highest bitrate is preferred within the same supported format and language")
    func honorsBitrate() {
        let low = Stream(url: URL(string: "https://example.com/low.m4a")!, format: "m4a",
                         bitrate: 64_000, isAudioOnly: true)
        let high = Stream(url: URL(string: "https://example.com/high.m4a")!, format: "m4a",
                          bitrate: 128_000, isAudioOnly: true)
        #expect(AudioStreamSelector.select(from: [low, high]) == high)
    }
}

@Suite("Audio download selection")
struct AudioDownloadSelectionTests {
    @Test("Itag 140 m4a is preferred over a higher bitrate rendition")
    func prefers140() {
        let standard = Stream(url: URL(string: "https://example.com/audio?itag=140")!, format: "m4a",
                              bitrate: 128_000, isAudioOnly: true)
        let high = Stream(url: URL(string: "https://example.com/audio?itag=141")!, format: "m4a",
                          bitrate: 256_000, isAudioOnly: true)
        #expect(AudioStreamSelector.downloadStream(from: [high, standard]) == standard)
    }

    @Test("Downloads reject video, HLS, raw AAC and Opus")
    func rejectsNonM4A() {
        let hls = Stream(url: URL(string: "https://example.com/audio.m3u8")!, format: "hls",
                         audioCodec: "aac", isAudioOnly: true, mimeType: "application/vnd.apple.mpegurl")
        let aac = Stream(url: URL(string: "https://example.com/audio.aac")!, format: "aac", isAudioOnly: true)
        let opus = Stream(url: URL(string: "https://example.com/audio.webm")!, format: "webm",
                          audioCodec: "opus", isAudioOnly: true)
        #expect(AudioStreamSelector.downloadStream(from: [.preview, .videoOnlyPreview, hls, aac, opus]) == nil)
    }
}
