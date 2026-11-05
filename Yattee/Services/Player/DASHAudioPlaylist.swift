//
//  DASHAudioPlaylist.swift
//  Yattee
//
//  Converts a DASH sidx into an HLS byte-range playlist for standalone fMP4 audio.
//

import Foundation

enum DASHAudioError: Error, LocalizedError, Equatable, Sendable {
    case invalidRange
    case invalidIndex
    case unsupportedIndex
    case invalidResponse
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidRange: "Invalid DASH byte range."
        case .invalidIndex: "Invalid DASH segment index."
        case .unsupportedIndex: "Unsupported DASH segment index."
        case .invalidResponse: "The server did not return the requested DASH index range."
        case .network(let message): "Could not load the DASH index: \(message)"
        }
    }
}

// MARK: - Byte Ranges and Segment Index

struct DASHByteRange: Hashable, Sendable {
    let start: Int64
    let end: Int64

    var length: Int64 { end - start + 1 }

    init?(_ range: String) {
        let parts = range.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]), let end = Int64(parts[1]),
              start >= 0, end >= start, end < Int64.max else { return nil }
        self.start = start
        self.end = end
    }
}

struct DASHSegmentIndex: Sendable {
    struct Segment: Hashable, Sendable {
        let start: Int64
        let length: Int64
        let duration: TimeInterval
    }

    let timescale: UInt32
    let earliestPresentationTime: UInt64
    let firstOffset: UInt64
    let segments: [Segment]

    /// Offsets are relative to the end of the sidx box, normally indexRange.end + 1.
    /// Walk box boundaries so a leading box or an extended-size header is safe.
    static func parse(_ data: Data, indexRange: DASHByteRange) throws -> Self {
        guard Int64(data.count) == indexRange.length else { throw DASHAudioError.invalidIndex }
        var reader = Reader(bytes: Array(data), end: data.count)
        while reader.offset < data.count {
            let boxStart = reader.offset
            let size = try reader.read(4)
            let type = try reader.read(4)
            let boxSize: UInt64
            switch size {
            case 0: boxSize = UInt64(data.count - boxStart)
            case 1: boxSize = try reader.read(8)
            default: boxSize = size
            }
            guard boxSize >= UInt64(reader.offset - boxStart),
                  boxSize <= UInt64(data.count - boxStart) else { throw DASHAudioError.invalidIndex }
            let boxEnd = boxStart + Int(boxSize)
            if type == 0x73696478 { // sidx
                reader.end = boxEnd
                return try parseReferences(&reader, boxEnd: indexRange.start + Int64(boxEnd))
            }
            reader.offset = boxEnd
        }
        throw DASHAudioError.invalidIndex
    }

    private static func parseReferences(_ reader: inout Reader, boxEnd: Int64) throws -> Self {
        let version = try reader.read(4) >> 24 // FullBox version and flags
        guard version <= 1 else { throw DASHAudioError.unsupportedIndex }
        _ = try reader.read(4) // reference_ID
        let timescale = UInt32(try reader.read(4))
        guard timescale > 0 else { throw DASHAudioError.invalidIndex }
        let earliestPresentationTime = try reader.read(version == 0 ? 4 : 8)
        let firstOffset = try reader.read(version == 0 ? 4 : 8)
        _ = try reader.read(2) // reserved
        let count = Int(try reader.read(2))
        guard count > 0, count <= (reader.end - reader.offset) / 12,
              firstOffset <= UInt64(Int64.max - boxEnd) else { throw DASHAudioError.invalidIndex }
        var start = boxEnd + Int64(firstOffset)
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for _ in 0..<count {
            let reference = try reader.read(4)
            // Hierarchical indexes need another fetch; fall back rather than treat them as media.
            guard reference & 0x80000000 == 0 else { throw DASHAudioError.unsupportedIndex }
            let length = Int64(reference & 0x7fffffff)
            let duration = try reader.read(4)
            _ = try reader.read(4) // SAP flags and delta (audio samples are independent)
            guard length > 0, duration > 0, start <= Int64.max - length else {
                throw DASHAudioError.invalidIndex
            }
            segments.append(Segment(start: start, length: length,
                                    duration: Double(duration) / Double(timescale)))
            start += length
        }
        return Self(timescale: timescale, earliestPresentationTime: earliestPresentationTime,
                    firstOffset: firstOffset, segments: segments)
    }

    /// Bounds-checked big-endian reads also avoid unaligned integer loads.
    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var end: Int

        mutating func read(_ count: Int) throws -> UInt64 {
            guard count <= end - offset else { throw DASHAudioError.invalidIndex }
            var value: UInt64 = 0
            for byte in bytes[offset..<(offset + count)] { value = (value << 8) | UInt64(byte) }
            offset += count
            return value
        }
    }
}

// MARK: - Playlist Generation

enum DASHAudioPlaylist {
    static func make(stream: Stream, indexData: Data) throws -> String {
        guard let rawInit = stream.initRange, let initialization = DASHByteRange(rawInit),
              let rawIndex = stream.indexRange, let range = DASHByteRange(rawIndex),
              initialization.end < range.start else { throw DASHAudioError.invalidRange }
        let index = try DASHSegmentIndex.parse(indexData, indexRange: range)
        if let fileSize = stream.fileSize, let last = index.segments.last {
            guard last.start + last.length <= fileSize else { throw DASHAudioError.invalidIndex }
        }

        // Coalesce adjacent fragments to reduce playlist size and HTTP requests.
        // A larger original fragment is kept intact; merged fragments never exceed 30s.
        var segments: [DASHSegmentIndex.Segment] = []
        for segment in index.segments {
            if let previous = segments.last, previous.start + previous.length == segment.start,
               previous.duration + segment.duration <= 30 {
                segments[segments.count - 1] = .init(start: previous.start,
                                                    length: previous.length + segment.length,
                                                    duration: previous.duration + segment.duration)
            } else {
                segments.append(segment)
            }
        }
        let targetDuration = Int(ceil(segments.map(\.duration).max() ?? 1))
        let url = stream.url.absoluteString
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(initialization.length)@\(initialization.start)\""
        ]
        for segment in segments {
            let duration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), segment.duration)
            lines.append("#EXTINF:\(duration),")
            lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.start)")
            lines.append(url)
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Index Loading

actor DASHAudioPlaylistLoader {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func playlist(for stream: Stream) async throws -> String {
        guard let rawRange = stream.indexRange, let range = DASHByteRange(rawRange),
              range.length <= 1_048_576 else { throw DASHAudioError.invalidRange }
        var request = URLRequest(url: stream.url, timeoutInterval: 20)
        request.allHTTPHeaderFields = stream.httpHeaders
        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        do {
            try Task.checkCancellation()
            // Inspect headers before reading the body: an ignored Range must never
            // download the entire multi-hour audio file just to build a playlist.
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                  http.value(forHTTPHeaderField: "Content-Range")?
                    .hasPrefix("bytes \(range.start)-\(range.end)/") == true else {
                throw DASHAudioError.invalidResponse
            }
            var data = Data()
            data.reserveCapacity(Int(range.length))
            for try await byte in bytes {
                guard data.count < Int(range.length) else { throw DASHAudioError.invalidResponse }
                data.append(byte)
            }
            try Task.checkCancellation()
            guard data.count == Int(range.length) else { throw DASHAudioError.invalidResponse }
            return try DASHAudioPlaylist.make(stream: stream, indexData: data)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error as? DASHAudioError ?? .network(error.localizedDescription)
        }
    }
}
