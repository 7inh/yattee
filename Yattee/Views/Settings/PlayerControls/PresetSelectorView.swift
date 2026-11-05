//
//  PresetSelectorView.swift
//  Yattee
//
//  View for selecting and managing player controls presets.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export File Wrapper

private struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Pending preset creation request
private struct PendingPresetCreation: Equatable {
    let name: String
    let basePresetID: UUID?
}

/// Pending preset rename request
private struct PendingPresetRename: Equatable {
    let presetID: UUID
    let newName: String
}

/// Notification posted when a preset is selected in PresetSelectorView
extension Notification.Name {
    static let presetSelectionDidChange = Notification.Name("presetSelectionDidChange")
}

/// View for selecting and managing player controls layout presets.
struct PresetSelectorView: View {
    @Bindable var viewModel: PlayerControlsSettingsViewModel
    var onPresetSelected: ((String) -> Void)?

    @State private var showCreateSheet = false
    @State private var presetToRename: LayoutPreset?
    @State private var pendingCreation: PendingPresetCreation?
    @State private var pendingRename: PendingPresetRename?
    @State private var listRefreshID = UUID()

    // Track active preset ID locally to force view updates
    @State private var trackedActivePresetID: UUID?

    // Import/Export state
    @State private var showingImportPicker = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showingImportError = false
    @State private var importedPresetName: String?
    @State private var showingImportSuccess = false
    @State private var exportFile: ExportFile?

    var body: some View {
        presetList
            .opaqueSettingsFormBackground()
            .navigationTitle(String(localized: "settings.playerControls.presets"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .sheet(isPresented: $showCreateSheet) { createPresetSheet }
            .sheet(item: $presetToRename) { preset in renamePresetSheet(preset) }
            .sheet(isPresented: $showingImportPicker) { importPickerSheet }
            .sheet(item: $exportFile) { file in ShareSheet(items: [file.url]) }
            .alert(
                String(localized: "settings.playerControls.import.error.title"),
                isPresented: $showingImportError
            ) {
                Button(String(localized: "settings.playerControls.ok")) {}
            } message: {
                if let error = importError {
                    Text(error)
                }
            }
            .alert(
                String(localized: "settings.playerControls.import.success.title"),
                isPresented: $showingImportSuccess
            ) {
                Button(String(localized: "settings.playerControls.ok")) {}
            } message: {
                if let name = importedPresetName {
                    Text(String(localized: "settings.playerControls.import.success.message \(name)"))
                }
            }
            .task(id: pendingCreation) {
                guard let creation = pendingCreation else { return }
                let basePreset = creation.basePresetID.flatMap { id in
                    viewModel.presets.first { $0.id == id }
                }
                await viewModel.createPreset(name: creation.name, basedOn: basePreset)
                pendingCreation = nil
                // Force view update by updating local tracked state
                trackedActivePresetID = viewModel.activePreset?.id
                listRefreshID = UUID()
                // Notify parent of selection change
                if let name = viewModel.activePreset?.name {
                    onPresetSelected?(name)
                    NotificationCenter.default.post(name: .presetSelectionDidChange, object: name)
                }
            }
            .task(id: pendingRename) {
                guard let rename = pendingRename else { return }
                if let preset = viewModel.presets.first(where: { $0.id == rename.presetID }) {
                    await viewModel.renamePreset(preset, to: rename.newName)
                }
                pendingRename = nil
                listRefreshID = UUID()
            }
            .onAppear {
                trackedActivePresetID = viewModel.activePreset?.id
            }
    }

    // MARK: - View Components

    private var presetList: some View {
        List {
            builtInPresetsSection
            customPresetsSection
        }
        .id(listRefreshID)
    }

    private var builtInPresetsSection: some View {
        Section {
            ForEach(viewModel.builtInPresets) { preset in
                PresetRow(
                    preset: preset,
                    isActive: preset.id == trackedActivePresetID,
                    onSelect: {
                        viewModel.selectPreset(preset)
                        trackedActivePresetID = preset.id
                        onPresetSelected?(preset.name)
                        NotificationCenter.default.post(name: .presetSelectionDidChange, object: preset.name)
                    }
                )
            }
        } header: {
            Text(String(localized: "settings.playerControls.builtInPresets"))
        }
    }

    @ViewBuilder
    private var customPresetsSection: some View {
        if !viewModel.customPresets.isEmpty {
            Section {
                ForEach(viewModel.customPresets) { preset in
                    customPresetRow(preset)
                }
            } header: {
                Text(String(localized: "settings.playerControls.customPresets"))
            }
        }
    }

    private func customPresetRow(_ preset: LayoutPreset) -> some View {
        PresetRow(
            preset: preset,
            isActive: preset.id == trackedActivePresetID,
            onSelect: {
                viewModel.selectPreset(preset)
                trackedActivePresetID = preset.id
                onPresetSelected?(preset.name)
                NotificationCenter.default.post(name: .presetSelectionDidChange, object: preset.name)
            },
            onRename: { presetToRename = preset },
            onExport: {
                exportPreset(preset)
            },
            onDelete: {
                Task { await viewModel.deletePreset(preset) }
            },
            canDelete: preset.id != trackedActivePresetID
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    showCreateSheet = true
                } label: {
                    Label(
                        String(localized: "settings.playerControls.newPreset"),
                        systemImage: "plus"
                    )
                }

                Divider()

                Button {
                    showImportPicker()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.importPreset"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .disabled(isImporting)
            } label: {
                Label(
                    String(localized: "settings.playerControls.newPreset"),
                    systemImage: "plus"
                )
            }
        }
    }

    private var createPresetSheet: some View {
        PresetEditorView(
            mode: .create(
                baseLayouts: viewModel.presets,
                activePreset: viewModel.activePreset
            ),
            onSave: { name, basePresetID in
                pendingCreation = PendingPresetCreation(name: name, basePresetID: basePresetID)
            }
        )
    }

    private func renamePresetSheet(_ preset: LayoutPreset) -> some View {
        let presetID = preset.id
        return PresetEditorView(
            mode: .rename(currentName: preset.name),
            onSave: { name, _ in
                pendingRename = PendingPresetRename(presetID: presetID, newName: name)
            }
        )
    }

    private var importPickerSheet: some View {
        PresetFilePickerView { url in
            handleImportedFile(url)
        }
    }

    // MARK: - Import/Export Actions

    private func showImportPicker() {
        showingImportPicker = true
    }


    private func handleImportedFile(_ url: URL) {
        isImporting = true

        Task {
            do {
                let presetName = try await viewModel.importPreset(from: url)
                await MainActor.run {
                    isImporting = false
                    importedPresetName = presetName
                    showingImportSuccess = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = error.localizedDescription
                    showingImportError = true
                }
            }
        }
    }

    private func exportPreset(_ preset: LayoutPreset) {
        guard let url = viewModel.exportPreset(preset) else { return }

        exportFile = ExportFile(url: url)
    }

}

// MARK: - Preset Row

private struct PresetRow: View {
    let preset: LayoutPreset
    let isActive: Bool
    let onSelect: () -> Void
    var onRename: (() -> Void)? = nil
    var onExport: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    var canDelete: Bool = true

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(preset.name)
                        .foregroundStyle(.primary)

                    if preset.isBuiltIn {
                        Text(String(localized: "settings.playerControls.builtIn"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete, !preset.isBuiltIn, canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.delete"),
                        systemImage: "trash"
                    )
                }
            }

            if let onRename, !preset.isBuiltIn {
                Button {
                    onRename()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.rename"),
                        systemImage: "pencil"
                    )
                }
                .tint(.orange)
            }

            if let onExport, !preset.isBuiltIn {
                Button {
                    onExport()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.exportPreset"),
                        systemImage: "square.and.arrow.up"
                    )
                }
                .tint(.blue)
            }
        }
        .contextMenu {
            if let onRename, !preset.isBuiltIn {
                Button {
                    onRename()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.rename"),
                        systemImage: "pencil"
                    )
                }
            }

            if let onExport, !preset.isBuiltIn {
                Button {
                    onExport()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.exportPreset"),
                        systemImage: "square.and.arrow.up"
                    )
                }
            }

            if let onDelete, !preset.isBuiltIn, canDelete {
                Divider()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label(
                        String(localized: "settings.playerControls.delete"),
                        systemImage: "trash"
                    )
                }
            }
        }
    }
}

// MARK: - File Picker (iOS)

private struct PresetFilePickerView: UIViewControllerRepresentable {
    let onSelect: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void

        init(onSelect: @escaping (URL) -> Void) {
            self.onSelect = onSelect
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onSelect(url)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PresetSelectorView(
            viewModel: PlayerControlsSettingsViewModel(
                layoutService: PlayerControlsLayoutService(),
                settingsManager: SettingsManager()
            )
        )
    }
}
