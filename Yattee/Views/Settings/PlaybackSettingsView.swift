//
//  PlaybackSettingsView.swift
//  Yattee
//
//  Playback settings view with quality and behavior preferences.
//

import SwiftUI

struct PlaybackSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment

    var body: some View {
        SettingsFormContainer {
            if let settings = appEnvironment?.settingsManager {
                AudioSection(settings: settings)
                BehaviorSection(settings: settings)
                SystemControlsSection(settings: settings)
                QueueSection(settings: settings)
            }
        }
        // Observed on the always-present form: an observer on the hidden
        // section itself would have no view to attach to and never fire.
        .navigationTitle(String(localized: "settings.playback.title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Audio Section

private struct AudioSection: View {
    @Bindable var settings: SettingsManager

    // All YouTube-supported language codes, sorted alphabetically by localized name
    static let languageCodes: [String] = [
        "af", // Afrikaans
        "am", // Amharic
        "ar", // Arabic
        "az", // Azerbaijani
        "be", // Belarusian
        "bg", // Bulgarian
        "bn", // Bengali
        "bs", // Bosnian
        "ca", // Catalan
        "cs", // Czech
        "cy", // Welsh
        "da", // Danish
        "de", // German
        "el", // Greek
        "en", // English
        "es", // Spanish
        "et", // Estonian
        "eu", // Basque
        "fa", // Persian
        "fi", // Finnish
        "fil", // Filipino
        "fr", // French
        "gl", // Galician
        "gu", // Gujarati
        "he", // Hebrew
        "hi", // Hindi
        "hr", // Croatian
        "hu", // Hungarian
        "hy", // Armenian
        "id", // Indonesian
        "is", // Icelandic
        "it", // Italian
        "ja", // Japanese
        "ka", // Georgian
        "kk", // Kazakh
        "km", // Khmer
        "kn", // Kannada
        "ko", // Korean
        "ky", // Kyrgyz
        "lo", // Lao
        "lt", // Lithuanian
        "lv", // Latvian
        "mk", // Macedonian
        "ml", // Malayalam
        "mn", // Mongolian
        "mr", // Marathi
        "ms", // Malay
        "my", // Burmese
        "ne", // Nepali
        "nl", // Dutch
        "no", // Norwegian
        "or", // Odia
        "pa", // Punjabi
        "pl", // Polish
        "pt", // Portuguese
        "ro", // Romanian
        "ru", // Russian
        "si", // Sinhala
        "sk", // Slovak
        "sl", // Slovenian
        "sq", // Albanian
        "sr", // Serbian
        "sv", // Swedish
        "sw", // Swahili
        "ta", // Tamil
        "te", // Telugu
        "th", // Thai
        "tr", // Turkish
        "uk", // Ukrainian
        "ur", // Urdu
        "uz", // Uzbek
        "vi", // Vietnamese
        "zh", // Chinese
        "zu", // Zulu
    ]

    // Generate sorted list of (code, localizedName) tuples
    private var sortedLanguages: [(code: String, name: String)] {
        Self.languageCodes
            .map { code in
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
                return (code: code, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        SettingsFormSection("settings.playback.audio.header") {
            Picker(
                String(localized: "settings.playback.audio.preferredLanguage"),
                selection: Binding(
                    get: { settings.preferredAudioLanguage ?? "" },
                    set: { settings.preferredAudioLanguage = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text(String(localized: "settings.playback.audio.original"))
                    .tag("")

                Divider()

                ForEach(sortedLanguages, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
        }
    }
}

// Volume and System Controls settings are in Player Controls settings

// MARK: - Behavior Section

private struct BehaviorSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        let footer: LocalizedStringKey? = nil

        SettingsFormSection("settings.playback.behavior.header", footer: footer) {

            PlatformMenuPicker(
                String(localized: "settings.playback.resumeAction"),
                selection: $settings.resumeAction
            ) {
                ForEach(ResumeAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }

            // macOS never suspends apps, so playback always continues in the
            // background — the toggle would have no effect there
            Toggle(
                String(localized: "settings.playback.backgroundPlayback"),
                isOn: $settings.backgroundPlaybackEnabled
            )

        }
    }
}

// MARK: - System Controls Section

/// Skip interval for the Lock Screen / Control Center seek buttons.
private struct SystemControlsSection: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection(
            "settings.playback.systemControls.header",
            footer: "settings.playback.systemControls.seek.footer"
        ) {
            PlatformMenuPicker(
                String(localized: "settings.playback.systemControls.seekDuration"),
                selection: $settings.systemControlsSeekDuration
            ) {
                ForEach(SystemControlsSeekDuration.allCases, id: \.self) { duration in
                    Text(duration.displayName).tag(duration)
                }
            }
        }
        .onChange(of: settings.systemControlsSeekDuration) { _, newValue in
            appEnvironment?.playerService.reconfigureSystemControls(duration: newValue)
        }
    }
}

// MARK: - TV Display Matching Section


// MARK: - Queue Section

private struct QueueSection: View {
    @Bindable var settings: SettingsManager

    var body: some View {
        SettingsFormSection("settings.playback.queue.header") {
            Toggle(
                String(localized: "settings.playback.queue.enabled"),
                isOn: $settings.queueEnabled
            )

            Stepper(
                value: $settings.queueAutoPlayCountdown,
                in: 1...15
            ) {
                HStack {
                    Text(String(localized: "settings.playback.queue.autoPlayCountdown"))
                    Spacer()
                    Text("\(settings.queueAutoPlayCountdown)s")
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!settings.queueEnabled)
        }
    }
}

// MARK: - VideoQuality Extension

extension VideoQuality {
    var displayName: String {
        switch self {
        case .auto: return String(localized: "settings.playback.quality.best")
        case .hd4k: return "4K"
        case .hd1440p: return "1440p"
        case .hd1080p: return "1080p"
        case .hd720p: return "720p"
        case .sd480p: return "480p"
        case .sd360p: return "360p"
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PlaybackSettingsView()
    }
    .appEnvironment(.preview)
}
