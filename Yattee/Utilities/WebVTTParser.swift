//
//  WebVTTParser.swift
//  Yattee
//
//  Turns WebVTT captions, including YouTube rolling captions, into lyric lines.
//

import Foundation

enum WebVTTParser {
    private struct Cue: Sendable {
        let start: TimeInterval
        let end: TimeInterval
        let lines: [String]
    }

    private static let numericEntityPattern = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")

    // MARK: - Parsing

    static func parse(_ webVTT: String) -> [LyricLine] {
        let source = webVTT
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = source.components(separatedBy: "\n").split {
            $0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cues = blocks.compactMap { block -> Cue? in
            let rows = Array(block)
            guard let first = rows.first,
                  !first.hasPrefix("WEBVTT"), first != "NOTE",
                  !first.hasPrefix("NOTE "), !first.hasPrefix("NOTE\t"),
                  first != "STYLE", first != "REGION",
                  let timingIndex = rows.prefix(2).firstIndex(where: { $0.contains("-->") }) else { return nil }
            let timing = rows[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2,
                  let start = timestamp(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = timing[1].split(whereSeparator: \.isWhitespace).first,
                  let end = timestamp(String(endToken)), end > start else { return nil }
            return Cue(start: start, end: end, lines: rows.dropFirst(timingIndex + 1).map(cleanText).filter { !$0.isEmpty })
        }.sorted { $0.start < $1.start }

        var lines: [LyricLine] = []
        var previousCue: Cue?
        for cue in cues {
            guard !cue.lines.isEmpty else {
                // Tiny blank transition cues should not flash an empty lyric.
                if let last = lines.last, cue.end - cue.start < 0.2, cue.start <= last.end + 0.1 {
                    lines[lines.count - 1] = LyricLine(start: last.start, end: max(last.end, cue.end), text: last.text)
                }
                continue
            }

            var newLines = cue.lines
            if let previousCue, cue.start <= previousCue.end + 0.1 {
                // A rolling cue carries the previous cue's last line(s) above its new text.
                let limit = min(previousCue.lines.count, newLines.count)
                if let overlap = (1...limit).reversed().first(where: {
                    previousCue.lines.suffix($0).elementsEqual(newLines.prefix($0))
                }) {
                    newLines.removeFirst(overlap)
                }
            }
            previousCue = cue

            let text = newLines.joined(separator: " ")
            if let last = lines.last, cue.start <= last.end + 0.1 {
                if text.isEmpty || text == last.text {
                    lines[lines.count - 1] = LyricLine(start: last.start, end: max(last.end, cue.end), text: last.text)
                    continue
                }
                // Word-timed captions can progressively grow a single physical line.
                if text.hasPrefix(last.text + " ") {
                    lines[lines.count - 1] = LyricLine(start: last.start, end: max(last.end, cue.end), text: text)
                    continue
                }
            }
            if !text.isEmpty {
                lines.append(LyricLine(start: cue.start, end: cue.end, text: text))
            }
        }

        return mergeShortLines(lines)
    }

    // MARK: - Normalization

    private static func timestamp(_ value: String) -> TimeInterval? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.dropLast().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let minutes = Int(parts[parts.count - 2]), minutes < 60 else { return nil }
        let secondParts = parts[parts.count - 1].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count == 2, secondParts[0].count == 2, secondParts[1].count == 3,
              secondParts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              let seconds = Double(parts[parts.count - 1]), seconds < 60 else { return nil }
        let hours: Double
        if parts.count == 3 {
            guard let value = Double(parts[0]), value.isFinite else { return nil }
            hours = value
        } else {
            hours = 0
        }
        let time = hours * 3600 + Double(minutes) * 60 + seconds
        return time.isFinite ? time : nil
    }

    private static func cleanText(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        // Decode after stripping tags so escaped literal angle brackets survive.
        let entities = ["&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&lrm;": "", "&rlm;": "", "&quot;": "\"", "&apos;": "'"]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        if let regex = numericEntityPattern {
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let tokenRange = Range(match.range(at: 1), in: result),
                      let wholeRange = Range(match.range, in: result) else { continue }
                let token = String(result[tokenRange])
                let value = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
                if let value, let scalar = UnicodeScalar(value) {
                    result.replaceSubrange(wholeRange, with: String(scalar))
                }
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func mergeShortLines(_ lines: [LyricLine]) -> [LyricLine] {
        var merged: [LyricLine] = []
        var pending: LyricLine?
        for line in lines {
            var line = line
            if let fragment = pending {
                if line.start <= fragment.end + 0.1 {
                    line = LyricLine(start: fragment.start, end: max(fragment.end, line.end), text: fragment.text + " " + line.text)
                } else {
                    merged.append(fragment)
                }
                pending = nil
            }
            if line.end - line.start < 0.2 {
                pending = line
            } else {
                merged.append(line)
            }
        }
        if let fragment = pending {
            if let last = merged.last, fragment.start <= last.end + 0.1 {
                merged[merged.count - 1] = LyricLine(start: last.start, end: max(last.end, fragment.end), text: last.text + " " + fragment.text)
            } else {
                merged.append(fragment)
            }
        }
        return merged
    }
}
