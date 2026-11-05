//
//  SleepTimer.swift
//  Yattee
//
//  Keeps the iOS sleep timer running independently of the player controls.
//

import Foundation
import Observation


@MainActor
@Observable
final class SleepTimer {
    enum Mode: Equatable, Sendable {
        case off
        case duration(minutes: Int, endDate: Date)
        case endOfVideo
    }

    static let shared = SleepTimer()
    static let durationOptions = [5, 10, 15, 30, 45, 60]

    private(set) var mode: Mode = .off
    private(set) var remainingSeconds = 0

    @ObservationIgnored private weak var playerService: PlayerService?
    @ObservationIgnored private var timer: Timer?

    private init() {}

    var isActive: Bool { mode != .off }

    var selectedMinutes: Int? {
        guard case .duration(let minutes, _) = mode else { return nil }
        return minutes
    }

    var caption: String? {
        switch mode {
        case .off:
            nil
        case .duration:
            String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
        case .endOfVideo:
            String(localized: "End")
        }
    }

    // MARK: - Selection

    func start(minutes: Int, playerService: PlayerService) {
        cancel()
        guard Self.durationOptions.contains(minutes) else { return }

        self.playerService = playerService
        mode = .duration(minutes: minutes, endDate: Date().addingTimeInterval(Double(minutes) * 60))
        checkForExpiration()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkForExpiration()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func startEndOfVideo(playerService: PlayerService) {
        cancel()
        self.playerService = playerService
        mode = .endOfVideo

        // Also stop a countdown if this video has already reached its end.
        if playerService.state.playbackState == .ended {
            stopAtEndOfVideo(for: playerService)
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        mode = .off
        remainingSeconds = 0
        playerService = nil
    }

    // MARK: - Expiration

    /// Uses wall-clock time so delayed background ticks do not extend the timer.
    /// PlayerService also calls this when the app enters the foreground.
    func checkForExpiration() {
        guard case .duration(_, let endDate) = mode else { return }

        let remaining = endDate.timeIntervalSinceNow
        remainingSeconds = max(0, Int(remaining.rounded(.up)))
        guard remaining <= 0 else { return }

        let playerService = self.playerService
        cancel()
        LoggingService.shared.logPlayer("Sleep timer expired")
        playerService?.pauseForSleepTimer()
    }

    /// Consumes the selection before the player can repeat or dequeue another video.
    @discardableResult
    func stopAtEndOfVideo(for playerService: PlayerService) -> Bool {
        guard mode == .endOfVideo, self.playerService === playerService else { return false }

        cancel()
        LoggingService.shared.logPlayer("Sleep timer stopped at end of video")
        playerService.pauseForSleepTimer()
        return true
    }
}
