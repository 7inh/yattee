//
//  BackgroundFeedRefresher.swift
//  Yattee
//
//  Core background feed refresh logic for notifications.
//

import Foundation

/// Performs background feed refresh and detects new videos for notifications.
/// Only fetches videos from channels with notifications enabled.
@MainActor
final class BackgroundFeedRefresher {
    // MARK: - Dependencies

    private weak var appEnvironment: AppEnvironment?
    private let notificationManager: NotificationManager

    // MARK: - Initialization

    init(notificationManager: NotificationManager) {
        self.notificationManager = notificationManager
    }

    func setAppEnvironment(_ environment: AppEnvironment) {
        self.appEnvironment = environment
    }

    // MARK: - Refresh Logic

    /// Performs background refresh and sends notifications for new videos.
    /// Routes to appropriate refresh method based on subscription account type.
    func performBackgroundRefresh() async {
        guard let appEnvironment else {
            LoggingService.shared.warning("Background refresh skipped: no app environment", category: .notifications)
            return
        }

        guard appEnvironment.settingsManager.backgroundNotificationsEnabled else {
            LoggingService.shared.debug("Background refresh disabled in settings", category: .notifications)
            return
        }

        // Route on the *effective* context. An account context resolves its own
        // instance, so a second login on the same instance refreshes the right
        // user's feed — but an account whose instance is switched off or whose
        // credential has not arrived falls back to local rather than sending
        // background requests to a server the user is not currently using.
        switch appEnvironment.dataContextValidator.effectiveContext {
        case .local:
            await performLocalAccountRefresh()
        case let .account(id):
            guard let account = appEnvironment.accountsManager.account(id: id),
                  let instance = appEnvironment.accountsManager.instance(for: account)
            else {
                LoggingService.shared.debug(
                    "Background refresh skipped: selected account has no resolved instance",
                    category: .notifications
                )
                return
            }

            switch instance.type {
            case .invidious: await performInvidiousAccountRefresh()
            default:
                LoggingService.shared.debug(
                    "Background refresh not supported for this account type",
                    category: .notifications
                )
            }
        }
    }

    // MARK: - Local Account Refresh

    /// Performs background refresh for local (Yattee/iCloud) subscription account.
    /// Requires Yattee Server - uses stateless feed endpoint for efficient single-request fetching.
    private func performLocalAccountRefresh() async {
        guard let appEnvironment, let instance = appEnvironment.instancesManager.enabledInstances.first else { return }
        let lastCheck = appEnvironment.settingsManager.lastBackgroundCheck ?? .distantPast
        let channelIDs = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())
        let subscriptions = appEnvironment.dataManager.subscriptions().filter { channelIDs.contains($0.channelID) }
        var newVideos: [(video: Video, channelName: String)] = []
        do {
            for subscription in subscriptions {
                try Task.checkCancellation()
                let page = try await appEnvironment.contentService.channelVideos(id: subscription.channelID, instance: instance)
                for video in page.videos where (video.publishedAt ?? .distantPast) > lastCheck
                    && (video.publishedAt ?? .distantPast) <= Date()
                    && appEnvironment.settingsManager.lastNotifiedVideoPerChannel[video.author.id] != video.id.videoID {
                    newVideos.append((video, video.author.name))
                }
            }
            appEnvironment.settingsManager.lastBackgroundCheck = Date()
            await sendNotificationsIfNeeded(newVideos: newVideos)
        } catch { LoggingService.shared.logNotificationError("Local Invidious feed refresh failed", error: error) }
    }

    // MARK: - Invidious Account Refresh

    /// Performs background refresh for Invidious subscription account.
    /// Fetches the full Invidious feed and filters to channels with notifications enabled.
    private func performInvidiousAccountRefresh() async {
        guard let appEnvironment else { return }

        // Resolve through the selected account: a fresh login writes only the
        // account-scoped Keychain key, and "first enabled Invidious instance"
        // could pick a server this account has no credential for.
        guard let account = appEnvironment.account(forSelectedContext: .invidious),
              let invidiousInstance = appEnvironment.accountsManager.instance(for: account),
              let sid = appEnvironment.accountCredentialsManager(for: account)?.credential(for: account) else {
            LoggingService.shared.debug("Background refresh requires authenticated Invidious instance", category: .notifications)
            return
        }

        let lastCheckDate = appEnvironment.settingsManager.lastBackgroundCheck ?? Date.distantPast

        // Get channel IDs with notifications enabled from ChannelNotificationSettings
        let notifiableChannelIDs = Set(appEnvironment.dataManager.channelIDsWithNotificationsEnabled())

        LoggingService.shared.info(
            "Background refresh starting (Invidious account) | lastBackgroundCheck: \(lastCheckDate) | channels with notifications: \(notifiableChannelIDs.count)",
            category: .notifications
        )

        guard !notifiableChannelIDs.isEmpty else {
            LoggingService.shared.debug("No channels with notifications enabled", category: .notifications)
            appEnvironment.settingsManager.lastBackgroundCheck = Date()
            return
        }

        LoggingService.shared.debug("Fetching feed from Invidious: \(invidiousInstance.url)", category: .notifications)

        do {
            // Fetch the Invidious feed - fetch enough to cover recent videos from notifiable channels
            // Use a reasonable limit since we're filtering client-side
            let feedResponse = try await appEnvironment.invidiousAPI.feed(
                instance: invidiousInstance,
                sid: sid,
                page: 1,
                maxResults: 100
            )

            LoggingService.shared.debug("API returned \(feedResponse.videos.count) total videos", category: .notifications)

            // Load last notified video IDs per channel for deduplication
            let lastNotified = appEnvironment.settingsManager.lastNotifiedVideoPerChannel

            // Filter to new videos from notifiable channels
            var channelFilteredCount = 0
            var dateFilteredCount = 0
            var dedupedCount = 0
            let newVideos: [(video: Video, channelName: String)] = feedResponse.videos.compactMap { video in
                // Only include videos from channels with notifications enabled
                guard notifiableChannelIDs.contains(video.author.id) else {
                    return nil
                }
                channelFilteredCount += 1

                // Only include videos published after last check and not in the future
                guard let publishedAt = video.publishedAt,
                      publishedAt > lastCheckDate,
                      publishedAt <= Date() else {
                    return nil
                }
                dateFilteredCount += 1

                // Skip if this is the last video we notified about for this channel
                if lastNotified[video.author.id] == video.id.videoID {
                    dedupedCount += 1
                    return nil
                }

                return (video: video, channelName: video.author.name)
            }

            LoggingService.shared.debug(
                "After channel filter: \(channelFilteredCount) videos from notifiable channels",
                category: .notifications
            )
            LoggingService.shared.debug(
                "After date filter: \(dateFilteredCount) videos newer than \(lastCheckDate)",
                category: .notifications
            )
            LoggingService.shared.debug(
                "After deduplication: \(newVideos.count) videos (removed \(dedupedCount) already-notified)",
                category: .notifications
            )

            // Update last notified video per channel (store newest video ID for each channel)
            var updatedLastNotified = lastNotified
            for (video, _) in newVideos {
                updatedLastNotified[video.author.id] = video.id.videoID
            }
            appEnvironment.settingsManager.lastNotifiedVideoPerChannel = updatedLastNotified

            // Update timestamp before sending notification
            appEnvironment.settingsManager.lastBackgroundCheck = Date()

            await sendNotificationsIfNeeded(newVideos: newVideos)
        } catch {
            LoggingService.shared.logNotificationError("Background refresh failed (Invidious account)", error: error)
        }
    }

    // MARK: - Piped Account Refresh

    /// Performs background refresh for Piped subscription account.
    /// Fetches the Piped feed and filters to channels with notifications enabled.

    // MARK: - Notification Sending

    /// Sends notifications for new videos if any were found.
    /// Filters out videos the user has already started or finished watching.
    /// - Parameter newVideos: Array of new videos with their channel names
    private func sendNotificationsIfNeeded(newVideos: [(video: Video, channelName: String)]) async {
        guard !newVideos.isEmpty else {
            LoggingService.shared.debug("No new videos found", category: .notifications)
            return
        }

        var videosToNotify = newVideos

        // Filter out upcoming/premiere videos that haven't aired yet
        let upcomingCount = videosToNotify.count
        videosToNotify = videosToNotify.filter { !$0.video.isUpcoming }
        if upcomingCount - videosToNotify.count > 0 {
            LoggingService.shared.debug(
                "Filtered \(upcomingCount - videosToNotify.count) upcoming/premiere videos from notifications",
                category: .notifications
            )
        }

        // Filter out videos the user has already started or finished watching
        if let appEnvironment {
            let watchEntries = appEnvironment.dataManager.watchEntriesMap()
            let originalCount = videosToNotify.count

            videosToNotify = videosToNotify.filter { item in
                guard let entry = watchEntries[item.video.id.videoID] else {
                    // No watch entry - video hasn't been watched, include it
                    return true
                }
                // Skip if user has started watching (any progress) or finished
                return entry.watchedSeconds <= 0 && !entry.isFinished
            }

            let filteredCount = originalCount - videosToNotify.count
            if filteredCount > 0 {
                LoggingService.shared.debug(
                    "Filtered \(filteredCount) watched/started videos from notifications",
                    category: .notifications
                )
            }
        }

        if !videosToNotify.isEmpty {
            await notificationManager.sendNotification(for: videosToNotify)
            LoggingService.shared.info(
                "Background refresh complete | Found \(videosToNotify.count) new videos from \(Set(videosToNotify.map(\.channelName)).count) channels | Notification sent: true",
                category: .notifications
            )
        } else {
            LoggingService.shared.info(
                "Background refresh complete | Found 0 new videos | Notification sent: false",
                category: .notifications
            )
        }
    }
}
