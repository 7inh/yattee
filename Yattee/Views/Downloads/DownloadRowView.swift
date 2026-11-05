//
//  DownloadRowView.swift
//  Yattee
//
//  Audio download progress and offline playback actions.
//

import Foundation
import SwiftUI

struct DownloadRowView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    let download: Download
    let isActive: Bool
    var queueSource: QueueSource? = nil
    var sourceLabel: String? = nil
    var videoList: [Video]? = nil
    var videoIndex: Int? = nil
    var loadMoreVideos: LoadMoreVideosCallback? = nil

    private var video: Video { download.toVideo(downloadsDirectory: appEnvironment?.downloadManager.downloadsDirectory()) }

    var body: some View {
        if isActive {
            VStack(alignment: .leading, spacing: 8) {
                Text(download.title).font(.headline).lineLimit(2)
                Text(download.channelName).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: download.progress)
                HStack {
                    Text("M4A • \(ByteCountFormatter.string(fromByteCount: download.downloadedBytes, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if download.status == .downloading {
                        Button("Pause") { Task { await appEnvironment?.downloadManager.pause(download) } }
                    } else if download.status == .paused || download.status == .failed {
                        Button("Resume") { Task { await appEnvironment?.downloadManager.resume(download) } }
                    }
                    Button("Cancel", role: .destructive) { Task { await appEnvironment?.downloadManager.cancel(download) } }
                }
                if let error = download.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(.vertical, 8)
        } else {
            VideoRowView(video: video, customMetadata: "M4A • \(ByteCountFormatter.string(fromByteCount: download.totalBytes, countStyle: .file))", disableInternalTapHandling: true)
                .tappableVideo(video, queueSource: queueSource, sourceLabel: sourceLabel, videoList: videoList,
                               videoIndex: videoIndex, loadMoreVideos: loadMoreVideos)
                .contextMenu {
                    Button("Delete download", role: .destructive) { Task { await appEnvironment?.downloadManager.delete(download) } }
                }
        }
    }
}
