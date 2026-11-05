//
//  AddSourceView.swift
//  Yattee
//
//  Opens the remote server form directly on iOS and presents source type
//  selection with dedicated forms on other platforms.
//

import SwiftUI

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    // Network discovery sheet
    @State private var showingNetworkDiscovery = false
    @State private var selectedShareType: DiscoveredShare.ShareType?

    // Navigation destinations from network discovery
    @State private var navigateToWebDAV = false
    @State private var navigateToSMB = false
    @State private var discoveredWebDAVURL: URL?
    @State private var discoveredSMBServer: String?
    @State private var discoveredName: String?
    @State private var discoveredAllowInvalidCerts = false
    @State private var hasLegacyAccountsToImport = false

    var body: some View {
        NavigationStack {
            AddRemoteServerView(dismissSheet: dismiss)
                .toolbar {
                    sheetCloseToolbarItem { dismiss() }
                }
        }
    }

    private var listContent: some View {
        List {
            if hasLegacyAccountsToImport {
                Section {
                    NavigationLink {
                        LegacyAccountsImportView(showsDoneButton: false)
                    } label: {
                        Label(String(localized: "migration.accounts.addSourcesLink"), systemImage: "person.badge.key")
                    }
                } footer: {
                    Text(String(localized: "migration.accounts.addSourcesFooter"))
                }
            }

            Section {
                NavigationLink {
                    AddLocalFolderView(dismissSheet: dismiss)
                } label: {
                    Label(String(localized: "sources.addLocalFolder"), systemImage: "folder")
                }

                NavigationLink {
                    AddWebDAVView(dismissSheet: dismiss)
                } label: {
                    Label(String(localized: "sources.addWebDAV"), systemImage: "externaldrive.connected.to.line.below")
                }

                NavigationLink {
                    AddSMBView(dismissSheet: dismiss)
                } label: {
                    Label(String(localized: "sources.addSMB"), systemImage: "server.rack")
                }

                NavigationLink {
                    AddRemoteServerView(dismissSheet: dismiss)
                } label: {
                    Label(String(localized: "sources.addRemoteServer"), systemImage: "globe")
                }

                NavigationLink {
                    if let appEnvironment {
                        PeerTubeInstancesExploreView()
                            .appEnvironment(appEnvironment)
                    }
                } label: {
                    Label {
                        Text(String(localized: "sources.browsePeerTube"))
                    } icon: {
                        Image("peertube")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 24, height: 24)
                    }
                }
            }

            Section {
                Button {
                    selectedShareType = nil
                    showingNetworkDiscovery = true
                } label: {
                    Label(String(localized: "discovery.scanNetwork"), systemImage: "wifi")
                }
            } footer: {
                Text(String(localized: "sources.footer.discovery"))
            }
        }
        .task {
            refreshLegacyAccountsVisibility()
        }
        .onChange(of: appEnvironment?.legacyMigrationService.legacyDataRevision ?? 0) {
            refreshLegacyAccountsVisibility()
        }
    }

    private func handleSelectedShare(_ share: DiscoveredShare) {
        discoveredName = share.name

        switch share.type {
        case .webdav, .webdavs:
            discoveredWebDAVURL = share.url
            discoveredAllowInvalidCerts = share.type == .webdavs
            navigateToWebDAV = true

        case .smb:
            discoveredSMBServer = share.host
            navigateToSMB = true
        }
    }

    private func refreshLegacyAccountsVisibility() {
        hasLegacyAccountsToImport = appEnvironment?.legacyMigrationService.hasLegacyDataToImport() == true
    }
}

// MARK: - Preview

#Preview {
    AddSourceView()
        .appEnvironment(.preview)
}
