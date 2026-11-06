//
//  PlaybackIntentController.swift
//  Yattee
//
//  Keeps transport intent responsive while coalescing commands and backend feedback.
//

import Foundation
import Observation

@MainActor
@Observable
final class PlaybackIntentController {
    private(set) var isPlaying = false

    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var reconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var commandGeneration = 0
    @ObservationIgnored private var protectedUntil: ContinuousClock.Instant?

    private let commandDelay: Duration
    private let protectionDuration: Duration
    private let stabilityDuration: Duration

    init(
        commandDelay: Duration = .milliseconds(120),
        protectionDuration: Duration = .milliseconds(400),
        stabilityDuration: Duration = .milliseconds(120)
    ) {
        self.commandDelay = commandDelay
        self.protectionDuration = protectionDuration
        self.stabilityDuration = stabilityDuration
    }

    // MARK: - Commands

    /// Flips the glyph immediately; only the final intent in a burst reaches the backend.
    func toggle(apply: @escaping @MainActor (Bool) async -> Void) {
        setPlaying(!isPlaying)
        let intendedPlaying = isPlaying
        let generation = commandGeneration
        let delay = commandDelay
        commandTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch { return }
            guard !Task.isCancelled else { return }

            // Detach before applying so resets triggered by the command itself
            // (e.g. replay reloading the item) can't cancel it midway.
            if let self, self.commandGeneration == generation {
                self.commandTask = nil
            }
            await apply(intendedPlaying)
        }
    }

    /// Explicit commands (including system and sleep-timer pauses) supersede queued taps.
    func setPlaying(_ playing: Bool) {
        cancelPendingWork()
        isPlaying = playing
        protectedUntil = ContinuousClock.now.advanced(by: protectionDuration)
    }

    func reset() {
        cancelPendingWork()
        protectedUntil = nil
        isPlaying = false
    }

    // MARK: - Backend Reconciliation

    func receive(_ state: PlaybackState) {
        reconciliationTask?.cancel()
        reconciliationTask = nil

        let playing: Bool
        switch state {
        case .playing: playing = true
        case .paused: playing = false
        case .idle, .ended, .failed:
            reset()
            return
        case .loading, .ready, .buffering:
            // Waiting for data is not a change in play/pause intent.
            return
        }

        let now = ContinuousClock.now
        let deadline = max(now.advanced(by: stabilityDuration), protectedUntil ?? now)
        reconciliationTask = Task { [weak self] in
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.isPlaying = playing
            self.reconciliationTask = nil
        }
    }

    private func cancelPendingWork() {
        commandGeneration += 1
        commandTask?.cancel()
        commandTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
    }
}
