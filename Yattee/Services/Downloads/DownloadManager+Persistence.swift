//
//  DownloadManager+Persistence.swift
//  Yattee
//
//  Persists audio downloads and imports compatible files from earlier releases.
//

import Foundation

extension DownloadManager {
    func saveDownloadsImmediately() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(activeDownloads), forKey: "activeDownloads")
            UserDefaults.standard.set(try JSONEncoder().encode(completedDownloads), forKey: "completedDownloads")
        } catch { LoggingService.shared.logDownloadError("Unable to save audio downloads", error: error) }
    }

    func loadDownloads() {
        let decoder = JSONDecoder()
        if let data = UserDefaults.standard.data(forKey: "activeDownloads") {
            activeDownloads = (try? decoder.decode(LossyDecodableArray<Download>.self, from: data).elements) ?? []
            // Pre-audio jobs contain video URLs. Leave them out rather than fetch video bytes.
            activeDownloads.removeAll { $0.formatID != "m4a" || $0.quality != "Audio" }
        }
        if let data = UserDefaults.standard.data(forKey: "completedDownloads") {
            completedDownloads = ((try? decoder.decode(LossyDecodableArray<Download>.self, from: data).elements) ?? []).filter {
                guard let url = resolveLocalURL(for: $0) else { return false }
                return url.pathExtension.lowercased() == "m4a" && fileManager.fileExists(atPath: url.path)
            }
        }
        refreshIndexes()
        Task { storageUsed = await calculateStorageUsed() }
    }
}
