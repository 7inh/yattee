//
//  MediaBrowserViewOptionsSheet.swift
//  Yattee
//
//  Sheet for customizing media browser view options.
//

import SwiftUI

struct MediaBrowserViewOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let sourceType: MediaSourceType

    @Binding var sortOrder: MediaBrowserSortOrder
    @Binding var sortAscending: Bool
    @Binding var showOnlyPlayable: Bool

    private var availableSortOptions: [MediaBrowserSortOrder] {
        MediaBrowserSortOrder.availableOptions(for: sourceType)
    }

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("mediaBrowser.viewOptions.title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    sheetCloseToolbarItem { dismiss() }
                }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Reset sort order if current selection is not available for this source type
            if !availableSortOptions.contains(sortOrder) {
                sortOrder = .name
            }
        }
    }

    @ViewBuilder
    private var sharedOptions: some View {
        Toggle("mediaBrowser.viewOptions.showOnlyPlayable", isOn: $showOnlyPlayable)
        PlatformMenuPicker(String(localized: "mediaBrowser.viewOptions.sortBy"), selection: $sortOrder) {
            ForEach(availableSortOptions) { order in
                Label(order.displayName, systemImage: order.systemImage)
                    .tag(order)
            }
        }

        Picker("mediaBrowser.viewOptions.order", selection: $sortAscending) {
            Label(String(localized: "mediaBrowser.viewOptions.ascending"), systemImage: "arrow.up")
                .tag(true)
            Label(String(localized: "mediaBrowser.viewOptions.descending"), systemImage: "arrow.down")
                .tag(false)
        }
        .pickerStyle(.segmented)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
    }


    private var formContent: some View {
        Form {
            Section {
                sharedOptions
            }
        }
    }
}

// MARK: - Preview

#Preview("Local Folder") {
    @Previewable @State var sortOrder: MediaBrowserSortOrder = .name
    @Previewable @State var sortAscending = true
    @Previewable @State var showOnlyPlayable = false

    MediaBrowserViewOptionsSheet(
        sourceType: .localFolder,
        sortOrder: $sortOrder,
        sortAscending: $sortAscending,
        showOnlyPlayable: $showOnlyPlayable
    )
}

#Preview("WebDAV") {
    @Previewable @State var sortOrder: MediaBrowserSortOrder = .name
    @Previewable @State var sortAscending = true
    @Previewable @State var showOnlyPlayable = false

    MediaBrowserViewOptionsSheet(
        sourceType: .webdav,
        sortOrder: $sortOrder,
        sortAscending: $sortAscending,
        showOnlyPlayable: $showOnlyPlayable
    )
}
