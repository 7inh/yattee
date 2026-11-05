//
//  VideoRowStyle.swift
//  Yattee
//
//  Row style configuration for VideoRowView.
//

import Foundation

/// Row style for VideoRowView.
enum VideoRowStyle: String {
    /// Large size with 160x90 thumbnail (220x124 on tvOS) and 3-line titles.
    case large
    /// Regular size with 120x68 thumbnail (180x101 on tvOS) and 2-line titles.
    case regular
    /// Compact size with 70x39 thumbnail (120x68 on tvOS), 1-line titles, hidden metadata, and duration shown inline.
    case compact

    var thumbnailWidth: CGFloat {
        switch self {
        case .large:
            return 160
        case .regular:
            return 120
        case .compact:
            return 70
        }
    }

    var thumbnailHeight: CGFloat {
        switch self {
        case .large:
            return 90
        case .regular:
            return 68
        case .compact:
            return 39
        }
    }
}
