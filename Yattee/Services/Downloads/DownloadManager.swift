//
//  DownloadManager.swift
//  Yattee
//
//  Persistent audio-only downloads. Each background request fetches one byte range.
//

import Foundation
import SwiftUI

struct DownloadProgressInfo: Equatable, Sendable {
    var progress: Double
    var isIndeterminate: Bool
}

@MainActor
@Observable
final class DownloadManager: NSObject, URLSessionDownloadDelegate {
    var activeDownloads: [Download] = []
    var completedDownloads: [Download] = []
    var downloadedVideoIDs: Set<VideoID> = []
    var downloadingVideoIDs: Set<VideoID> = []
    var downloadProgressByVideo: [VideoID: DownloadProgressInfo] = [:]
    var storageUsed: Int64 = 0
    var batchDownloadIDs: Set<UUID> = []
    let fileManager = FileManager.default
    weak var toastManager: ToastManager?
    weak var downloadSettings: DownloadSettings?
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var finishing: Set<UUID> = []
    private var restoring = true
    private var contentService: ContentService?
    private weak var instancesManager: InstancesManager?
    var backgroundCompletion: (() -> Void)?
    static let sessionIdentifier = AppIdentifiers.downloadSession
    private let rangeSize: Int64 = 4 * 1024 * 1024

    override init() {
        super.init()
        loadDownloads()
    }

    func setAudioSources(contentService: ContentService, instancesManager: InstancesManager) {
        self.contentService = contentService
        self.instancesManager = instancesManager
    }

    func setToastManager(_ manager: ToastManager) { toastManager = manager }

    func setDownloadSettings(_ settings: DownloadSettings) {
        downloadSettings = settings
        guard session == nil else { return }
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // Cellular permission is checked for each request, so changing it doesn't
        // invalidate the background session and discard its delegate events.
        config.allowsCellularAccess = true
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        Task {
            let existing = await session.allTasks
            for task in existing {
                guard let id = task.taskDescription.flatMap(UUID.init(uuidString:)),
                      activeDownloads.contains(where: { $0.id == id && $0.status == .downloading }),
                      let downloadTask = task as? URLSessionDownloadTask else {
                    task.cancel()
                    continue
                }
                tasks[id] = downloadTask
            }
            for index in activeDownloads.indices where tasks[activeDownloads[index].id] == nil && activeDownloads[index].status == .downloading {
                let id = activeDownloads[index].id
                let finalURL = downloadsDirectory().appendingPathComponent("\(id.uuidString).m4a")
                if fileManager.fileExists(atPath: finalURL.path) {
                    activeDownloads[index].localAudioPath = finalURL.lastPathComponent
                    finishing.insert(id)
                    Task { await finish(id) }
                } else { activeDownloads[index].status = .queued }
            }
            restoring = false
            startNextDownloadIfNeeded()
        }
    }

    func refreshCellularAccessSetting() {
        Task {
            for download in activeDownloads where download.status == .downloading {
                await pause(download)
                await resume(download)
            }
        }
    }

    func autoEnqueue(_ video: Video, preferredAudioLanguage: String?, contentService: ContentService,
                     instance: Instance, suppressStartToast: Bool = false) async throws {
        guard !video.isLive else { throw DownloadError.noStreamAvailable }
        let result = try await contentService.videoWithStreamsAndCaptions(id: video.id.videoID, instance: instance)
        let streams = await InvidiousAPI.proxyStreamsIfNeeded(result.streams, instance: instance)
        guard let stream = AudioStreamSelector.downloadStream(from: streams, preferredLanguage: preferredAudioLanguage) else {
            throw DownloadError.noStreamAvailable
        }
        try await enqueue(result.video, stream: stream, suppressStartToast: suppressStartToast)
    }

    func enqueue(_ video: Video, stream: Stream, suppressStartToast: Bool = false) async throws {
        guard AudioStreamSelector.downloadStream(from: [stream]) != nil, !video.isLive else { throw DownloadError.noStreamAvailable }
        guard !isDownloading(video.id) else { throw DownloadError.alreadyDownloading }
        guard !isDownloaded(video.id) else { throw DownloadError.alreadyDownloaded }
        var download = Download(video: video, quality: "Audio", formatID: "m4a", streamURL: stream.url,
                                audioLanguage: stream.audioLanguage, httpHeaders: stream.httpHeaders,
                                audioCodec: "mp4a", audioBitrate: stream.bitrate)
        download.totalBytes = stream.fileSize ?? 0
        activeDownloads.append(download)
        refreshIndexes()
        saveDownloadsImmediately()
        if !suppressStartToast { toastManager?.showInfo("Downloading audio: \(video.title)") }
        startNextDownloadIfNeeded()
    }

    struct BatchDownloadResult: Sendable {
        let successCount: Int
        let skippedCount: Int
        let failedVideos: [(title: String, error: String)]
    }

    func batchAutoEnqueue(videos: [Video], preferredAudioLanguage: String?, contentService: ContentService,
                          instance: Instance, onProgress: @escaping @Sendable (Int, Int) async -> Void,
                          onError: @escaping @Sendable (Video, Error) async -> Bool,
                          onEnqueued: (@Sendable (UUID) async -> Void)? = nil) async -> BatchDownloadResult {
        var success = 0
        var skipped = 0
        var failed: [(title: String, error: String)] = []
        for (index, video) in videos.enumerated() {
            await onProgress(index + 1, videos.count)
            if isDownloaded(video.id) || isDownloading(video.id) { skipped += 1; continue }
            do {
                try Task.checkCancellation()
                try await autoEnqueue(video, preferredAudioLanguage: preferredAudioLanguage, contentService: contentService,
                                      instance: instance, suppressStartToast: true)
                if let download = activeDownloads.first(where: { $0.videoID == video.id }) { await onEnqueued?(download.id) }
                success += 1
            } catch {
                failed.append((video.title, error.localizedDescription))
                if !(await onError(video, error)) { break }
            }
        }
        return BatchDownloadResult(successCount: success, skippedCount: skipped, failedVideos: failed)
    }

    // MARK: - Queue and Ranges

    private func startNextDownloadIfNeeded() {
        guard !restoring, session != nil else { return }
        let limit = downloadSettings?.maxConcurrentDownloads ?? 2
        while tasks.count + finishing.count < limit,
              let index = activeDownloads.firstIndex(where: { $0.status == .queued }) {
            activeDownloads[index].status = .downloading
            activeDownloads[index].startedAt = activeDownloads[index].startedAt ?? Date()
            startRange(for: activeDownloads[index].id)
        }
        saveDownloadsImmediately()
    }

    private func partialURL(_ id: UUID) -> URL { downloadsDirectory().appendingPathComponent("\(id.uuidString).partial") }

    private func startRange(for id: UUID) {
        guard let index = activeDownloads.firstIndex(where: { $0.id == id && $0.status == .downloading }) else { return }
        let download = activeDownloads[index]
        let offset = fileSize(at: partialURL(id).path)
        var components = URLComponents(url: download.streamURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems?.filter { $0.name != "range" }
        components?.queryItems = queryItems
        var request = URLRequest(url: components?.url ?? download.streamURL)
        request.allowsCellularAccess = downloadSettings?.allowCellularDownloads ?? false
        request.setValue(SettingsManager.currentUserAgent(), forHTTPHeaderField: "User-Agent")
        download.httpHeaders?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("bytes=\(offset)-\(offset + rangeSize - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request)
        task.taskDescription = id.uuidString
        tasks[id] = task
        task.resume()
    }

    func receivedProgress(id: UUID, taskID: Int, bytes: Int64) {
        guard tasks[id]?.taskIdentifier == taskID,
              let index = activeDownloads.firstIndex(where: { $0.id == id && $0.status == .downloading }) else { return }
        let written = fileSize(at: partialURL(id).path) + bytes
        activeDownloads[index].downloadedBytes = written
        let total = activeDownloads[index].totalBytes
        if total > 0 { activeDownloads[index].progress = min(1, Double(written) / Double(total)) }
        downloadProgressByVideo[activeDownloads[index].videoID] = DownloadProgressInfo(progress: activeDownloads[index].progress, isIndeterminate: total <= 0)
    }

    func receivedRange(id: UUID, taskID: Int, response: HTTPURLResponse?, location: URL) {
        defer { try? fileManager.removeItem(at: location) }
        guard tasks[id]?.taskIdentifier == taskID,
              let index = activeDownloads.firstIndex(where: { $0.id == id && $0.status == .downloading }) else { return }
        tasks[id] = nil
        do {
            guard let response, [200, 206].contains(response.statusCode) else {
                throw DownloadError.downloadFailed("Audio server returned HTTP \(response?.statusCode ?? 0)")
            }
            let offset = fileSize(at: partialURL(id).path)
            let bytes = fileSize(at: location.path)
            let total: Int64
            if response.statusCode == 206 {
                let range = try AudioDownloadRange(contentRange: response.value(forHTTPHeaderField: "Content-Range") ?? "")
                try range.validate(offset: offset, bytes: bytes, expectedTotal: activeDownloads[index].totalBytes)
                total = range.total
            } else {
                // A server ignoring Range must send the entire object. Restarted
                // requests must never append a full object to an existing prefix.
                guard offset == 0, bytes > 0,
                      activeDownloads[index].totalBytes <= 0 || activeDownloads[index].totalBytes == bytes else {
                    throw DownloadError.downloadFailed("Server did not honor the audio byte range")
                }
                total = bytes
            }
            if offset == 0 {
                let headerFile = try FileHandle(forReadingFrom: location)
                let header = try headerFile.read(upToCount: 8)
                try headerFile.close()
                guard header?.dropFirst(4) == Data("ftyp".utf8) else {
                    throw DownloadError.downloadFailed("Server returned a non-MP4 audio resource")
                }
                try fileManager.moveItem(at: location, to: partialURL(id))
            }
            else {
                let input = try FileHandle(forReadingFrom: location)
                let output = try FileHandle(forWritingTo: partialURL(id))
                defer { try? input.close(); try? output.close() }
                try output.seekToEnd()
                while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
            }
            let written = offset + bytes
            activeDownloads[index].downloadedBytes = written
            activeDownloads[index].totalBytes = total
            activeDownloads[index].progress = Double(written) / Double(total)
            downloadProgressByVideo[activeDownloads[index].videoID] = DownloadProgressInfo(progress: activeDownloads[index].progress, isIndeterminate: false)
            saveDownloadsImmediately()
            if written == total {
                let filename = "\(id.uuidString).m4a"
                try fileManager.moveItem(at: partialURL(id), to: downloadsDirectory().appendingPathComponent(filename))
                activeDownloads[index].localAudioPath = filename
                finishing.insert(id)
                saveDownloadsImmediately()
                Task { await finish(id) }
            } else { startRange(for: id) }
        } catch { failed(id, error: error) }
    }

    private func finish(_ id: UUID) async {
        guard let download = activeDownloads.first(where: { $0.id == id }) else { finishing.remove(id); return }
        var thumbnailPath: String?
        if let url = download.thumbnailURL {
            do {
                let config = URLSessionConfiguration.ephemeral
                config.allowsCellularAccess = downloadSettings?.allowCellularDownloads ?? false
                let artworkSession = URLSession(configuration: config)
                defer { artworkSession.finishTasksAndInvalidate() }
                let (data, response) = try await artworkSession.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    let path = "\(id.uuidString).jpg"
                    try data.write(to: downloadsDirectory().appendingPathComponent(path), options: .atomic)
                    thumbnailPath = path
                }
            } catch { LoggingService.shared.logDownloadError("Offline artwork unavailable", error: error) }
        }
        finishing.remove(id)
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[index].localThumbnailPath = thumbnailPath
        activeDownloads[index].status = .completed
        activeDownloads[index].completedAt = Date()
        activeDownloads[index].progress = 1
        completedDownloads.append(activeDownloads.remove(at: index))
        batchDownloadIDs.remove(id)
        refreshIndexes()
        saveDownloadsImmediately()
        storageUsed = await calculateStorageUsed()
        startNextDownloadIfNeeded()
    }

    func failed(_ id: UUID, taskID: Int? = nil, error: Error) {
        if let taskID, tasks[id]?.taskIdentifier != taskID { return }
        tasks[id] = nil
        guard let index = activeDownloads.firstIndex(where: { $0.id == id }) else { return }
        activeDownloads[index].status = .failed
        activeDownloads[index].error = error.localizedDescription
        LoggingService.shared.logDownloadError("Audio download failed", error: error)
        saveDownloadsImmediately()
        startNextDownloadIfNeeded()
    }

    func pause(_ download: Download) async {
        guard let index = activeDownloads.firstIndex(where: { $0.id == download.id }), !finishing.contains(download.id) else { return }
        activeDownloads[index].status = .paused
        tasks.removeValue(forKey: download.id)?.cancel()
        saveDownloadsImmediately()
        startNextDownloadIfNeeded()
    }

    func resume(_ download: Download) async {
        guard activeDownloads.contains(where: { $0.id == download.id && ($0.status == .paused || $0.status == .failed) }),
              !finishing.contains(download.id) else { return }
        if let contentService, let instance = instancesManager?.instance(for: download.videoID.source) {
            do {
                let result = try await contentService.videoWithStreamsAndCaptions(id: download.videoID.videoID, instance: instance)
                let streams = await InvidiousAPI.proxyStreamsIfNeeded(result.streams, instance: instance)
                guard let stream = AudioStreamSelector.downloadStream(from: streams, preferredLanguage: download.audioLanguage),
                      let current = activeDownloads.firstIndex(where: { $0.id == download.id && ($0.status == .paused || $0.status == .failed) }) else { return }
                // A different rendition may have the same file length. Discard the
                // prefix when its itag or audio language changes.
                let oldItag = URLComponents(url: activeDownloads[current].streamURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itag" }?.value
                let newItag = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itag" }?.value
                if oldItag == nil || newItag == nil || oldItag != newItag || stream.audioLanguage != download.audioLanguage
                    || (stream.fileSize.map { $0 > 0 && $0 != activeDownloads[current].totalBytes } ?? false) {
                    try? fileManager.removeItem(at: partialURL(download.id))
                    activeDownloads[current].totalBytes = stream.fileSize ?? 0
                }
                activeDownloads[current].streamURL = stream.url
                activeDownloads[current].httpHeaders = stream.httpHeaders
            } catch { failed(download.id, error: error); return }
        }
        guard let current = activeDownloads.firstIndex(where: { $0.id == download.id }) else { return }
        activeDownloads[current].status = .queued
        activeDownloads[current].error = nil
        startNextDownloadIfNeeded()
    }

    func cancel(_ download: Download) async {
        tasks.removeValue(forKey: download.id)?.cancel()
        activeDownloads.removeAll { $0.id == download.id }
        finishing.remove(download.id)
        try? fileManager.removeItem(at: partialURL(download.id))
        if let path = download.localAudioPath { try? fileManager.removeItem(at: downloadsDirectory().appendingPathComponent(path)) }
        batchDownloadIDs.remove(download.id)
        refreshIndexes()
        saveDownloadsImmediately()
        startNextDownloadIfNeeded()
    }

    func delete(_ download: Download) async {
        await cancel(download)
        completedDownloads.removeAll { $0.id == download.id }
        for path in [download.localVideoPath, download.localAudioPath, download.localCaptionPath, download.localStoryboardPath,
                     download.localThumbnailPath, download.localChannelThumbnailPath].compactMap({ $0 }) {
            try? fileManager.removeItem(at: downloadsDirectory().appendingPathComponent(path))
        }
        refreshIndexes()
        saveDownloadsImmediately()
        storageUsed = await calculateStorageUsed()
    }

    func deleteAllCompleted() async { for download in completedDownloads { await delete(download) } }
    func deleteWatchedDownloads(watchedVideoIDs: Set<String>) async {
        for download in completedDownloads where watchedVideoIDs.contains(download.videoID.videoID) { await delete(download) }
    }
    func moveInQueue(_ download: Download, to position: Int) async {
        guard let index = activeDownloads.firstIndex(where: { $0.id == download.id }) else { return }
        let item = activeDownloads.remove(at: index)
        activeDownloads.insert(item, at: min(max(0, position), activeDownloads.count))
        saveDownloadsImmediately()
    }

    // MARK: - Offline Playback

    func isDownloaded(_ id: VideoID) -> Bool { downloadedVideoIDs.contains(id) }
    func isDownloading(_ id: VideoID) -> Bool { downloadingVideoIDs.contains(id) }
    func download(for id: VideoID) -> Download? { completedDownloads.first { $0.videoID == id } ?? activeDownloads.first { $0.videoID == id } }
    func localURL(for id: VideoID) -> URL? { download(for: id).flatMap(resolveLocalURL) }
    func resolveLocalURL(for download: Download) -> URL? {
        (download.localAudioPath ?? download.localVideoPath).map { downloadsDirectory().appendingPathComponent($0) }
    }
    func videoAndStream(for download: Download) -> (video: Video, stream: Stream, audioStream: Stream?, captionURL: URL?, dislikeCount: Int?)? {
        guard let url = resolveLocalURL(for: download), url.pathExtension.lowercased() == "m4a", fileManager.fileExists(atPath: url.path) else { return nil }
        let stream = Stream(url: url, resolution: nil, format: "m4a", audioCodec: "mp4a", bitrate: download.audioBitrate,
                            fileSize: download.totalBytes, isAudioOnly: true, isLive: false, mimeType: "audio/mp4")
        return (download.toVideo(downloadsDirectory: downloadsDirectory()), stream, nil, nil, download.dislikeCount)
    }

    func fileSize(at path: String) -> Int64 { (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0 }
    func downloadsDirectory() -> URL {
        var url = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    func refreshIndexes() {
        downloadedVideoIDs = Set(completedDownloads.map(\.videoID))
        downloadingVideoIDs = Set(activeDownloads.map(\.videoID))
        downloadProgressByVideo = Dictionary(uniqueKeysWithValues: activeDownloads.map { ($0.videoID, DownloadProgressInfo(progress: $0.progress, isIndeterminate: $0.totalBytes <= 0)) })
    }
}
