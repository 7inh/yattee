//
//  SubtitlesSettingsView.swift
//  Yattee
//
//  Settings view for configuring subtitle appearance in player player.
//

import SwiftUI

struct SubtitlesSettingsView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var settings: SubtitleSettings = .default

    var body: some View {
        SettingsFormContainer {
            fontSection
            colorsSection
            styleSection
            positionSection
            resetSection
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(String(localized: "settings.subtitles.title"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let settingsManager = appEnvironment?.settingsManager {
                settings = settingsManager.subtitleSettings
            }
        }
    }

    // MARK: - Font Section

    private var fontSection: some View {
        SettingsFormSection {
            PlatformMenuPicker(
                String(localized: "settings.subtitles.font"),
                selection: $settings.font
            ) {
                ForEach(SubtitleFont.allCases, id: \.self) { font in
                    Text(font.displayName).tag(font)
                }
            }
            .onChange(of: settings.font) { _, _ in saveSettings() }

            VStack(alignment: .leading) {
                Text(String(localized: "settings.subtitles.fontSize"))
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(settings.fontSize) },
                            set: { settings.fontSize = Int($0) }
                        ),
                        in: 20...100,
                        step: 1
                    )
                    .onChange(of: settings.fontSize) { _, _ in saveSettings() }
                    TextField("", value: $settings.fontSize, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                        .multilineTextAlignment(.center)
                        .onChange(of: settings.fontSize) { _, _ in saveSettings() }
                    Text(String(localized: "common.unit.points"))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Colors Section

    private var colorsSection: some View {
        SettingsFormSection("settings.subtitles.colorsSection") {
            ColorPicker(
                String(localized: "settings.subtitles.textColor"),
                selection: Binding(
                    get: { settings.textColor.color },
                    set: {
                        settings.textColor = CodableColor($0)
                        saveSettings()
                    }
                ),
                supportsOpacity: false
            )

            ColorPicker(
                String(localized: "settings.subtitles.borderColor"),
                selection: Binding(
                    get: { settings.borderColor.color },
                    set: {
                        settings.borderColor = CodableColor($0)
                        saveSettings()
                    }
                ),
                supportsOpacity: false
            )

            VStack(alignment: .leading) {
                Text(String(localized: "settings.subtitles.borderSize"))
                HStack {
                    Slider(value: $settings.borderSize, in: 0...5, step: 0.5)
                        .onChange(of: settings.borderSize) { _, _ in saveSettings() }
                    Text(String(format: "%.1f", settings.borderSize))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 30)
                }
            }

            Toggle(
                String(localized: "settings.subtitles.showBackground"),
                isOn: $settings.showBackground
            )
            .onChange(of: settings.showBackground) { _, _ in saveSettings() }

            if settings.showBackground {
                ColorPicker(
                    String(localized: "settings.subtitles.backgroundColor"),
                    selection: Binding(
                        get: { settings.backgroundColor.color },
                        set: {
                            settings.backgroundColor = CodableColor($0)
                            saveSettings()
                        }
                    ),
                    supportsOpacity: true
                )
            }
        }
    }

    // MARK: - Style Section

    private var styleSection: some View {
        SettingsFormSection("settings.subtitles.styleSection") {
            Toggle(
                String(localized: "settings.subtitles.bold"),
                isOn: $settings.isBold
            )
            .onChange(of: settings.isBold) { _, _ in saveSettings() }

            Toggle(
                String(localized: "settings.subtitles.italic"),
                isOn: $settings.isItalic
            )
            .onChange(of: settings.isItalic) { _, _ in saveSettings() }
        }
    }

    // MARK: - Position Section

    private var positionSection: some View {
        SettingsFormSection("settings.subtitles.positionSection", footer: "settings.subtitles.positionFooter") {
            Stepper(
                String(localized: "settings.subtitles.bottomMargin \(settings.bottomMargin)"),
                value: $settings.bottomMargin,
                in: 0...50,
                step: 5
            )
            .onChange(of: settings.bottomMargin) { _, _ in saveSettings() }
        }
    }

    // MARK: - Reset Section

    private var resetSection: some View {
        SettingsFormSection {
            Button(role: .destructive) {
                settings = .default
                saveSettings()
            } label: {
                HStack {
                    Spacer()
                    Text(String(localized: "settings.subtitles.resetToDefaults"))
                    Spacer()
                }
            }
        }
    }

    // MARK: - tvOS Helpers


    // MARK: - Helpers

    private func saveSettings() {
        appEnvironment?.settingsManager.subtitleSettings = settings

        // Apply changes to active player player immediately
    }
}

// MARK: - tvOS Color Presets


// MARK: - Preview

#Preview {
    NavigationStack {
        SubtitlesSettingsView()
    }
    .appEnvironment(.preview)
}
