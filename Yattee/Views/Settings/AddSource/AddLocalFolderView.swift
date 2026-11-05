//
//  AddLocalFolderView.swift
//  Yattee
//
//  View for adding a local folder as a media source.
//

import SwiftUI

struct AddLocalFolderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    // MARK: - State

    @State private var name = ""
    @State private var selectedFolderURL: URL?
    @State private var testResult: SourceTestResult?

    @State private var showingFolderPicker = false

    // Closure to dismiss the parent sheet
    var dismissSheet: DismissAction?

    // MARK: - Computed Properties

    private var canAdd: Bool {
        !name.isEmpty && selectedFolderURL != nil
    }

    /// macOS surfaces toolbar confirmation items from a pushed-in-sheet view
    /// reliably only from macOS 26 onward. On older macOS we render the
    /// "Add Source" action button inline in the form instead.
    private var usesToolbarActionButton: Bool {
        return false
    }

    // MARK: - Body

    var body: some View {
        Form {
            nameSection
            folderSection

            if let result = testResult {
                SourceTestResultSection(result: result)
            }

            actionSection
        }
        .navigationTitle(String(localized: "sources.addLocalFolder"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerView { url in
                handleFolderSelection(url)
            }
        }
    }


    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField(String(localized: "sources.field.name"), text: $name)
        } footer: {
            Text(String(localized: "sources.footer.displayName"))
        }
    }

    private var folderSection: some View {
        Section {
            Button {
                showingFolderPicker = true
            } label: {
                HStack {
                    if let url = selectedFolderURL {
                        Label(url.lastPathComponent, systemImage: "folder.fill")
                    } else {
                        Label(String(localized: "sources.selectFolder"), systemImage: "folder.badge.plus")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text(String(localized: "sources.header.folder"))
        } footer: {
            Text(String(localized: "sources.footer.folder"))
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                addSource()
            } label: {
                Text(String(localized: "sources.addSource"))
            }
            .disabled(!canAdd)
        }
    }

    // MARK: - Actions

    private func handleFolderSelection(_ url: URL) {
        selectedFolderURL = url
        if name.isEmpty {
            name = url.lastPathComponent
        }
    }


    private func addSource() {
        guard let appEnvironment,
              let url = selectedFolderURL else { return }

        Task {
            do {
                let bookmarkData = try await appEnvironment.localFileClient.createBookmark(for: url)

                await MainActor.run {
                    let source = MediaSource.localFolder(
                        name: name,
                        url: url,
                        bookmarkData: bookmarkData
                    )
                    appEnvironment.mediaSourcesManager.add(source)
                    if let dismissSheet {
                        dismissSheet()
                    } else {
                        dismiss()
                    }
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(String(localized: "sources.error.folderAccess \(error.localizedDescription)"))
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        AddLocalFolderView()
            .appEnvironment(.preview)
    }
}
