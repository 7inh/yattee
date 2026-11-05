//
//  BackgroundRefreshManager.swift
//  Yattee
//
//  Platform-specific background refresh orchestration.
//

import Foundation
import BackgroundTasks

/// Manages background refresh scheduling and execution across platforms.
@MainActor
final class BackgroundRefreshManager {
    // MARK: - Constants

    static let backgroundTaskIdentifier = AppIdentifiers.backgroundFeedRefresh


    // MARK: - Dependencies

    private let backgroundRefresher: BackgroundFeedRefresher

    // MARK: - Initialization

    init(notificationManager: NotificationManager) {
        self.backgroundRefresher = BackgroundFeedRefresher(notificationManager: notificationManager)
    }

    func setAppEnvironment(_ environment: AppEnvironment) {
        backgroundRefresher.setAppEnvironment(environment)
    }

    // MARK: - Registration (call at app launch)

    func registerBackgroundTasks() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        registerIOSBackgroundTask()
    }

    // MARK: - iOS Implementation

    private func registerIOSBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let task = task as? BGAppRefreshTask else { return }
            self?.handleIOSBackgroundTask(task)
        }
        LoggingService.shared.info("Registered iOS background task", category: .notifications)
    }

    func scheduleIOSBackgroundRefresh() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // Request to run in ~15 minutes (system decides actual timing)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            LoggingService.shared.info("Scheduled iOS background refresh", category: .notifications)
        } catch {
            LoggingService.shared.logNotificationError("Failed to schedule background refresh", error: error)
        }
    }

    func cancelIOSBackgroundRefresh() {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        LoggingService.shared.debug("Cancelled iOS background refresh", category: .notifications)
    }

    private func handleIOSBackgroundTask(_ task: BGAppRefreshTask) {
        LoggingService.shared.info("iOS background task started", category: .notifications)

        // Schedule the next refresh immediately
        scheduleIOSBackgroundRefresh()

        // Create a task to perform the refresh
        let refreshTask = Task { @MainActor in
            await backgroundRefresher.performBackgroundRefresh()
        }

        // Set expiration handler
        task.expirationHandler = {
            LoggingService.shared.warning("iOS background task expired", category: .notifications)
            refreshTask.cancel()
        }

        // Wait for completion
        Task {
            _ = await refreshTask.result
            task.setTaskCompleted(success: !refreshTask.isCancelled)
            LoggingService.shared.info("iOS background task completed", category: .notifications)
        }
    }

    // MARK: - macOS Implementation


    // MARK: - Enable/Disable

    func handleNotificationsEnabledChanged(_ enabled: Bool) {
        guard !ProcessInfo.processInfo.isMacCatalystApp else { return }
        if enabled {
            scheduleIOSBackgroundRefresh()
        } else {
            cancelIOSBackgroundRefresh()
        }
    }
}
