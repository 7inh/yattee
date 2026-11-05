//
//  SettingsManager+Advanced.swift
//  Yattee
//
//  Advanced settings: debug, player, floating panel.
//

import Foundation
import SwiftUI

extension SettingsManager {
    // MARK: - Advanced Settings

    /// Whether to show advanced stream details (codec, bitrate, size) in quality selector.
    /// When disabled, only shows resolution/language and filters to best stream per resolution/language.
    /// Default is false (simplified view).
    var showAdvancedStreamDetails: Bool {
        get {
            if let cached = _showAdvancedStreamDetails { return cached }
            return bool(for: .showAdvancedStreamDetails, default: false)
        }
        set {
            _showAdvancedStreamDetails = newValue
            set(newValue, for: .showAdvancedStreamDetails)
        }
    }

    /// Whether to show player area debug overlays (frame borders, safe area values, layout info).
    /// Useful for troubleshooting layout issues on different devices.
    /// Default is false (hidden).
    var showPlayerAreaDebug: Bool {
        get {
            if let cached = _showPlayerAreaDebug { return cached }
            return bool(for: .showPlayerAreaDebug, default: false)
        }
        set {
            _showPlayerAreaDebug = newValue
            set(newValue, for: .showPlayerAreaDebug)
        }
    }

    /// Whether verbose remote control logging is enabled.
    /// When enabled, logs detailed discovery, connection, and message state
    /// to help diagnose remote control issues. Default is false (disabled).
    var verboseRemoteControlLogging: Bool {
        get {
            if let cached = _verboseRemoteControlLogging { return cached }
            return bool(for: .verboseRemoteControlLogging, default: false)
        }
        set {
            _verboseRemoteControlLogging = newValue
            set(newValue, for: .verboseRemoteControlLogging)
        }
    }

    /// Custom device name for remote control. When empty, uses system device name.
    /// Allows users to set a custom name that appears to other devices on the network.
    var remoteControlCustomDeviceName: String {
        get {
            if let cached = _remoteControlCustomDeviceName { return cached }
            return string(for: .remoteControlCustomDeviceName) ?? ""
        }
        set {
            _remoteControlCustomDeviceName = newValue
            set(newValue, for: .remoteControlCustomDeviceName)
        }
    }

    /// Whether to hide this device from remote control when app enters background.
    /// When enabled, stops Bonjour advertising when backgrounded so device disappears
    /// from other devices' lists. Default is true (hide when backgrounded).
    /// Only applies to iOS and tvOS.
    var remoteControlHideWhenBackgrounded: Bool {
        get {
            if let cached = _remoteControlHideWhenBackgrounded { return cached }
            return bool(for: .remoteControlHideWhenBackgrounded, default: true)
        }
        set {
            _remoteControlHideWhenBackgrounded = newValue
            set(newValue, for: .remoteControlHideWhenBackgrounded)
        }
    }

    /// Minimum buffer time in seconds before video playback starts.
    /// Higher values reduce initial stuttering but increase startup delay.
    /// Default is 3.0 seconds.

    /// Whether zoom navigation transitions are enabled (iOS only).
    /// When enabled, navigating to video/channel/playlist details shows a zoom animation
    /// from the source thumbnail. Disable if experiencing visual glitches with swipe-back gestures.
    /// Default is true (enabled).
    var zoomTransitionsEnabled: Bool {
        get {
            if let cached = _zoomTransitionsEnabled { return cached }
            return bool(for: .zoomTransitionsEnabled, default: true)
        }
        set {
            _zoomTransitionsEnabled = newValue
            set(newValue, for: .zoomTransitionsEnabled)
        }
    }

    // MARK: - Details Panel Settings

    /// Default panel width in wide layout.
    static let defaultFloatingDetailsPanelWidth: CGFloat = 400

    /// Width of the floating details panel in wide layout.
    /// User can resize via drag gesture. Persisted across sessions.
    var floatingDetailsPanelWidth: CGFloat {
        get {
            if let cached = _floatingDetailsPanelWidth { return cached }
            let value = double(for: .floatingDetailsPanelWidth)
            return value > 0 ? CGFloat(value) : Self.defaultFloatingDetailsPanelWidth
        }
        set {
            _floatingDetailsPanelWidth = newValue
            set(Double(newValue), for: .floatingDetailsPanelWidth)
        }
    }

    /// Whether the details panel is visible in landscape layout.
    /// Default is false (hidden). User must manually show panel.
    var landscapeDetailsPanelVisible: Bool {
        get {
            if let cached = _landscapeDetailsPanelVisible { return cached }
            return bool(for: .landscapeDetailsPanelVisible, default: false)
        }
        set {
            _landscapeDetailsPanelVisible = newValue
            set(newValue, for: .landscapeDetailsPanelVisible)
        }
    }

    /// Last user-set portrait panel visibility, restored when the active
    /// preset's portrait default visibility is "remember". Falls back to the
    /// legacy shared value from before the per-orientation split.
    var portraitDetailsPanelLastVisible: Bool {
        get {
            if let cached = _portraitDetailsPanelLastVisible { return cached }
            return bool(for: .portraitDetailsPanelLastVisible, default: legacyDetailsPanelLastVisible)
        }
        set {
            _portraitDetailsPanelLastVisible = newValue
            set(newValue, for: .portraitDetailsPanelLastVisible)
        }
    }

    /// Last user-set landscape panel visibility, restored when the active
    /// preset's landscape default visibility is "remember". Falls back to the
    /// legacy shared value from before the per-orientation split.
    var landscapeDetailsPanelLastVisible: Bool {
        get {
            if let cached = _landscapeDetailsPanelLastVisible { return cached }
            return bool(for: .landscapeDetailsPanelLastVisible, default: legacyDetailsPanelLastVisible)
        }
        set {
            _landscapeDetailsPanelLastVisible = newValue
            set(newValue, for: .landscapeDetailsPanelLastVisible)
        }
    }

    /// The pre-split shared "remember" value; only read as the fallback for
    /// the per-orientation values above.
    private var legacyDetailsPanelLastVisible: Bool {
        bool(for: .detailsPanelLastVisible, default: false)
    }

    /// Last user-set visibility for an orientation.
    func detailsPanelLastVisible(for orientation: PanelOrientation) -> Bool {
        switch orientation {
        case .portrait:
            return portraitDetailsPanelLastVisible
        case .landscape:
            return landscapeDetailsPanelLastVisible
        }
    }

    /// Default side column width in the corner player layout.
    static let defaultCornerPanelColumnWidth: CGFloat = 380

    /// Width of the side column in the corner player layout (iPad/macOS).
    /// User can resize via drag gesture. Persisted across sessions.
    var cornerPanelColumnWidth: CGFloat {
        get {
            if let cached = _cornerPanelColumnWidth { return cached }
            let value = double(for: .cornerPanelColumnWidth)
            return value > 0 ? CGFloat(value) : Self.defaultCornerPanelColumnWidth
        }
        set {
            _cornerPanelColumnWidth = newValue
            set(Double(newValue), for: .cornerPanelColumnWidth)
        }
    }

    /// Whether the details panel is pinned (side-by-side) in the wide layout.
    /// iPad/macOS default to pinned; iPhone is floating-only and always
    /// resolves to `false` regardless of the stored value.
    var landscapeDetailsPanelPinned: Bool {
        get {
            if PanelSettings.isSectionsOnlyDevice { return false }
            if let cached = _landscapeDetailsPanelPinned { return cached }
            return bool(for: .landscapeDetailsPanelPinned, default: true)
        }
        set {
            _landscapeDetailsPanelPinned = newValue
            set(newValue, for: .landscapeDetailsPanelPinned)
        }
    }

    // MARK: - Appearance Settings

    /// List style for video list views.
    /// Controls whether lists use inset grouped style (card background) or plain style.
    /// Default is plain. Synced per-platform via iCloud.
    var listStyle: VideoListStyle {
        get {
            if let cached = _listStyle { return cached }
            guard let rawValue = string(for: .listStyle),
                  let style = VideoListStyle(rawValue: rawValue) else {
                return .plain
            }
            _listStyle = style
            return style
        }
        set {
            _listStyle = newValue
            set(newValue.rawValue, for: .listStyle)
        }
    }

    // MARK: - Video Swipe Actions

    /// Order of video swipe actions. Actions appear in this order from left to right.
    /// New actions are merged in at their default positions if not already present.
    var videoSwipeActionOrder: [VideoSwipeAction] {
        get {
            if let cached = _videoSwipeActionOrder { return cached }

            // Try to decode from storage
            if let data = data(for: .videoSwipeActionOrder),
               let decoded = try? JSONDecoder().decode([VideoSwipeAction].self, from: data) {
                // Merge any new actions that might have been added in an update
                var order = decoded
                for action in VideoSwipeAction.allCases {
                    if !order.contains(action) {
                        order.append(action)
                    }
                }
                _videoSwipeActionOrder = order
                return order
            }

            // Return default order with all actions
            let order = VideoSwipeAction.allCases
            _videoSwipeActionOrder = order
            return order
        }
        set {
            _videoSwipeActionOrder = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                set(data, for: .videoSwipeActionOrder)
            }
        }
    }

    /// Visibility of each video swipe action. True = enabled, False = disabled.
    var videoSwipeActionVisibility: [VideoSwipeAction: Bool] {
        get {
            if let cached = _videoSwipeActionVisibility { return cached }

            // Try to decode from storage
            if let data = data(for: .videoSwipeActionVisibility),
               let decoded = try? JSONDecoder().decode([VideoSwipeAction: Bool].self, from: data) {
                // Merge in defaults for any new actions
                var visibility = decoded
                for action in VideoSwipeAction.allCases {
                    if visibility[action] == nil {
                        visibility[action] = VideoSwipeAction.defaultVisibility[action] ?? false
                    }
                }
                _videoSwipeActionVisibility = visibility
                return visibility
            }

            // Return default visibility
            let visibility = VideoSwipeAction.defaultVisibility
            _videoSwipeActionVisibility = visibility
            return visibility
        }
        set {
            _videoSwipeActionVisibility = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                set(data, for: .videoSwipeActionVisibility)
            }
        }
    }

    /// Returns visible swipe actions in the configured order.
    func visibleVideoSwipeActions() -> [VideoSwipeAction] {
        videoSwipeActionOrder.filter { videoSwipeActionVisibility[$0] ?? false }
    }
}
