//
//  LyricLine.swift
//  Yattee
//
//  A caption line and its playback interval for synced lyrics.
//

import Foundation

struct LyricLine: Codable, Hashable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String

    /// Find the latest started line without scanning the entire transcript each tick.
    static func currentIndex(at time: TimeInterval, in lines: [LyricLine]) -> Int? {
        guard time.isFinite else { return nil }
        var lower = 0
        var upper = lines.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lines[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let index = lower - 1
        return index >= 0 && time < lines[index].end ? index : nil
    }
}
