//
//  SleepTimerLiveActivityController.swift
//  Yattee
//
//  Keeps the lock-screen sleep timer card in step with the player and timer.
//

#if os(iOS)
import Foundation
import ActivityKit
import Observation
import UIKit

/// Shows a Live Activity while a video is in the player, so the sleep timer can
/// be set from the lock screen. iOS only lets an app start one while it is in
/// the foreground; updates and ending work from the background.
@MainActor
final class SleepTimerLiveActivityController {
    static let shared = SleepTimerLiveActivityController()

    private typealias State = SleepTimerActivityAttributes.ContentState

    private weak var playerService: PlayerService?
    private var activity: Activity<SleepTimerActivityAttributes>?
    private var lastState: State?
    private var isStarted = false

    func start(playerService: PlayerService) {
        guard !isStarted else { return }
        isStarted = true
        self.playerService = playerService

        SleepTimerIntentBridge.handler = { [weak self] minutes in
            self?.handleIntent(minutes: minutes)
        }

        Task {
            // Cards left over from a previous launch no longer track anything.
            for stale in Activity<SleepTimerActivityAttributes>.activities {
                await stale.end(nil, dismissalPolicy: .immediate)
            }
            self.observe()
            self.sync()
        }
    }

    /// A card can only be started in the foreground, so retry on return.
    func appBecameActive() {
        guard isStarted else { return }
        sync()
    }

    // MARK: - Intent

    private func handleIntent(minutes: Int) {
        guard let playerService else { return }
        switch minutes {
        case SetSleepTimerIntent.offValue:
            SleepTimer.shared.cancel()
        case SetSleepTimerIntent.endOfVideoValue:
            SleepTimer.shared.startEndOfVideo(playerService: playerService)
        default:
            SleepTimer.shared.start(minutes: minutes, playerService: playerService)
        }
        LoggingService.shared.logPlayer("Sleep timer set from Live Activity: \(minutes)")
        sync()
    }

    // MARK: - Syncing

    private func observe() {
        withObservationTracking {
            _ = desiredState()
            _ = playerService?.state.playbackState
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.sync()
                self?.observe()
            }
        }
    }

    private func desiredState() -> State? {
        guard let video = playerService?.state.currentVideo else { return nil }
        var endDate: Date?
        var endsWithVideo = false
        switch SleepTimer.shared.mode {
        case .off:
            break
        case .duration(_, let date):
            endDate = date
        case .endOfVideo:
            endsWithVideo = true
        }
        return State(
            title: video.title,
            author: video.author.name,
            endDate: endDate,
            endsWithVideo: endsWithVideo
        )
    }

    private func sync() {
        guard let state = desiredState() else {
            endActivity()
            return
        }
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            guard state != lastState else { return }
            lastState = state
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            return
        }
        activity = nil
        // Starting needs the foreground, so start on the play press itself
        // (loading counts) rather than when audio begins, which may be after
        // the phone is locked. A restored, never-played session stays paused
        // and puts no card on the lock screen.
        let playState = playerService?.state.playbackState
        guard UIApplication.shared.applicationState == .active,
              playState == .playing || playState == .loading || playState == .buffering,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activity = try Activity.request(
                attributes: SleepTimerActivityAttributes(),
                content: ActivityContent(state: state, staleDate: nil)
            )
            lastState = state
            LoggingService.shared.logPlayer("Sleep timer Live Activity started")
        } catch {
            LoggingService.shared.logPlayerError("Sleep timer Live Activity failed to start", error: error)
        }
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        lastState = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
#endif
