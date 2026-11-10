//
//  AudioTrackOptionsTests.swift
//  YatteeTests
//
//  Covers multi-voice videos: original vs dubbed vs AI (auto) dubbed tracks.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Audio track options")
struct AudioTrackOptionsTests {
    private func track(_ lang: String, _ kind: AudioTrackKind?, bitrate: Int = 128_000) -> Yattee.Stream {
        Yattee.Stream(url: URL(string: "https://example.com/videoplayback?itag=140&lang=\(lang)&b=\(bitrate)")!,
               format: "m4a", audioCodec: "mp4a", bitrate: bitrate, isAudioOnly: true,
               mimeType: "audio/mp4", audioLanguage: lang, isOriginalAudio: kind == .original,
               audioTrackKind: kind)
    }

    @Test("acont xtag values map to track kinds")
    func parsesAcont() {
        #expect(AudioTrackKind(acont: "original") == .original)
        #expect(AudioTrackKind(acont: "dubbed-auto") == .autoDubbed)
        #expect(AudioTrackKind(acont: "dubbed") == .dubbed)
        #expect(AudioTrackKind(acont: "descriptive") == .descriptive)
        #expect(AudioTrackKind(acont: nil) == nil)
    }

    @Test("One option per voice, original first, best bitrate kept")
    func groupsVoices() {
        let original = track("en", .original)
        let aiLow = track("vi", .autoDubbed, bitrate: 48_000)
        let aiHigh = track("vi", .autoDubbed, bitrate: 128_000)
        let dub = track("fr", .dubbed)
        let options = AudioStreamSelector.trackOptions(from: [aiLow, dub, aiHigh, original])
        #expect(options.count == 3)
        #expect(options.first?.kind == .original)
        #expect(options.first { $0.language == "vi" }?.stream == aiHigh)
    }

    @Test("Single-voice videos without language info have no options")
    func noOptionsWithoutLanguage() {
        let plain = Yattee.Stream(url: URL(string: "https://example.com/a.m4a")!, format: "m4a",
                           audioCodec: "mp4a", isAudioOnly: true)
        #expect(AudioStreamSelector.trackOptions(from: [plain]).isEmpty)
    }

    @Test("Stream refresh keeps the same voice, not just the same language")
    func keepsSameVoice() {
        let human = track("vi", .dubbed)
        let ai = track("vi", .autoDubbed)
        let original = track("en", .original)
        let picked = AudioStreamSelector.select(from: [human, original, ai], sameVoiceAs: ai, preferredLanguage: nil)
        #expect(picked == ai)
        #expect(AudioStreamSelector.select(from: [human, original, ai], sameVoiceAs: nil, preferredLanguage: nil) == original)
    }
}
