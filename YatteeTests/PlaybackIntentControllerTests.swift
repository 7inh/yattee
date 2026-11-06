//
//  PlaybackIntentControllerTests.swift
//  Yattee
//
//  Regression coverage for rapid transport taps and delayed backend feedback.
//

import Foundation
import Testing
@testable import Yattee

@Suite("Playback intent")
@MainActor
struct PlaybackIntentControllerTests {
    @Test("Rapid taps update intent immediately and send only the final command")
    func rapidTapsCoalesce() async throws {
        let intent = PlaybackIntentController()
        var commands: [Bool] = []
        intent.setPlaying(true)

        for playing in [false, true, false, true, false] {
            intent.toggle { commands.append($0) }
            #expect(intent.isPlaying == playing)
            try await Task.sleep(for: .milliseconds(25))
            #expect(commands.isEmpty)
        }
        #expect(commands.isEmpty)

        try await waitUntil { commands.count == 1 }
        #expect(commands == [false])
        #expect(!intent.isPlaying)
    }

    @Test("Backend bounces cannot undo a recent tap")
    func backendBounceDuringProtection() async throws {
        let intent = PlaybackIntentController()
        intent.setPlaying(true)
        intent.toggle { _ in }
        intent.receive(.playing)
        intent.receive(.paused)
        intent.receive(.playing)

        try await Task.sleep(for: .milliseconds(200))
        #expect(!intent.isPlaying)

        // A buffering update cancels reconciliation of the previous playing event.
        intent.receive(.buffering)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!intent.isPlaying)
    }

    @Test("Buffering never flips the glyph, even after the tap protection expires")
    func bufferingPreservesIntent() async throws {
        let intent = PlaybackIntentController()
        intent.toggle { _ in }
        intent.receive(.paused)
        intent.receive(.buffering)

        try await Task.sleep(for: .milliseconds(500))
        #expect(intent.isPlaying)

        intent.receive(.loading)
        intent.receive(.ready)
        #expect(intent.isPlaying)
    }

    @Test("Stable backend pauses reconcile after protection expires")
    func stableBackendPause() async throws {
        let intent = PlaybackIntentController()
        intent.setPlaying(true)
        intent.receive(.paused)
        #expect(intent.isPlaying)

        try await Task.sleep(for: .milliseconds(200))
        #expect(intent.isPlaying)
        try await waitUntil { !intent.isPlaying }
    }

    @Test("Explicit pauses supersede a pending tap, including sleep timer and remote commands")
    func explicitPauseCancelsPendingPlay() async throws {
        let intent = PlaybackIntentController()
        var commands: [Bool] = []
        intent.toggle { commands.append($0) }
        intent.setPlaying(false)

        try await Task.sleep(for: .milliseconds(250))
        #expect(!intent.isPlaying)
        #expect(commands.isEmpty)
    }

    @Test("End, error and teardown cancel pending commands", arguments: [
        PlaybackState.ended, .failed(URLError(.networkConnectionLost)), .idle
    ])
    func terminalStatesCancelCommands(state: PlaybackState) async throws {
        let intent = PlaybackIntentController()
        var commands: [Bool] = []
        intent.toggle { commands.append($0) }
        intent.receive(state)

        try await Task.sleep(for: .milliseconds(250))
        #expect(!intent.isPlaying)
        #expect(commands.isEmpty)
    }

    @Test("Changing playback cancels stale backend reconciliation")
    func resetCancelsReconciliation() async throws {
        let intent = PlaybackIntentController()
        intent.setPlaying(true)
        intent.receive(.playing)
        intent.reset()

        try await Task.sleep(for: .milliseconds(500))
        #expect(!intent.isPlaying)
    }

    @Test("A newer tap cancels an in-flight asynchronous command such as replay seeking")
    func inFlightCommandIsCancelled() async throws {
        let intent = PlaybackIntentController()
        var replayStarted = false
        var replayResumed = false
        var pauseApplied = false
        intent.toggle { _ in
            replayStarted = true
            // Model a seek that finishes even if its calling task was cancelled.
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { replayResumed = true }
        }
        try await waitUntil { replayStarted }

        intent.toggle { _ in pauseApplied = true }
        try await waitUntil { pauseApplied }
        #expect(!replayResumed)
        #expect(!intent.isPlaying)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
