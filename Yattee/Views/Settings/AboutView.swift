//
//  AboutView.swift
//  Yattee
//
//  About section containing app information and acknowledgements.
//

import SwiftUI

struct AboutView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsFormContainer {
            SettingsFormSection("settings.about.community") {
                communityLink("GitHub", icon: "github", url: "https://github.com/yattee/yattee")
                communityLink("Discord", icon: "discord", url: "https://yattee.stream/discord")
            }

            SettingsFormSection {
                SettingsNavigationRow("settings.contributors.title", systemImage: "person.3") {
                    ContributorsView()
                }
                SettingsNavigationRow("settings.translators.title", systemImage: "globe") {
                    TranslationContributorsView()
                }
                SettingsNavigationRow("settings.acknowledgements.title", systemImage: "heart.text.square") {
                    AcknowledgementsView()
                }
            }

            SettingsFormSection {
                SettingsNavigationRow("settings.advanced.deviceCapabilities", systemImage: "cpu") {
                    DeviceCapabilitiesView()
                }
            }

            versionInfoSection
        }
        .navigationTitle(String(localized: "settings.about.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    @ViewBuilder
    private var versionInfoSection: some View {
        SettingsFormSection("settings.about.versionInfo") {
            versionInfoRow(label: String(localized: "settings.advanced.debug.appVersion"), value: appVersion)
            versionInfoRow(label: String(localized: "settings.advanced.debug.buildNumber"), value: buildNumber)
            versionInfoRow(label: String(localized: "settings.advanced.debug.buildDate"), value: buildDate)
            versionInfoRow(label: String(localized: "settings.advanced.debug.osVersion"), value: osVersion)
        }
    }

    @ViewBuilder
    private func versionInfoRow(label: String, value: String) -> some View {
        LabeledContent(label) {
            Text(value)
        }
    }

    // MARK: - Helpers

    private func communityLink(_ name: String, icon: String, url: String) -> some View {
        Button {
            if let url = URL(string: url) {
                openURL(url)
            }
        } label: {
            HStack {
                Label {
                    Text(name)
                } icon: {
                    Image(icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Computed Properties

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var buildDate: String {
        guard let executableURL = Bundle.main.executableURL,
              let date = (try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var osVersion: String {
        return "iOS \(UIDevice.current.systemVersion)"
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
