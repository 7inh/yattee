//
//  ListBackgroundStyle.swift
//  Yattee
//
//  Platform-specific background colors for list containers.
//

import SwiftUI

/// Background style variants for list containers.
///
/// Provides consistent platform-specific colors for grouped lists,
/// plain lists, and card backgrounds across iOS, macOS, and tvOS.
enum ListBackgroundStyle {
    /// Grouped background (systemGroupedBackground on iOS).
    /// Used as outer background for inset list style.
    case grouped

    /// Plain background (systemBackground on iOS).
    /// Used as outer background for plain list style.
    case plain

    /// Card/row background (secondarySystemGroupedBackground on iOS).
    /// Used for the card container in inset list style.
    case card

    /// Returns the platform-appropriate color for this background style.
    var color: Color {
        switch self {
        case .grouped:
            Color(uiColor: .systemGroupedBackground)

        case .plain:
            Color(uiColor: .systemBackground)

        case .card:
            Color(uiColor: .secondarySystemGroupedBackground)
        }
    }
}
