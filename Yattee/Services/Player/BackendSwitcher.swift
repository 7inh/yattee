//
//  BackendSwitcher.swift
//  Yattee
//
//  Creates the app's audio playback backend.
//

import Foundation

@MainActor
final class BackendFactory {
    func createBackend(type: PlayerBackendType) throws -> any PlayerBackend {
        switch type {
        case .avFoundation:
            return AVAudioBackend()
        }
    }

    var availableBackends: [PlayerBackendType] { PlayerBackendType.allCases }
}
