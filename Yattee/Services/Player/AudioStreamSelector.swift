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
