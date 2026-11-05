//
//  HomeShortcutCardView.swift
//  Yattee
//
//  Card component for home shortcuts.
//

import SwiftUI

struct HomeShortcutCardView<StatusIndicator: View>: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Position-resolved colorful color; when set it overrides `colorfulColor`.
    @Environment(\.homeShortcutColorfulColor) private var positionColorfulColor

    private var accentColor: Color {
        appEnvironment?.settingsManager.resolvedAccentColor ?? .accentColor
    }

    let icon: String
    let title: String
    let count: Int
    let subtitle: String
    /// Whether to show the count number in the filled (Reminders) layout.
    /// Cards without a meaningful count (Open Link, Remote, Subscriptions) hide it.
    var showsCount: Bool
    /// Palette-resolved color for this card (from position/palette). Used as the
    /// tint in Soft and the solid fill in Vibrant.
    var colorfulColor: Color
    /// Explicit layout override. When set, takes precedence over the global
    /// setting — used to render live previews of a not-yet-saved layout.
    var styleOverride: HomeShortcutCardStyle?
    /// Explicit color override. When set, takes precedence over the global
    /// setting — used to render live previews of a not-yet-saved color.
    var colorOverride: HomeShortcutCardColor?
    var statusIndicator: StatusIndicator?

    init(
        icon: String,
        title: String,
        count: Int,
        subtitle: String,
        showsCount: Bool = true,
        colorfulColor: Color = .accentColor,
        styleOverride: HomeShortcutCardStyle? = nil,
        colorOverride: HomeShortcutCardColor? = nil,
        statusIndicator: StatusIndicator?
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.subtitle = subtitle
        self.showsCount = showsCount
        self.colorfulColor = colorfulColor
        self.styleOverride = styleOverride
        self.colorOverride = colorOverride
        self.statusIndicator = statusIndicator
    }

    // MARK: - Card Style

    private var cardStyle: HomeShortcutCardStyle {
        return styleOverride ?? (appEnvironment?.settingsManager.homeShortcutCardStyle ?? .regular)
    }

    private var cardColor: HomeShortcutCardColor {
        return colorOverride ?? (appEnvironment?.settingsManager.homeShortcutCardColor ?? .soft)
    }

    private var isVibrant: Bool {
        cardColor == .vibrant
    }

    /// Palette-resolved color injected via the environment (the Accent palette
    /// injects the accent color). Used as the tint in Soft and the fill in Vibrant.
    private var paletteColor: Color {
        positionColorfulColor ?? colorfulColor
    }

    private var iconColor: Color {
        isVibrant ? .white : paletteColor
    }

    private var titleColor: Color {
        isVibrant ? .white : .primary
    }

    private var subtitleColor: Color {
        isVibrant ? Color.white.opacity(0.85) : .secondary
    }

    // Platform-specific styling
    private let iconSize: CGFloat = 28
    private let titleFont: Font = .subheadline
    private let subtitleFont: Font = .caption.monospacedDigit()
    private let hPadding: CGFloat = 12
    private let vPadding: CGFloat = 12
    private let cornerRadius: CGFloat = 16

    private var needsVerticalLayout: Bool {
        return dynamicTypeSize >= .xxxLarge
    }

    /// The Regular layout is the Reminders-style card:
    /// icon top-leading, count top-trailing, title at the bottom.
    private var useRemindersLayout: Bool {
        return cardStyle == .regular
    }

    private var hasSubtitle: Bool {
        !subtitle.isEmpty
    }

    var body: some View {
        Group {
            if useRemindersLayout {
                remindersLayout
            } else if needsVerticalLayout {
                // Vertical layout for tvOS and accessibility sizes
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                        .frame(width: iconSize)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(title)
                                .font(titleFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(titleColor)
                            if let statusIndicator {
                                statusIndicator.padding(.leading, 4)
                            }
                        }

                        Text(hasSubtitle ? subtitle : " ")
                            .font(subtitleFont)
                            .foregroundStyle(subtitleColor)
                            .opacity(hasSubtitle ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Horizontal layout for standard sizes
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundStyle(iconColor)
                        .frame(width: iconSize)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(title)
                                .font(titleFont)
                                .fontWeight(.semibold)
                                .foregroundStyle(titleColor)
                                .allowsTightening(true)
                                .lineLimit(1)
                            if let statusIndicator {
                                statusIndicator.padding(.leading, 4)
                            }
                        }

                        if hasSubtitle {
                            Text(subtitle)
                                .font(subtitleFont)
                                .foregroundStyle(subtitleColor)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .frame(minHeight: subtitleMinHeight)
            }
        }
        .padding(.horizontal, hPadding)
        .padding(.vertical, vPadding)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    /// Reminders-style layout used by the Regular layout:
    /// icon top-leading, count top-trailing, title anchored to the bottom.
    private var remindersLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(iconColor)

                Spacer(minLength: 4)

                if let statusIndicator {
                    statusIndicator
                }

                if showsCount {
                    Text(count, format: .number)
                        .font(.title2)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(title)
                .font(titleFont)
                .fontWeight(.semibold)
                .foregroundStyle(titleColor)
                .lineLimit(1)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: remindersMinHeight, alignment: .leading)
    }

    /// Minimum height for the text content area to ensure consistent card heights
    private var subtitleMinHeight: CGFloat {
        // subheadline + caption + spacing
        34
    }

    /// Minimum content height for the Reminders-style layout so the title sits
    /// well below the icon/count row (matches Apple's roomier card proportions).
    private var remindersMinHeight: CGFloat {
        60
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isVibrant {
            // Solid fill plus a subtle top-to-bottom sheen for a gentle gradient.
            paletteColor.overlay(
                LinearGradient(
                    colors: [Color.white.opacity(0.28), Color.clear, Color.black.opacity(0.10)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            paletteColor.opacity(0.1)
        }
    }

    private var borderColor: Color {
        return isVibrant ? .clear : paletteColor.opacity(0.3)
    }
}

// MARK: - Convenience Initializer (no status indicator)

extension HomeShortcutCardView where StatusIndicator == EmptyView {
    init(
        icon: String,
        title: String,
        count: Int,
        subtitle: String,
        showsCount: Bool = true,
        colorfulColor: Color = .accentColor,
        styleOverride: HomeShortcutCardStyle? = nil,
        colorOverride: HomeShortcutCardColor? = nil
    ) {
        self.icon = icon
        self.title = title
        self.count = count
        self.subtitle = subtitle
        self.showsCount = showsCount
        self.colorfulColor = colorfulColor
        self.styleOverride = styleOverride
        self.colorOverride = colorOverride
        self.statusIndicator = nil
    }
}
