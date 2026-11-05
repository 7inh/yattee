//
//  UnifiedSource.swift
//  Yattee
//
//  Unified wrapper for Instance and MediaSource types for display in the Sources settings.
//

import Foundation

/// Represents any source type for unified display in the Sources list.
enum UnifiedSource: Identifiable, Hashable, Sendable {
    case remoteServer(Instance)

    // MARK: - Identifiable

    var id: UUID {
        switch self {
        case .remoteServer(let instance):
            return instance.id
        }
    }

    // MARK: - Common Properties

    var name: String {
        switch self {
        case .remoteServer(let instance):
            return instance.displayName
        }
    }

    var isEnabled: Bool {
        switch self {
        case .remoteServer(let instance):
            return instance.isEnabled
        }
    }

    var urlDisplayString: String {
        switch self {
        case .remoteServer(let instance):
            return instance.url.host ?? instance.url.absoluteString
        }
    }
}
