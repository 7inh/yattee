//
//  WebVTTParserTests.swift
//  YatteeTests
//
//  Covers lyric timing, WebVTT cleanup, rolling captions, and track preference.
//

import Foundation
import Testing

@testable import Yattee

@Suite("WebVTT lyrics parser")
struct WebVTTParserTests {
    @Test("Parses cue identifiers, settings, hour and minute timestamps")
    func timestampsAndSettings() {
        let lines = WebVTTParser.parse("""
        WEBVTT
        Kind: captions
        Language: en

        first-cue
        00:01.250 --> 00:03.750 align:start position:0%
        First line

        01:02:03.456 --> 01:02:05.000
        Later line
        """)
        #expect(lines == [
            LyricLine(start: 1.25, end: 3.75, text: "First line"),
            LyricLine(start: 3723.456, end: 3725, text: "Later line")
        ])
    }

    @Test("Strips styling, voice and inline timestamp tags and decodes entities")
    func markupAndEntities() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:03.000
        <v Singer><c.colorE5E5E5><i>Hello</i><00:00:01.000>   world</c></v>
        &amp; &lt;you&gt; &quot;me&quot; &#39;us&#39; &#x266A;&nbsp;
        """)
        #expect(lines.map(\.text) == ["Hello world & <you> \"me\" 'us' ♪"])
    }

    @Test("Accepts BOM, CRLF, and whitespace-only separators")
    func lineEndings() {
        let lines = WebVTTParser.parse("\u{FEFF}WEBVTT\r\n \r\n00:00.000 --> 00:02.000\r\nHello\r\n\t\r\n00:02.000 --> 00:04.000\r\nWorld")
        #expect(lines.map(\.text) == ["Hello", "World"])
    }

    @Test("Skips NOTE, STYLE, and REGION metadata blocks")
    func metadata() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        NOTE a comment
        00:00.000 --> 00:01.000
        Not a lyric

        STYLE
        ::cue { color: red; }

        REGION
        id:fred

        00:01.000 --> 00:03.000
        A lyric
        """)
        #expect(lines.map(\.text) == ["A lyric"])
    }

    @Test("Ignores malformed, reversed, zero-length, and invalid timestamps")
    func invalidCues() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        nonsense --> 00:02.000
        Invalid

        00:02.000 --> 00:01.000
        Reversed

        00:02.000 --> 00:02.000
        Zero

        00:60.000 --> 00:62.000
        Invalid seconds

        -1:00.000 --> 00:03.000
        Negative

        00:04.000 --> 00:05.000
        Valid
        """)
        #expect(lines == [LyricLine(start: 4, end: 5, text: "Valid")])
        #expect(WebVTTParser.parse("").isEmpty)
        #expect(WebVTTParser.parse("<html>Not WebVTT</html>").isEmpty)
    }

    @Test("Collapses repeated consecutive cues and extends their duration")
    func consecutiveDuplicates() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:01.000
        The same line

        00:01.000 --> 00:02.000
        <c>The same line</c>

        00:02.000 --> 00:03.000
        The next line
        """)
        #expect(lines == [
            LyricLine(start: 0, end: 2, text: "The same line"),
            LyricLine(start: 2, end: 3, text: "The next line")
        ])
    }

    @Test("Removes carried lines from YouTube rolling captions")
    func rollingCaptions() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:02.000
        First line

        00:01.000 --> 00:03.000
        First line
        Second line

        00:02.000 --> 00:04.000
        Second line

        00:03.000 --> 00:05.000
        Second line
        Third line

        00:04.000 --> 00:06.000
        Third line
        """)
        #expect(lines.map(\.text) == ["First line", "Second line", "Third line"])
        #expect(lines.map(\.start) == [0, 1, 3])
        #expect(lines.last?.end == 6)
    }

    @Test("Merges progressively revealed words into one line")
    func growingCaptions() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:00.500
        Hello

        00:00.500 --> 00:01.000
        Hello <00:00:00.600>world

        00:01.000 --> 00:02.000
        Hello world again
        """)
        #expect(lines == [LyricLine(start: 0, end: 2, text: "Hello world again")])
    }

    @Test("Keeps repeated lyrics after a gap or an intervening line")
    func repeatedChorus() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:02.000
        Chorus

        00:05.000 --> 00:07.000
        Chorus

        00:07.000 --> 00:09.000
        Verse

        00:09.000 --> 00:11.000
        Chorus
        """)
        #expect(lines.map(\.text) == ["Chorus", "Chorus", "Verse", "Chorus"])
    }

    @Test("Merges tiny empty transitions and short text fragments")
    func shortCues() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:00.050
        Oh

        00:00.050 --> 00:02.000
        what a day

        00:02.000 --> 00:02.010
        <c></c>

        00:03.000 --> 00:05.000
        Singing

        00:05.000 --> 00:05.050
        tonight
        """)
        #expect(lines == [
            LyricLine(start: 0, end: 2.01, text: "Oh what a day"),
            LyricLine(start: 3, end: 5.05, text: "Singing tonight")
        ])
    }

    @Test("Keeps isolated short cues without bridging silence")
    func isolatedShortCue() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:00.000 --> 00:00.050
        Hey

        00:05.000 --> 00:07.000
        Hello
        """)
        #expect(lines.map(\.text) == ["Hey", "Hello"])
        #expect(lines.first?.end == 0.05)
    }

    @Test("Orders cues for binary search and handles seeks, gaps, and end boundaries")
    func currentLineLookup() {
        let lines = WebVTTParser.parse("""
        WEBVTT

        00:05.000 --> 00:07.000
        Second

        00:01.000 --> 00:03.000
        First
        """)
        #expect(LyricLine.currentIndex(at: 0, in: lines) == nil)
        #expect(LyricLine.currentIndex(at: 1, in: lines) == 0)
        #expect(LyricLine.currentIndex(at: 3, in: lines) == nil)
        #expect(LyricLine.currentIndex(at: 5.5, in: lines) == 1)
        #expect(LyricLine.currentIndex(at: 1.5, in: lines) == 0)
        #expect(LyricLine.currentIndex(at: 7, in: lines) == nil)
        #expect(LyricLine.currentIndex(at: .nan, in: lines) == nil)
        #expect(LyricLine.currentIndex(at: 1, in: []) == nil)
    }
}

@Suite("Lyrics caption preference")
struct LyricsCaptionPreferenceTests {
    private let french = Caption(label: "French", languageCode: "fr", url: URL(string: "https://example.com/fr")!)
    private let english = Caption(label: "English", languageCode: "en", url: URL(string: "https://example.com/en")!)
    private let automatic = Caption(label: "English (auto-generated)", languageCode: "en", url: URL(string: "https://example.com/auto")!)

    @Test("Prefers matching manual captions even if auto captions appear first")
    func matchingManual() {
        #expect(Caption.preferred(in: [automatic, french, english], languages: ["en-US"]) == english)
    }

    @Test("Prefers any manual captions to matching auto captions")
    func manualFallback() {
        #expect(Caption.preferred(in: [automatic, french], languages: ["en-US"]) == french)
    }

    @Test("Falls back to auto captions and handles no tracks")
    func autoFallback() {
        #expect(Caption.preferred(in: [automatic], languages: ["en-US"]) == automatic)
        #expect(Caption.preferred(in: [], languages: ["en-US"]) == nil)
    }

    @Test("Prefers the exact language region before a base language match")
    func regionalMatch() {
        let british = Caption(label: "English (UK)", languageCode: "en-GB", url: URL(string: "https://example.com/uk")!)
        #expect(Caption.preferred(in: [english, british], languages: ["en_GB"]) == british)
        #expect(Caption.preferred(in: [english, french], languages: ["fr-CA", "en"]) == french)
    }
}
