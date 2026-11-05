//
//  QueueManagementSheet.swift
//  Yattee
//
//  Sheet for managing the player queue with reorder and remove capabilities.
//

import SwiftUI

struct QueueManagementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appEnvironment) private var appEnvironment

    /// Optional dismiss callback used when the view is presented inline (e.g. as
    /// the tvOS half-screen panel) rather than via a sheet/fullScreenCover. When
    /// nil, falls back to `@Environment(\.dismiss)`.
    var onDismiss: (() -> Void)?

    private func performDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var queueManager: QueueManager? { appEnvironment?.queueManager }
    private var playerState: PlayerState? { appEnvironment?.playerService.state }

    private var queue: [QueuedVideo] { playerState?.queue ?? [] }
    private var history: [QueuedVideo] { playerState?.history ?? [] }
    private var queueSourceLabel: String? { queueManager?.currentQueueSourceLabel }

    var body: some View {
        nonTVOSBody
    }


    private var nonTVOSBody: some View {
        NavigationStack {
            Group {
                if queue.isEmpty && history.isEmpty && playerState?.currentVideo == nil {
                    emptyStateView
                } else {
                    queueListView
                }
            }
            .navigationTitle(queueSourceLabel ?? String(localized: "queue.sheet.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    queueModeMenu
                }
                sheetCloseToolbarItem { performDismiss() }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationDetents([.medium, .large])
    }

    // MARK: - Views

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text(String(localized: "queue.sheet.empty"))
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(String(localized: "queue.sheet.emptyHint"))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var queueListView: some View {
        QueueListView(onPlay: {
            performDismiss()
        })
    }


    /// Menu for selecting queue mode (shuffle, repeat, etc.)
    @ViewBuilder
    private var queueModeMenu: some View {
        Menu {
            ForEach(QueueMode.allCases, id: \.self) { mode in
                Button {
                    playerState?.queueMode = mode
                } label: {
                    Label(mode.displayName, systemImage: mode.icon)
                }
                .disabled(playerState?.queueMode == mode)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: playerState?.queueMode.icon ?? "list.bullet")
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.tint)
        }
    }

    private func cycleQueueMode() {
        guard let playerState else { return }
        let modes = QueueMode.allCases
        let currentIndex = modes.firstIndex(of: playerState.queueMode) ?? 0
        let nextIndex = (currentIndex + 1) % modes.count
        playerState.queueMode = modes[nextIndex]
    }

}

#Preview {
    Text("Tap to open")
        .sheet(isPresented: .constant(true)) {
            QueueManagementSheet()
        }
}
