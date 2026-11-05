//
//  SubtitleSettings.swift
//  Yattee
//
//  Settings for subtitle appearance in player player.
//

import Foundation

// MARK: - Subtitle Font

/// Font options for subtitles.
enum SubtitleFont: String, Codable, Hashable, Sendable, CaseIterable {
    case sansSerif
    case serif
    case monospaced

    /// Display name for the UI.
    var displayName: String {
        switch self {
        case .sansSerif:
            return String(localized: "settings.subtitles.font.sansSerif")
        case .serif:
            return String(localized: "settings.subtitles.font.serif")
        case .monospaced:
            return String(localized: "settings.subtitles.font.monospaced")
        }
    }

}


// MARK: - Subtitle Settings

/// Settings for subtitle appearance in player.
struct SubtitleSettings: Codable, Hashable, Sendable {
    /// Font for subtitles.
    var font: SubtitleFont

    /// Font size for subtitles (in points, 20-100).
    var fontSize: Int

    /// Text color for subtitles.
    var textColor: CodableColor

    /// Border (outline) color for subtitles.
    var borderColor: CodableColor

    /// Border size (0-5).
    var borderSize: Double

    /// Background color for subtitles (when showBackground is enabled).
    var backgroundColor: CodableColor

    /// Whether to show a background box behind subtitles.
    var showBackground: Bool

    /// Whether text is bold.
    var isBold: Bool

    /// Whether text is italic.
    var isItalic: Bool

    /// Bottom margin as percentage (0-50).
    var bottomMargin: Int

    /// Creates subtitle settings with default values.
    init(
        font: SubtitleFont = .sansSerif,
        fontSize: Int = 60,
        textColor: CodableColor = CodableColor(red: 1, green: 1, blue: 1),
        borderColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0),
        borderSize: Double = 2.5,
        backgroundColor: CodableColor = CodableColor(red: 0, green: 0, blue: 0, opacity: 0.75),
        showBackground: Bool = false,
        isBold: Bool = false,
        isItalic: Bool = false,
        bottomMargin: Int = 30
    ) {
        self.font = font
        self.fontSize = fontSize
        self.textColor = textColor
        self.borderColor = borderColor
        self.borderSize = borderSize
        self.backgroundColor = backgroundColor
        self.showBackground = showBackground
        self.isBold = isBold
        self.isItalic = isItalic
        self.bottomMargin = bottomMargin
    }

    /// Default subtitle settings.
    static let `default` = SubtitleSettings()

}
