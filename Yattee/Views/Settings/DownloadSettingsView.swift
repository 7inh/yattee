//
//  DownloadSettingsView.swift
//  Yattee
//
//  Settings view for download configuration.
//

import SwiftUI

struct DownloadSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let downloadSettings = appEnvironment?.downloadSettings,
               let downloadManager = appEnvironment?.downloadManager {
                StorageSection(downloadManager: downloadManager)
                ConcurrencySection(downloadSettings: downloadSettings)
                CellularSection(
                    downloadSettings: downloadSettings,
                    downloadManager: downloadManager
                )
            }
        }
        .navigationTitle(String(localized: "settings.downloads.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Storage Section

private struct StorageSection: View {
    let downloadManager: DownloadManager

    private var storageUsed: Int64 {
        downloadManager.storageUsed
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        SettingsFormSection {
            NavigationLink {
                DownloadsStorageView()
            } label: {
                HStack {
                    Text(String(localized: "settings.downloads.usedStorage"))
                    Spacer()
                    Text(formatBytes(storageUsed))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Concurrency Section

private struct ConcurrencySection: View {
    @Bindable var downloadSettings: DownloadSettings

    var body: some View {
        SettingsFormSection {
            Stepper(value: $downloadSettings.maxConcurrentDownloads, in: 1...5) {
                HStack {
                    Text(String(localized: "settings.downloads.maxConcurrent"))
                    Spacer()
                    Text("\(downloadSettings.maxConcurrentDownloads)")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Cellular Section

private struct CellularSection: View {
    @Bindable var downloadSettings: DownloadSettings
    let downloadManager: DownloadManager?

    var body: some View {
        SettingsFormSection(footer: "settings.downloads.allowCellular.footer") {
            Toggle(
                String(localized: "settings.downloads.allowCellular"),
                isOn: $downloadSettings.allowCellularDownloads
            )
            .onChange(of: downloadSettings.allowCellularDownloads) {
                downloadManager?.refreshCellularAccessSetting()
            }
        }
    }
}

#Preview {
    NavigationStack {
        DownloadSettingsView()
    }
    .appEnvironment(.preview)
}
