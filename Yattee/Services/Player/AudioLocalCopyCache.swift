//
//  AudioLocalCopyCache.swift
//  Yattee
//
//  Downloads a streamed audio rendition to a local file for speeds above 2x.
//

import Foundation
import CryptoKit
@preconcurrency import AVFoundation

/// iOS plays HLS above 2x silently, so streamed audio switches to a local copy
/// for 2.5x and 3x. Copies are fetched in byte ranges, shared between callers,
/// and only a few recent ones are kept.
actor AudioLocalCopyCache {
    static let shared = AudioLocalCopyCache()

    private static let chunkSize: Int64 = 8 * 1_048_576
    private static let maxFiles = 5
    private static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    private let session: URLSession
    private let directory: URL
    private var inFlight: [String: Task<URL, Error>] = [:]

    init(session: URLSession = .shared, directory: URL? = nil) {
        self.session = session
        self.directory = directory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AudioLocalCopies", isDirectory: true)
    }

    /// The finished local copy for this stream, if one exists.
    func existingCopy(for stream: Stream) -> URL? {
        let url = fileURL(for: stream)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the local copy, downloading it first if needed.
    func localCopy(for stream: Stream) async throws -> URL {
        if let existing = existingCopy(for: stream) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: existing.path)
            return existing
        }
        let key = Self.key(for: stream)
        if let task = inFlight[key] { return try await task.value }
        let destination = fileURL(for: stream)
        let task = Task { try await download(stream, to: destination) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    // MARK: - Download

    private func download(_ stream: Stream, to destination: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // AVFoundation picks the file type from the extension, so keep .m4a last.
        let partial = destination.deletingPathExtension().appendingPathExtension("download.m4a")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: partial) }
        }

        var offset: Int64 = 0
        var total = stream.fileSize
        let started = Date()
        while total.map({ offset < $0 }) ?? true {
            try Task.checkCancellation()
            let end = total.map { min(offset + Self.chunkSize, $0) - 1 } ?? offset + Self.chunkSize - 1
            var request = URLRequest(url: stream.url)
            stream.httpHeaders?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200,
                  !data.isEmpty else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                LoggingService.shared.logPlayer("Audio local copy: HTTP \(status) at byte \(offset), \(data.count) bytes")
                throw URLError(.badServerResponse)
            }
            if http.statusCode == 200 {
                // The server ignored the range and sent the whole file.
                guard offset == 0 else { throw URLError(.badServerResponse) }
                try handle.write(contentsOf: data)
                offset = Int64(data.count)
                break
            }
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"),
               let size = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                total = size
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if total == nil, Int64(data.count) < Self.chunkSize { break }
        }
        try handle.close()
        try await rewriteAsPlainM4A(partial, to: destination)
        try? FileManager.default.removeItem(at: partial)
        completed = true
        LoggingService.shared.logPlayer(
            "Audio local copy ready: \(offset / 1024) KB in \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
        )
        prune(keeping: destination)
        return destination
    }

    /// YouTube audio is fragmented DASH MP4, which AVFoundation reads with the
    /// wrong duration. A passthrough export (no re-encoding) writes a plain M4A.
    private func rewriteAsPlainM4A(_ source: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw URLError(.cannotDecodeContentData)
        }
        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            LoggingService.shared.logPlayer("Audio local copy: export failed: \(error)")
            throw error
        }
    }

    private func prune(keeping kept: URL) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }
        let dated = files.filter {
            $0.pathExtension == "m4a" && !$0.lastPathComponent.hasSuffix(".download.m4a") && $0 != kept
        }.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in dated.enumerated()
        where index >= Self.maxFiles - 1 || Date().timeIntervalSince(entry.1) > Self.maxAge {
            try? FileManager.default.removeItem(at: entry.0)
        }
    }

    // MARK: - Keys

    private func fileURL(for stream: Stream) -> URL {
        directory.appendingPathComponent(Self.key(for: stream)).appendingPathExtension("m4a")
    }

    /// Stream URLs carry expiring signatures, so key by the video and format
    /// when the URL names them; otherwise by the whole URL.
    static func key(for stream: Stream) -> String {
        let items = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let raw: String
        if let id = value("id"), let itag = value("itag") {
            raw = "\(id)-\(itag)-\(stream.fileSize ?? 0)"
        } else {
            raw = stream.url.absoluteString
        }
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
