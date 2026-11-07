//
//  SettingsManager+Migration.swift
//  Yattee
//
//  One-shot migrations for saved settings and platform-specific layout keys.
//

import Foundation

extension SettingsManager {
    private static let migrationFlagKey = "didMigratePlatformSpecificLayoutKeys_v1"
    private static let compactTabBarHistoryMigrationFlagKey = "didMigrateCompactTabBarHistory_v1"
    private static let compactTabBarSettingsMigrationFlagKey = "didMigrateCompactTabBarSettings_v1"
    private static let phoneBookmarksTabMigrationFlagKey = "didMigratePhoneBookmarksTab_v1"

    /// Replaces Sources with History and adds Settings after Downloads once.
    /// Independent flags let existing installs receive each migration, while later
    /// user customizations are kept.
    /// Run after the initial iCloud refresh so it cannot restore the old visibility.
    func migrateCompactTabBarIfNeeded() {
        migratePhoneBookmarksTabIfNeeded()

        if !localDefaults.bool(forKey: Self.compactTabBarHistoryMigrationFlagKey) {
            var visibility = tabBarItemVisibility
            visibility[.sources] = false
            visibility[.history] = true
            tabBarItemVisibility = visibility

            if tabBarStartupTab == .sources {
                tabBarStartupTab = .home
            }

            localDefaults.set(true, forKey: Self.compactTabBarHistoryMigrationFlagKey)
            LoggingService.shared.logCloudKit("Migrated compact tab bar visibility from Sources to History")
        }

        guard !localDefaults.bool(forKey: Self.compactTabBarSettingsMigrationFlagKey) else { return }

        var visibility = tabBarItemVisibility
        visibility[.settings] = true
        tabBarItemVisibility = visibility

        var order = tabBarItemOrder.filter { $0 != .settings }
        if let downloadsIndex = order.firstIndex(of: .downloads) {
            order.insert(.settings, at: downloadsIndex + 1)
        } else {
            order.append(.settings)
        }
        tabBarItemOrder = order

        localDefaults.set(true, forKey: Self.compactTabBarSettingsMigrationFlagKey)
        LoggingService.shared.logCloudKit("Added Settings after Downloads in the compact tab bar")
    }

    /// Seeds the separate iPhone preferences from the old iOS settings, then
    /// replaces the Downloads slot with Bookmarks without changing iPad settings.
    private func migratePhoneBookmarksTabIfNeeded() {
        guard usesPhoneTabBar,
              !localDefaults.bool(forKey: Self.phoneBookmarksTabMigrationFlagKey) else { return }

        // Another iPhone may already have synced its migrated preferences.
        guard data(for: .tabBarItemVisibility) == nil else {
            localDefaults.set(true, forKey: Self.phoneBookmarksTabMigrationFlagKey)
            return
        }

        for key in [SettingsKey.tabBarItemOrder, .tabBarItemVisibility, .tabBarStartupTab] {
            let legacyKey = "iOS.\(key.rawValue)"
            let cloudValue = iCloudSyncEnabled && syncSettings ? ubiquitousStore.object(forKey: legacyKey) : nil
            if localDefaults.object(forKey: platformKey(key)) == nil,
               let value = cloudValue ?? localDefaults.object(forKey: legacyKey) {
                localDefaults.set(value, forKey: platformKey(key))
            }
        }

        var visibility = tabBarItemVisibility
        visibility[.bookmarks] = true
        visibility[.downloads] = false
        tabBarItemVisibility = visibility

        var order = tabBarItemOrder.filter { $0 != .bookmarks }
        order.insert(.bookmarks, at: order.firstIndex(of: .downloads) ?? order.endIndex)
        tabBarItemOrder = order

        tabBarStartupTab = tabBarStartupTab == .downloads ? .bookmarks : tabBarStartupTab

        localDefaults.set(true, forKey: Self.phoneBookmarksTabMigrationFlagKey)
        LoggingService.shared.logCloudKit("Replaced Downloads with Bookmarks in the iPhone tab bar")
    }

    // Mirrors `SettingsManager+CloudSync.protectedVisibilityKeys`. Kept in sync manually
    // because that collection is fileprivate; the set is small and rarely changes.
    private static let protectedKeysForMigration: Set<SettingsKey> = [
        .homeShortcutVisibility,
        .homeSectionVisibility,
        .homeShortcutOrder,
        .homeSectionOrder
    ]

    /// Copies any legacy unprefixed values for keys that became platform-specific into their
    /// new `iOS.` / `macOS.` / `tvOS.` slots, both locally and (if iCloud sync is on) in iCloud.
    /// Leaves the legacy unprefixed keys in place so older builds on other devices still work.
    func migrateLayoutKeysToPlatformPrefixed() {
        guard !localDefaults.bool(forKey: Self.migrationFlagKey) else { return }

        let keysNeedingMigration = SettingsKey.allCases.filter { $0.isPlatformSpecific }
        let pushToCloud = iCloudSyncEnabled && syncSettings

        for key in keysNeedingMigration {
            // Seed the original iOS namespace before the separate iPhone tab migration.
            let pKey = "iOS.\(key.rawValue)"
            let legacyKey = key.rawValue

            // Skip if the prefixed form already exists or if the legacy key is the same as the prefixed
            // key (e.g. on a platform where `platformKey` didn't rewrite it, though that shouldn't happen
            // for isPlatformSpecific keys).
            guard pKey != legacyKey,
                  localDefaults.object(forKey: pKey) == nil,
                  let legacyValue = localDefaults.object(forKey: legacyKey)
            else { continue }

            localDefaults.set(legacyValue, forKey: pKey)

            if Self.protectedKeysForMigration.contains(key) {
                let legacyTimestampKey = "\(legacyKey)_modifiedAt"
                let newTimestampKey = modifiedAtKey(for: key)
                let legacyTimestamp = localDefaults.double(forKey: legacyTimestampKey)
                if legacyTimestamp > 0, localDefaults.double(forKey: newTimestampKey) == 0 {
                    localDefaults.set(legacyTimestamp, forKey: newTimestampKey)
                }
            }

            if pushToCloud {
                ubiquitousStore.set(legacyValue, forKey: pKey)
                if Self.protectedKeysForMigration.contains(key) {
                    let newTimestampKey = modifiedAtKey(for: key)
                    let timestamp = localDefaults.double(forKey: newTimestampKey)
                    if timestamp > 0 {
                        ubiquitousStore.set(timestamp, forKey: newTimestampKey)
                    }
                }
            }
        }

        if pushToCloud {
            ubiquitousStore.synchronize()
        }

        localDefaults.set(true, forKey: Self.migrationFlagKey)
        LoggingService.shared.logCloudKit("Migrated legacy layout keys to platform-prefixed storage")
    }
}
