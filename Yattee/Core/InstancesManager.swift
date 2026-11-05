//
//  InstancesManager.swift
//  Yattee
//
//  Manages configured backend instances with iCloud sync.
//

import Foundation
import SwiftUI

/// Manages the list of configured backend instances with iCloud sync.
@MainActor
@Observable
final class InstancesManager {
    // MARK: - Storage

    private let localDefaults: UserDefaults
    private let ubiquitousStore = NSUbiquitousKeyValueStore.default
    private let instancesKey = "configuredInstances"
    private let activeInstanceKey = "activeInstanceID"

    // MARK: - Dependencies

    private weak var settingsManager: SettingsManager?

    // MARK: - State

    private(set) var instances: [Instance] = []
    private(set) var activeInstanceID: UUID?

    // MARK: - Initialization

    /// - Parameter defaults: where the configured instances are read and
    ///   written. The app's own defaults, except under test: a manager built on
    ///   the shared ones edits the list the app on that device is using, which
    ///   is how test fixtures ended up in it.
    init(settingsManager: SettingsManager? = nil, defaults: UserDefaults = .standard) {
        self.settingsManager = settingsManager
        self.localDefaults = defaults

        loadInstances()
        loadActiveInstance()

        // Listen for external changes from iCloud
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: ubiquitousStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleiCloudChange()
            }
        }
    }

    /// Sets the settings manager reference for checking iCloud sync status.
    func setSettingsManager(_ manager: SettingsManager) {
        self.settingsManager = manager
    }

    /// Whether iCloud sync is currently enabled.
    private var iCloudSyncEnabled: Bool {
        settingsManager?.iCloudSyncEnabled ?? false
    }

    /// Whether instance sync is enabled (requires both master toggle and category toggle).
    private var instanceSyncEnabled: Bool {
        iCloudSyncEnabled && (settingsManager?.syncInstances ?? true)
    }

    /// Handles external iCloud changes by replacing local data with iCloud data.
    private func handleiCloudChange() {
        // Only process iCloud changes if instance sync is enabled
        guard instanceSyncEnabled else { return }

        guard let iCloudData = ubiquitousStore.data(forKey: instancesKey),
              let iCloudInstances = try? JSONDecoder().decode(LossyDecodableArray<Instance>.self, from: iCloudData).elements else {
            return
        }

        // Replace local instances with iCloud data
        instances = iCloudInstances
        // Save to local defaults for offline access
        localDefaults.set(iCloudData, forKey: instancesKey)

        // Update sync time
        settingsManager?.updateLastSyncTime()

        // Instances arriving from iCloud are as much a change as a local edit.
        // Without this, a legacy authenticated instance delivered here never
        // reaches account migration — the account, and the adoption of its
        // saved login, would happen only after an unrelated edit or a relaunch.
        NotificationCenter.default.post(name: .instancesDidChange, object: nil)
    }

    /// Syncs local data to iCloud (called when enabling iCloud sync).
    /// Only syncs if instance sync is enabled.
    func syncToiCloud() {
        guard instanceSyncEnabled else { return }

        guard let data = try? JSONEncoder().encode(instances) else { return }
        ubiquitousStore.set(data, forKey: instancesKey)
        ubiquitousStore.synchronize()
        settingsManager?.updateLastSyncTime()
    }

    /// Replaces local data with iCloud data (called when enabling iCloud sync).
    /// Only replaces if instance sync is enabled.
    func replaceWithiCloudData() {
        guard instanceSyncEnabled else { return }

        ubiquitousStore.synchronize()

        guard let iCloudData = ubiquitousStore.data(forKey: instancesKey),
              let iCloudInstances = try? JSONDecoder().decode(LossyDecodableArray<Instance>.self, from: iCloudData).elements else {
            // No iCloud data exists, sync local data to iCloud
            syncToiCloud()
            return
        }

        // Replace local with iCloud data
        instances = iCloudInstances
        localDefaults.set(iCloudData, forKey: instancesKey)
        settingsManager?.updateLastSyncTime()

        NotificationCenter.default.post(name: .instancesDidChange, object: nil)
    }

    // MARK: - Public Methods

    func add(_ instance: Instance) {
        instances.append(instance)
        saveInstances()
    }

    func remove(_ instance: Instance) {
        instances.removeAll { $0.id == instance.id }

        // Clear active instance if it was the removed one
        if activeInstanceID == instance.id {
            activeInstanceID = nil
            localDefaults.removeObject(forKey: activeInstanceKey)
        }

        saveInstances()
        Task { await ProxyDetectionCache.shared.invalidate(instance: instance) }
    }

    func update(_ instance: Instance) {
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            instances[index] = instance
            saveInstances()
            // Editing a source can change the proxy answer (URL change, toggle
            // flip). Drop the cached auto-detect verdict so the next playback
            // re-probes.
            Task { await ProxyDetectionCache.shared.invalidate(instance: instance) }
        }
    }

    /// Toggles the enabled state of an instance.
    func toggleEnabled(_ instance: Instance) {
        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            var updated = instances[index]
            updated.isEnabled.toggle()
            instances[index] = updated
            saveInstances()
        }
    }

    /// Records whether an instance sits behind HTTP Basic Auth.
    /// Persisted (and synced to iCloud) so missing Keychain credentials can be
    /// detected after a reinstall.
    func setUsesBasicAuth(_ value: Bool, for instance: Instance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }),
              instances[index].usesBasicAuth != value else { return }
        instances[index].usesBasicAuth = value
        saveInstances()
    }

    /// Records that a pre-revamp single login existed on an instance.
    ///
    /// Migration-only: every caller is migration machinery (a Yattee 1 import,
    /// the credential backfill, or the last account on the instance going
    /// away). Signing in deliberately never calls this — accounts describe
    /// logins now (see `AccountSignInHandler`, and `Instance.usesAccountLogin`
    /// for who writes it and why).
    func setUsesAccountLogin(_ value: Bool, for instance: Instance) {
        guard let index = instances.firstIndex(where: { $0.id == instance.id }),
              instances[index].usesAccountLogin != value else { return }
        instances[index].usesAccountLogin = value
        saveInstances()
    }

    // MARK: - Computed Properties

    var enabledInstances: [Instance] {
        instances.filter(\.isEnabled)
    }

    var hasYouTubeInstances: Bool {
        instances.contains { $0.isYouTubeInstance }
    }

    /// Instances whose backend has accounts at all, asked of the capability
    /// table rather than a type list.
    var accountCapableInstances: [Instance] {
        instances.filter { $0.type.accountCapabilities.supportsAccounts }
    }

    var hasAccountCapableInstances: Bool {
        instances.contains { $0.type.accountCapabilities.supportsAccounts }
    }

    /// Selects an enabled instance appropriate for the given video's content source.
    /// - For PeerTube videos: prefers the exact instance, falls back to any PeerTube instance
    /// - For YouTube/extracted content: uses YouTube-capable instance (Invidious, Piped, Yattee Server)
    func instance(for video: Video) -> Instance? {
        instance(for: video.id.source)
    }

    /// Selects the instance to load a remote playlist from: Invidious first for
    /// YouTube (Invidious playlists are Invidious-specific), the playlist's own
    /// server for federated content, Yattee Server for extracted content.
    func playlistInstance(for source: ContentSource) -> Instance? {
        guard case .global(let provider) = source, provider == ContentSource.youtubeProvider else { return nil }
        return enabledInstances.first
    }

    /// Selects an enabled instance appropriate for the given content source.
    /// - For PeerTube content: prefers the exact instance, falls back to any PeerTube instance
    /// - For extracted content: requires Yattee Server (only backend with yt-dlp)
    /// - For YouTube content: uses YouTube-capable instance (Invidious, Piped, Yattee Server)
    func instance(for contentSource: ContentSource) -> Instance? {
        guard case .global(let provider) = contentSource, provider == ContentSource.youtubeProvider else { return nil }
        return activeInstance ?? enabledInstances.first
    }

    /// Disables all Yattee Server instances except the specified one.

    /// The currently active instance for browsing content.
    /// Falls back to the first enabled instance if no active instance is set.
    var activeInstance: Instance? {
        if let id = activeInstanceID,
           let instance = enabledInstances.first(where: { $0.id == id }) {
            return instance
        }
        return enabledInstances.first
    }

    // MARK: - Private Methods

    private func loadInstances() {
        // Only load from local defaults - never automatically pull from iCloud
        // User must explicitly enable iCloud sync to get iCloud data
        if let data = localDefaults.data(forKey: instancesKey),
           let decoded = try? JSONDecoder().decode(LossyDecodableArray<Instance>.self, from: data).elements {
            instances = decoded
        }
    }

    private func saveInstances() {
        guard let data = try? JSONEncoder().encode(instances) else { return }

        // Always write to local storage
        localDefaults.set(data, forKey: instancesKey)

        // Only write to iCloud if instance sync is enabled
        if instanceSyncEnabled {
            ubiquitousStore.set(data, forKey: instancesKey)
            settingsManager?.updateLastSyncTime()
        }

        NotificationCenter.default.post(name: .instancesDidChange, object: nil)
    }

    private func loadActiveInstance() {
        if let idString = localDefaults.string(forKey: activeInstanceKey),
           let uuid = UUID(uuidString: idString) {
            activeInstanceID = uuid
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let instancesDidChange = Notification.Name("stream.yattee.instancesDidChange")
}
