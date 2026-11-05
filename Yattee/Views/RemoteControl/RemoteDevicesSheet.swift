//
//  RemoteDevicesSheet.swift
//  Yattee
//
//  Sheet for quickly accessing remote control devices from Home.
//

import SwiftUI

struct RemoteDevicesSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDevice: DiscoveredDevice?

    var body: some View {
        DynamicSheetContainer {
            NavigationStack {
                RemoteControlContentView(navigationStyle: .selection($selectedDevice))
                    .navigationTitle(String(localized: "remoteControl.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        sheetCloseToolbarItem { dismiss() }
                    }
                    .navigationDestination(item: $selectedDevice) { device in
                        RemoteControlView(device: device)
                    }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RemoteDevicesSheet()
        .appEnvironment(.preview)
}
