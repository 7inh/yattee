//
//  SettingsManager+Player.swift
//  Yattee
//
//  Player behavior settings and platform-specific player modes.
//

import Foundation
import UIKit

extension SettingsManager {
    // MARK: - Player Settings

    /// Whether in-app orientation lock is enabled.
    /// When enabled, ignores accelerometer rotation detection and stays in current orientation.
    /// When disabled, uses accelerometer to detect rotation even if system lock is enabled.
    /// Only active when player sheet is expanded (visible on screen).
    var inAppOrientationLock: Bool {
        get {
            if let cached = _inAppOrientationLock { return cached }
            return bool(for: .inAppOrientationLock, default: true)
        }
        set {
            _inAppOrientationLock = newValue
            set(newValue, for: .inAppOrientationLock)
        }
    }

    /// Whether to automatically rotate to landscape when playing widescreen videos.
    var rotateToMatchAspectRatio: Bool {
        get {
            if let cached = _rotateToMatchAspectRatio { return cached }
            return bool(for: .rotateToMatchAspectRatio, default: true)
        }
        set {
            _rotateToMatchAspectRatio = newValue
            set(newValue, for: .rotateToMatchAspectRatio)
        }
    }

    /// Whether to automatically rotate to portrait when dismissing the player sheet.
    /// Only available on iPhone.
    var preferPortraitBrowsing: Bool {
        get {
            guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
            if let cached = _preferPortraitBrowsing { return cached }
            return bool(for: .preferPortraitBrowsing, default: false)
        }
        set {
            _preferPortraitBrowsing = newValue
            set(newValue, for: .preferPortraitBrowsing)
        }
    }

    /// Whether the iPhone Duo tabletop layout mirrors the video into the lower
    /// half as a dim reflection below the hinge. Default is `true`.
    var tabletopReflection: Bool {
        get {
            if let cached = _tabletopReflection { return cached }
            return bool(for: .tabletopReflection, default: true)
        }
        set {
            _tabletopReflection = newValue
            set(newValue, for: .tabletopReflection)
        }
    }


    /// Behavior for minimizing the mini player. Default is onScrollDown. (iOS 26+ only)
    @available(iOS 26, *)
    var miniPlayerMinimizeBehavior: MiniPlayerMinimizeBehavior {
        get {
            if let cached = _miniPlayerMinimizeBehavior as? MiniPlayerMinimizeBehavior { return cached }
            guard let rawValue = localDefaults.string(forKey: "miniPlayerMinimizeBehavior"),
                  let behavior = MiniPlayerMinimizeBehavior(rawValue: rawValue) else {
                return .never // Default
            }
            return behavior
        }
        set {
            _miniPlayerMinimizeBehavior = newValue
            localDefaults.set(newValue.rawValue, forKey: "miniPlayerMinimizeBehavior")
        }
    }
}
