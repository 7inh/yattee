//
//  DASHAudioPlaylistTests.swift
//  Yattee
//
//  Synthetic DASH indexes exercise HLS durations, byte offsets and safe fallback errors.
//

import Foundation
import Testing
@testable import Yattee

@Suite("DASH audio byte-range playlists")
struct DASHAudioPlaylistTests {
    private let url = URL(string: "https://example.com/videoplayback?itag=140&expire=123&sig=abc")!

    @Test("Version 0 uses the end of sidx plus first_offset and accumulates byte sizes")
    func parsesVersionZero() throws {
        let data = sidx(firstOffset: 11, references: [(100, 10_500), (200, 9_500), (300, 15_250)])
        let range = try indexRange(for: data)
        let index = try DASHSegmentIndex.parse(data, indexRange: range)
        #expect(index.timescale == 1_000)
        #expect(index.earliestPresentationTime == 2_500)
        #expect(index.firstOffset == 11)
        #expect(index.segments.map(\.start) == [range.end + 12, range.end + 112, range.end + 312])
        #expect(index.segments.map(\.length) == [100, 200, 300])
        #expect(index.segments.map(\.duration) == [10.5, 9.5, 15.25])
    }

    @Test("Version 1 preserves 64-bit presentation time and first_offset")
    func parsesVersionOne() throws {
        let offset: UInt64 = (1 << 32) + 17
        let time: UInt64 = (1 << 35) + 123
        let data = sidx(version: 1, earliestTime: time, firstOffset: offset, references: [(321, 1_250)])
        let range = try indexRange(for: data)
        let index = try DASHSegmentIndex.parse(data, indexRange: range)
        #expect(index.earliestPresentationTime == time)
        #expect(index.firstOffset == offset)
        #expect(index.segments == [.init(start: range.end + 1 + Int64(offset), length: 321, duration: 1.25)])
    }

    @Test("Box boundaries support leading boxes and an extended-size sidx header")
    func parsesBoxHeaders() throws {
        let original = sidx(firstOffset: 5, references: [(100, 1_000)])
        let prefix = Data([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65]) // free box
        var data = prefix
        data.append(contentsOf: integer(1, bytes: 4))
        data.append(contentsOf: [0x73, 0x69, 0x64, 0x78])
        data.append(contentsOf: integer(UInt64(original.count + 8), bytes: 8))
        data.append(original.dropFirst(8))
        let sidxEnd = 723 + Int64(data.count)
        data.append(prefix) // first_offset is relative to sidx, not the whole fetched range
        let index = try DASHSegmentIndex.parse(data, indexRange: indexRange(for: data))
        #expect(index.segments.first?.start == sidxEnd + 5)
    }

    @Test("HLS v7 preserves signed URLs, maps initialization bytes and merges at most 30 seconds")
    func generatesPlaylist() throws {
        let data = sidx(firstOffset: 11, references: [(100, 10_500), (200, 9_500), (300, 15_250)])
        let range = try indexRange(for: data)
        let stream = Stream(url: url, format: "m4a", fileSize: range.end + 612,
                            isAudioOnly: true, mimeType: "audio/mp4",
                            initRange: "0-722", indexRange: "\(range.start)-\(range.end)")
        let playlist = try DASHAudioPlaylist.make(stream: stream, indexData: data)
        #expect(playlist == """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:20
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MAP:URI="\(url.absoluteString)",BYTERANGE="723@0"
        #EXTINF:20.000000,
        #EXT-X-BYTERANGE:300@\(range.end + 12)
        \(url.absoluteString)
        #EXTINF:15.250000,
        #EXT-X-BYTERANGE:300@\(range.end + 312)
        \(url.absoluteString)
        #EXT-X-ENDLIST

        """)
    }

    @Test("Many short fragments coalesce without crossing 30 seconds or losing the final fragment")
    func coalescesTinySegments() throws {
        let data = sidx(references: Array(repeating: (10, 1_000), count: 65))
        let range = try indexRange(for: data)
        let stream = Stream(url: url, format: "m4a", isAudioOnly: true,
                            initRange: "0-722", indexRange: "\(range.start)-\(range.end)")
        let playlist = try DASHAudioPlaylist.make(stream: stream, indexData: data)
        #expect(playlist.contains("#EXT-X-TARGETDURATION:30\n"))
        #expect(playlist.components(separatedBy: "#EXTINF:30.000000,").count == 3)
        #expect(playlist.contains("#EXTINF:5.000000,\n#EXT-X-BYTERANGE:50@\(range.end + 601)\n"))
    }

    @Test("Malformed, truncated, empty, hierarchical and overflowing indexes fail safely")
    func rejectsInvalidIndexes() throws {
        let valid = sidx(references: [(100, 1_000)])
        let invalid = [
            Data(), Data(valid.dropLast()),
            sidx(timescale: 0, references: [(100, 1_000)]),
            sidx(version: 2, references: [(100, 1_000)]),
            sidx(references: []),
            sidx(references: [(0x80000064, 1_000)]),
            sidx(references: [(0, 1_000)]),
            sidx(references: [(100, 0)]),
            sidx(version: 1, firstOffset: UInt64.max, references: [(100, 1_000)])
        ]
        for data in invalid {
            // The empty input deliberately uses a nonempty advertised range.
            let range = try indexRange(for: data.isEmpty ? valid : data)
            #expect(throws: DASHAudioError.self) {
                try DASHSegmentIndex.parse(data, indexRange: range)
            }
        }
    }

    @Test("Invalid ranges and segment offsets beyond clen cannot produce a playlist")
    func rejectsInvalidRanges() throws {
        for raw in ["", "723", "-1-2", "2-1", "0-9223372036854775807"] {
            #expect(DASHByteRange(raw) == nil)
        }
        let data = sidx(references: [(100, 1_000)])
        let range = try indexRange(for: data)
        let truncated = Stream(url: url, format: "m4a", fileSize: range.end + 50,
                               isAudioOnly: true, initRange: "0-722",
                               indexRange: "\(range.start)-\(range.end)")
        #expect(throws: DASHAudioError.invalidIndex) {
            try DASHAudioPlaylist.make(stream: truncated, indexData: data)
        }
        #expect(throws: DASHAudioError.invalidRange) {
            try DASHAudioPlaylist.make(stream: .audioPreview, indexData: data)
        }
    }

    @Test("Stream copies and Codable retain optional DASH metadata; older streams still decode")
    func preservesStreamMetadata() throws {
        let stream = Stream(url: url, format: "m4a", fileSize: 400_000_000,
                            isAudioOnly: true, initRange: "0-722", indexRange: "723-30610")
        let rewritten = stream.withURL(URL(string: "https://proxy.example/audio")!).audioOnlyVariant()
        #expect(rewritten.initRange == stream.initRange)
        #expect(rewritten.indexRange == stream.indexRange)
        #expect(rewritten.fileSize == stream.fileSize)
        let decoded = try JSONDecoder().decode(Stream.self, from: JSONEncoder().encode(stream))
        #expect(decoded == stream)
        let oldStream = try JSONDecoder().decode(Stream.self, from: JSONEncoder().encode(Stream.audioPreview))
        #expect(oldStream.initRange == nil)
        #expect(oldStream.indexRange == nil)
    }

    // MARK: - Synthetic ISO BMFF Data

    private func indexRange(for data: Data) throws -> DASHByteRange {
        try #require(DASHByteRange("723-\(722 + data.count)"))
    }

    private func sidx(version: UInt8 = 0, timescale: UInt32 = 1_000, earliestTime: UInt64 = 2_500,
                      firstOffset: UInt64 = 0, references: [(UInt32, UInt32)]) -> Data {
        var payload = [version, 0, 0, 0]
        payload += integer(1, bytes: 4) // reference_ID
        payload += integer(UInt64(timescale), bytes: 4)
        payload += integer(earliestTime, bytes: version == 0 ? 4 : 8)
        payload += integer(firstOffset, bytes: version == 0 ? 4 : 8)
        payload += [0, 0] // reserved
        payload += integer(UInt64(references.count), bytes: 2)
        for (size, duration) in references {
            payload += integer(UInt64(size), bytes: 4)
            payload += integer(UInt64(duration), bytes: 4)
            payload += integer(0x90000000, bytes: 4) // starts_with_SAP, SAP type 1
        }
        return Data(integer(UInt64(payload.count + 8), bytes: 4) + [0x73, 0x69, 0x64, 0x78] + payload)
    }

    private func integer(_ value: UInt64, bytes: Int) -> [UInt8] {
        (0..<bytes).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}
