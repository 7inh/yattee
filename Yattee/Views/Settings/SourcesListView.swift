//
//  SourcesListView.swift
//  Yattee
//
//  Unified list of all sources (remote servers, WebDAV, local folders).
//

import SwiftUI

struct SourcesListView: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @State private var showingAddSheet = false
    @State private var sourceToEdit: UnifiedSource?

    // Delete confirmation state
    @State private var showingDeleteConfirmation = false
    @State private var pendingDeleteInstance: Instance?

    private var instancesManager: InstancesManager? {
        appEnvironment?.instancesManager
    }

    private var listStyle: VideoListStyle {
        appEnvironment?.settingsManager.listStyle ?? .inset
    }

    private var isEmpty: Bool { instancesManager?.instances.isEmpty ?? true }

    var body: some View {
        Group {
            sourcesInner
        }
        .navigationTitle(String(localized: "sources.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showAddButtonInToolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label(String(localized: "sources.addSource"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("sources.addButton")
                }
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddSourceView()
        }
        .sheet(item: $sourceToEdit) { source in
            EditSourceView(source: source)
        }
        .confirmationDialog(
            deleteConfirmationMessage,
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "common.delete"), role: .destructive) {
                confirmDelete()
            }
            Button(String(localized: "common.cancel"), role: .cancel) {
                pendingDeleteInstance = nil
            }
        } message: {
            // Deleting a source has always taken its logins with it; only the
            // question was silent about it.
            if let accounts = deleteConfirmationAccounts {
                Text(accounts)
            }
        }
        .presentationCompactAdaptation(.sheet)
    }

    /// Whether the "Add Source" button should be placed in the window/navigation
    /// toolbar. On macOS this only works reliably from macOS 26 onward (see
    /// `macOSLegacyAddHeader`); iOS always uses the toolbar.
    private var showAddButtonInToolbar: Bool {
        return true
    }

    @ViewBuilder
    private var sourcesInner: some View {
        if isEmpty {
            emptyState
        } else {
            sourcesList
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label(String(localized: "sources.empty.title"), systemImage: "server.rack")
        } description: {
            Text(String(localized: "sources.empty.description"))
        } actions: {
            Button(String(localized: "sources.addSource")) {
                showingAddSheet = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("sources.view")
    }

    // MARK: - Sources List

    private var sourcesList: some View {
        (listStyle == .inset ? ListBackgroundStyle.grouped.color : ListBackgroundStyle.plain.color)
            .ignoresSafeArea()
            .overlay(
                ScrollView {
                    LazyVStack(spacing: 0) {
                        remoteServersSection
                    }
                }
            )
    }

    // MARK: - Section Header

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, listStyle == .inset ? 32 : 16)
            .padding(.top, 16)
            .padding(.bottom, 8)
    }

    // MARK: - Section Card

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if listStyle == .inset {
            LazyVStack(spacing: 0) {
                content()
            }
            .background(ListBackgroundStyle.card.color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        } else {
            LazyVStack(spacing: 0) {
                content()
            }
            .padding(.bottom, 16)
        }
    }

    // MARK: - Remote Servers Section

    @ViewBuilder
    private var remoteServersSection: some View {
        if let manager = instancesManager, !manager.instances.isEmpty {
            sectionHeader(String(localized: "sources.section.remoteServers"))

            let instances = manager.instances.sorted { $0.dateAdded < $1.dateAdded }

            sectionCard {
                ForEach(Array(instances.enumerated()), id: \.element.id) { index, instance in
                    let isLast = index == instances.count - 1
                    instanceRowView(instance, isLast: isLast, isFirst: index == 0)
                }
            }
        }
    }

    @ViewBuilder
    private func instanceRowView(_ instance: Instance, isLast: Bool, isFirst: Bool = false) -> some View {
        SourceListRow(isLast: isLast, listStyle: listStyle) {
            Button {
                sourceToEdit = .remoteServer(instance)
            } label: {
                instanceRow(instance)
            }
            .foregroundStyle(.primary)
        }
        .swipeActions {
            SwipeAction(symbolImage: "pencil", tint: .white, background: .orange) { reset in
                sourceToEdit = .remoteServer(instance)
                reset()
            }
            SwipeAction(symbolImage: "trash", tint: .white, background: .red) { reset in
                pendingDeleteInstance = instance
                showingDeleteConfirmation = true
                reset()
            }
        }
        .contextMenu {
            Button {
                sourceToEdit = .remoteServer(instance)
            } label: {
                Label(String(localized: "common.edit"), systemImage: "pencil")
            }

            Button(role: .destructive) {
                pendingDeleteInstance = instance
                showingDeleteConfirmation = true
            } label: {
                Label(String(localized: "common.delete"), systemImage: "trash")
            }
        }
    }

    private func instanceRow(_ instance: Instance) -> some View {
        let rowSpacing: CGFloat = 12
        let iconFont: Font = .title2
        let iconFrameWidth: CGFloat = 32
        let titleFont: Font = .headline
        return HStack(spacing: rowSpacing) {
            Image(systemName: instance.type.systemImage)
                .font(iconFont)
                .foregroundStyle(.tint)
                .frame(width: iconFrameWidth)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(instance.displayName)
                        .font(titleFont)
                        .foregroundStyle(.primary)

                    if !instance.isEnabled {
                        Text("Disabled").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Text("\(instance.type.displayName) - \(instance.url.host ?? instance.url.absoluteString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                instanceStatusView(for: instance)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    /// Whether a remote server instance requires credentials that are missing from
    /// the Keychain (e.g. after reinstalling and importing sources from iCloud).
    private func needsCredentials(_ instance: Instance) -> Bool {
        appEnvironment?.needsCredentials(for: instance) ?? false
    }

    /// Whether one of this source's logins is being refused by the server, so a
    /// rejected login shows up where the user looks for their sources.
    private func hasRejectedAccount(_ instance: Instance) -> Bool {
        guard let accountsManager = appEnvironment?.accountsManager else { return false }

        return accountsManager.accounts(forInstance: instance.id).contains {
            accountsManager.status(for: $0.id) == .credentialRejected
        }
    }

    @ViewBuilder
    private func instanceStatusView(for instance: Instance) -> some View {
        // A refused login comes first: it names one thing the user has to do,
        // and two warnings stacked on one row say less than either alone.
        if hasRejectedAccount(instance) {
            Label(
                AccountStatusBadge.text(for: .credentialRejected),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.caption2)
            .foregroundStyle(AccountStatusBadge.color(for: .credentialRejected))
        } else if needsCredentials(instance) {
            Label(String(localized: "sources.status.authRequired"), systemImage: "key.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Actions

    private func confirmDelete() {
        if let instance = pendingDeleteInstance {
            appEnvironment?.removeInstance(instance)
            pendingDeleteInstance = nil
        }

    }

    private var deleteConfirmationMessage: String {
        if let instance = pendingDeleteInstance {
            return String(localized: "sources.delete.confirmation.single \(instance.displayName)")
        }
        return String(localized: "sources.delete.confirmation")
    }

    private var deleteConfirmationAccounts: String? {
        guard let instance = pendingDeleteInstance else { return nil }
        return InstanceDeletionDisclosure.message(for: instance, in: appEnvironment)
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SourcesListView()
    }
    .appEnvironment(.preview)
}
