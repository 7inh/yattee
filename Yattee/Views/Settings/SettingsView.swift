//
//  SettingsView.swift
//  Yattee
//
//  Main settings view.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    var showCloseButton: Bool = true


    var body: some View {
        iOSSettings
    }

    // MARK: - macOS Settings


    // MARK: - tvOS Settings


    // MARK: - iOS Settings

    private var iOSSettings: some View {
        NavigationStack {
            List {
                if let appEnvironment {
                    Section {
                    NavigationLink {
                        SourcesListView()
                    } label: {
                        HStack {
                            Label(String(localized: "sources.title"), systemImage: "server.rack")
                            Spacer()
                            if appEnvironment.mediaSourcesManager.hasSourcesNeedingPassword {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.row.sources")

                    if AccountsListView.showsSettingsEntry(in: appEnvironment) {
                        NavigationLink {
                            AccountsListView()
                        } label: {
                            HStack {
                                Label(String(localized: "accounts.title"), systemImage: "person.crop.circle")
                                Spacer()
                                if AccountsListView.needsAttention(in: appEnvironment) {
                                    Image(systemName: "exclamationmark.circle.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .accessibilityIdentifier("settings.row.accounts")
                    }
                    }

                    Section {
                        NavigationLink {
                            iCloudSettingsView()
                        } label: {
                            HStack {
                                Label(String(localized: "settings.icloud.title"), systemImage: "icloud")
                                if AppIdentifiers.isCloudKitDevelopmentEnvironment {
                                    Spacer()
                                    Text(String(localized: "settings.icloud.dev.badge"))
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.orange, in: Capsule())
                                }
                            }
                        }

                        NavigationLink {
                            AppearanceSettingsView()
                        } label: {
                            Label(String(localized: "settings.appearance.sectionTitle"), systemImage: "paintbrush")
                        }

                        NavigationLink {
                            LayoutNavigationSettingsView()
                        } label: {
                            Label(String(localized: "settings.layoutNavigation.title"), systemImage: "hand.tap")
                        }

                        NavigationLink {
                            PlaybackSettingsView()
                        } label: {
                            Label(String(localized: "settings.playback.sectionTitle"), systemImage: "play.circle")
                        }

                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            Label(String(localized: "settings.notifications.title"), systemImage: "bell.badge")
                        }

                        NavigationLink {
                            DownloadSettingsView()
                        } label: {
                            Label(String(localized: "settings.downloads.title"), systemImage: "arrow.down.circle")
                        }

                        NavigationLink {
                            PrivacySettingsView()
                        } label: {
                            Label(String(localized: "settings.privacy.title"), systemImage: "hand.raised")
                        }

                        if appEnvironment.instancesManager.enabledInstances.contains(where: \.isYouTubeInstance) {
                            NavigationLink {
                                YouTubeEnhancementsSettingsView()
                            } label: {
                                Label(String(localized: "settings.youtubeEnhancements.title"), systemImage: "puzzlepiece.extension")
                            }
                        }

                        NavigationLink {
                            AdvancedSettingsView()
                        } label: {
                            Label(String(localized: "settings.advanced.title"), systemImage: "gearshape.2")
                        }
                    }

                    Section {
                        NavigationLink {
                            AboutView()
                        } label: {
                            Label(String(localized: "settings.about.title"), systemImage: "info.circle")
                        }
                    }

                    Section {
                        VStack(spacing: 4) {
                            Text(verbatim: "Yattee")
                                .font(.headline)
                            Text("\(appVersion) (\(buildNumber))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle(String(localized: "settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showCloseButton {
                    sheetCloseToolbarItem(identifier: "settings.doneButton") { dismiss() }
                }
            }
            .accessibilityIdentifier("settings.view")
        }
    }

    // MARK: - App Info

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }
}

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case sources
    case accounts
    case icloud
    case appearance
    case layoutNavigation
    case playback
    case playerControls
    case notifications
    case downloads
    case privacy
    case youtubeEnhancements
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sources: return String(localized: "sources.title")
        case .accounts: return String(localized: "accounts.title")
        case .icloud: return String(localized: "settings.icloud.title")
        case .appearance: return String(localized: "settings.appearance.sectionTitle")
        case .layoutNavigation: return String(localized: "settings.layoutNavigation.title")
        case .playback: return String(localized: "settings.playback.sectionTitle")
        case .playerControls: return String(localized: "settings.playerControls.title")
        case .notifications: return String(localized: "settings.notifications.title")
        case .downloads: return String(localized: "settings.downloads.title")
        case .privacy: return String(localized: "settings.privacy.title")
        case .youtubeEnhancements: return String(localized: "settings.youtubeEnhancements.title")
        case .advanced: return String(localized: "settings.advanced.title")
        case .about: return String(localized: "settings.about.title")
        }
    }

    var icon: String {
        switch self {
        case .sources: return "server.rack"
        case .accounts: return "person.crop.circle"
        case .icloud: return "icloud"
        case .appearance: return "paintbrush"
        case .layoutNavigation: return "hand.tap"
        case .playback: return "play.circle"
        case .playerControls: return "slider.horizontal.below.rectangle"
        case .notifications: return "bell.badge"
        case .downloads: return "arrow.down.circle"
        case .privacy: return "hand.raised"
        case .youtubeEnhancements: return "puzzlepiece.extension"
        case .advanced: return "gearshape.2"
        case .about: return "info.circle"
        }
    }
}

#Preview {
    SettingsView()
        .appEnvironment(.preview)
}
