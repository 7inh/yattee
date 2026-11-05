//
//  AudioDownloadRange.swift
//  Yattee
//
//  Validates byte ranges before appending them to an offline audio file.
//

import Foundation

struct AudioDownloadRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64

    init(contentRange: String) throws {
        let parts = contentRange.split(separator: " ")
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            throw DownloadError.downloadFailed("Missing audio byte range")
        }
        let bounds = parts[1].split(separator: "/")
        let offsets = bounds.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
        guard bounds.count == 2, offsets.count == 2,
              let start = Int64(offsets[0]), let end = Int64(offsets[1]), let total = Int64(bounds[1]),
              start >= 0, end >= start, end < total else {
            throw DownloadError.downloadFailed("Invalid audio byte range")
        }
        self.start = start
        self.end = end
        self.total = total
    }

    func validate(offset: Int64, bytes: Int64, expectedTotal: Int64) throws {
        guard start == offset, bytes == end - start + 1,
              expectedTotal <= 0 || expectedTotal == total else {
            throw DownloadError.downloadFailed("Incomplete or changed audio file")
        }
    }
}
