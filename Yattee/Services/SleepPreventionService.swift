//
//  SleepPreventionService.swift
//  Yattee
//
//  Service to prevent system sleep during video playback.
//

import Foundation

import UIKit


/// Service that manages system sleep prevention during video playback.
/// Prevents the display from sleeping while video is actively playing.
@MainActor
final class SleepPreventionService {
    /// Whether sleep prevention is currently active.
    private var isPreventingSleep = false


    /// Prevents the system from sleeping.
    /// Call this when video playback starts or resumes.
    func preventSleep() {
        guard !isPreventingSleep else { return }
        isPreventingSleep = true

        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// Allows the system to sleep normally.
    /// Call this when video playback pauses or stops.
    func allowSleep() {
        guard isPreventingSleep else { return }
        isPreventingSleep = false

        UIApplication.shared.isIdleTimerDisabled = false
    }
}
