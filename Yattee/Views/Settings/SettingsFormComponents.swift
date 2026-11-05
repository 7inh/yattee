//
//  SettingsFormComponents.swift
//  Yattee
//
//  Shared iOS settings form, section, and navigation components.
//

import SwiftUI

/// Root form container for settings screens.
struct SettingsFormContainer<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
    }
}

extension View {
    /// Kept for existing form callers during the UI migration.
    func opaqueSettingsFormBackground() -> some View {
        return self
    }
}

/// A settings section with a header and optional footer.
struct SettingsFormSection<Content: View, Footer: View>: View {
    let header: LocalizedStringKey?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        platformSection
    }

    @ViewBuilder
    private var platformSection: some View {
        if let header {
            Section {
                content()
            } header: {
                Text(header)
            } footer: {
                footer()
            }
        } else {
            Section {
                content()
            } footer: {
                footer()
            }
        }
    }
}

extension SettingsFormSection where Footer == EmptyView {
    init(
        _ header: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.content = content
        self.footer = { EmptyView() }
    }
}

extension SettingsFormSection where Footer == Text {
    init(
        _ header: LocalizedStringKey? = nil,
        footer: LocalizedStringKey,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.content = content
        self.footer = { Text(footer) }
    }

    init(
        _ header: LocalizedStringKey? = nil,
        footer: LocalizedStringKey?,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.header = header
        self.content = content
        let footerKey = footer
        self.footer = { footerKey.map { Text($0) } ?? Text(verbatim: "") }
    }
}

extension SettingsFormSection {
    init(
        _ header: LocalizedStringKey? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.header = header
        self.content = content
        self.footer = footer
    }
}

/// A label style that forces the icon to a fixed width so adjacent
/// labels align regardless of icon glyph width. Use when a section has
/// a vertical stack of `Label`s with mixed-width SF Symbols.
struct FixedIconWidthLabelStyle: LabelStyle {
    var iconWidth: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon
                .frame(width: iconWidth, alignment: .center)
            configuration.title
        }
    }
}

/// A settings row that pushes a destination onto the navigation stack.
struct SettingsNavigationRow<Destination: View, Trailing: View>: View {
    let titleKey: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var destination: () -> Destination

    init(
        _ titleKey: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder destination: @escaping () -> Destination
    ) {
        self.titleKey = titleKey
        self.systemImage = systemImage
        self.trailing = trailing
        self.destination = destination
    }

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(titleKey, systemImage: systemImage)
                Spacer()
                trailing()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
