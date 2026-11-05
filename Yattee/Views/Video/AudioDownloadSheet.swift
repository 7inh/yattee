//
//  AudioDownloadSheet.swift
//  Yattee
//
//  Downloads one complete AAC/m4a resource for offline listening.
//

import Foundation
import SwiftUI

struct AudioDownloadSheet: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    let video: Video
    var streams: [Stream] = []
    @State private var isDownloading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(video.title).font(.headline)
                    Text("Audio • M4A").foregroundStyle(.secondary)
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button("Download audio") { Task { await download() } }
                    .disabled(isDownloading || video.isLive)
                if isDownloading { ProgressView() }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetCloseToolbarItem { dismiss() } }
        }
        .presentationDetents([.medium])
    }

    private func download() async {
        guard let appEnvironment else { return }
        isDownloading = true
        defer { isDownloading = false }
        do {
            let language = appEnvironment.settingsManager.preferredAudioLanguage
            if let stream = AudioStreamSelector.downloadStream(from: streams, preferredLanguage: language) {
                try await appEnvironment.downloadManager.enqueue(video, stream: stream)
            } else {
                guard let instance = appEnvironment.instancesManager.instance(for: video) else { throw APIError.noInstance }
                try await appEnvironment.downloadManager.autoEnqueue(video, preferredAudioLanguage: language,
                    contentService: appEnvironment.contentService, instance: instance)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
