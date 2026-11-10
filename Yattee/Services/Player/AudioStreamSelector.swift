//
//  AudioStreamSelector.swift
//  Yattee
//
//  Selects standalone audio streams without falling back to video URLs.
//

import Foundation

extension Stream {
    /// Only explicit audio renditions are safe. An HLS master may fetch video,
    /// and relabeling a muxed file as audio does not remove its video bytes.
    var isAVPlayerAudioPlayable: Bool {
        guard isAudioOnly, videoCodec == nil, resolution == nil else { return false }
        let container = format.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        let codec = audioCodec?.lowercased() ?? ""
        let ext = url.pathExtension.lowercased()
        guard !mime.hasPrefix("video/"),
              ![container, mime, codec, ext].contains(where: {
                  $0.contains("webm") || $0.contains("opus") || $0.contains("ogg") || $0.contains("vorbis")
              }),
              !container.contains("dash"), !mime.contains("dash"), ext != "mpd" else { return false }
        return isAACAudio || container == "hls" || container == "m3u8" || ext == "m3u8"
            || mime.contains("mpegurl") || container == "mp3" || ext == "mp3"
            || mime == "audio/mpeg" || codec.contains("mp3")
    }

    var isAACAudio: Bool {
        let codec = audioCodec?.lowercased() ?? ""
        let container = format.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        return codec.contains("aac") || codec.contains("mp4a")
            || ["m4a", "mp4", "aac"].contains(container)
            || ["m4a", "aac"].contains(url.pathExtension.lowercased())
            || mime.hasPrefix("audio/mp4") || mime.hasPrefix("audio/aac")
    }
}

enum AudioStreamSelector {
    static func select(from streams: [Stream], preferredLanguage: String? = nil) -> Stream? {
        streams.filter(\.isAVPlayerAudioPlayable).sorted { first, second in
            if let preferredLanguage, !preferredLanguage.isEmpty {
                let firstMatches = first.audioLanguage?.hasPrefix(preferredLanguage) == true
                let secondMatches = second.audioLanguage?.hasPrefix(preferredLanguage) == true
                if firstMatches != secondMatches { return firstMatches }
            } else if first.isOriginalAudio != second.isOriginalAudio {
                return first.isOriginalAudio
            }
            if first.isAACAudio != second.isAACAudio { return first.isAACAudio }
            return (first.bitrate ?? 0) > (second.bitrate ?? 0)
        }.first
    }
}

extension AudioStreamSelector {
    /// Downloads require a complete MP4 audio resource, never HLS, Opus or a muxed file.
    static func downloadStream(from streams: [Stream], preferredLanguage: String? = nil) -> Stream? {
        let candidates = streams.filter {
            $0.isAVPlayerAudioPlayable && $0.isAACAudio
                && (["m4a", "mp4"].contains($0.format.lowercased()) || ($0.mimeType ?? "").hasPrefix("audio/mp4") || $0.url.pathExtension.lowercased() == "m4a")
                && !$0.url.isFileURL && !$0.url.pathExtension.lowercased().contains("m3u8")
                && !(($0.mimeType ?? "").contains("mpegurl")) && $0.format.lowercased() != "hls"
        }
        return candidates.sorted { first, second in
            let first140 = URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "itag" && $0.value == "140" } == true
            let second140 = URLComponents(url: second.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "itag" && $0.value == "140" } == true
            if first140 != second140 { return first140 }
            if let language = preferredLanguage {
                let a = first.audioLanguage?.hasPrefix(language) == true
                let b = second.audioLanguage?.hasPrefix(language) == true
                if a != b { return a }
            }
            return (first.bitrate ?? 0) > (second.bitrate ?? 0)
        }.first
    }
}

// MARK: - Audio Track Options

/// One selectable voice of a video (e.g. "English · Original", "Vietnamese · AI dub").
struct AudioTrackOption: Identifiable, Hashable, Sendable {
    /// Language code as reported by the source (may carry a YouTube suffix like "en.4").
    let language: String
    let kind: AudioTrackKind?
    /// Best playable stream for this voice.
    let stream: Stream

    var id: String { "\(language)|\(kind?.rawValue ?? "")" }

    /// Language name in the user's locale, e.g. "Vietnamese".
    var languageName: String {
        // "en-US.4" -> "en": show "English", not "English (United States)".
        let code = String(language.split(separator: ".").first ?? Substring(language))
        let base = String(code.split(separator: "-").first ?? Substring(code))
        if let name = Locale.current.localizedString(forLanguageCode: base) ?? Locale.current.localizedString(forIdentifier: code) {
            return name.prefix(1).uppercased() + name.dropFirst()
        }
        return stream.audioTrackName ?? code
    }

    var label: String {
        guard let kind else { return languageName }
        return "\(languageName) · \(kind.label)"
    }

    func matches(_ stream: Stream?) -> Bool {
        guard let stream else { return false }
        return stream.audioLanguage == language && stream.audioTrackKind == kind
    }
}

extension AudioStreamSelector {
    /// Distinct voices available for a video, original first. Empty when the
    /// streams carry no language information (single-voice videos).
    static func trackOptions(from streams: [Stream]) -> [AudioTrackOption] {
        let playable = streams.filter { $0.isAVPlayerAudioPlayable && $0.audioLanguage != nil }
        let groups = Dictionary(grouping: playable) { "\($0.audioLanguage ?? "")|\($0.audioTrackKind?.rawValue ?? "")" }
        let options = groups.values.compactMap { group -> AudioTrackOption? in
            guard let best = select(from: group), let language = best.audioLanguage else { return nil }
            return AudioTrackOption(language: language, kind: best.audioTrackKind, stream: best)
        }
        return options.sorted { first, second in
            let firstOriginal = first.kind == .original
            let secondOriginal = second.kind == .original
            if firstOriginal != secondOriginal { return firstOriginal }
            return first.label.localizedStandardCompare(second.label) == .orderedAscending
        }
    }

    /// Picks the stream for the same voice (language and kind) as `current`,
    /// falling back to language-only matching, then to the preferred language.
    static func select(from streams: [Stream], sameVoiceAs current: Stream?, preferredLanguage: String?) -> Stream? {
        if let current, let language = current.audioLanguage {
            let sameVoice = streams.filter { $0.audioLanguage == language && $0.audioTrackKind == current.audioTrackKind }
            if let match = select(from: sameVoice) { return match }
            return select(from: streams, preferredLanguage: language)
        }
        return select(from: streams, preferredLanguage: preferredLanguage)
    }
}
