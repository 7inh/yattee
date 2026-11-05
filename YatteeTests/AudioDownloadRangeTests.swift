//
//  AudioDownloadRangeTests.swift
//  Yattee
//
//  Rejects gaps, truncated chunks and resource changes before offline audio is appended.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Audio download byte ranges")
struct AudioDownloadRangeTests {
    @Test("Successive chunks cover the full file, including a short final range")
    func completeFile() throws {
        let first = try AudioDownloadRange(contentRange: "bytes 0-1023/1200")
        try first.validate(offset: 0, bytes: 1024, expectedTotal: 1200)
        let last = try AudioDownloadRange(contentRange: "bytes 1024-1199/1200")
        try last.validate(offset: 1024, bytes: 176, expectedTotal: first.total)
        #expect(last.end + 1 == last.total)
    }

    @Test("A partial response cannot be appended at the wrong offset")
    func rejectsGap() throws {
        let range = try AudioDownloadRange(contentRange: "bytes 1024-1199/1200")
        #expect(throws: DownloadError.self) { try range.validate(offset: 512, bytes: 176, expectedTotal: 1200) }
    }

    @Test("Truncation and changed resource size fail validation")
    func rejectsTruncation() throws {
        let range = try AudioDownloadRange(contentRange: "bytes 0-1023/1200")
        #expect(throws: DownloadError.self) { try range.validate(offset: 0, bytes: 1023, expectedTotal: 1200) }
        #expect(throws: DownloadError.self) { try range.validate(offset: 0, bytes: 1024, expectedTotal: 1300) }
    }

    @Test("Malformed or unsatisfied ranges are rejected", arguments: ["", "bytes */1200", "bytes 0-1200/1200", "bytes -1-2/3", "items 0-1/3", "bytes 2-1/3"])
    func rejectsInvalidRanges(_ header: String) {
        #expect(throws: DownloadError.self) { try AudioDownloadRange(contentRange: header) }
    }
}
