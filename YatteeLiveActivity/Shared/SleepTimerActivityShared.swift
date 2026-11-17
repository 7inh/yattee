//
//  SleepTimerActivityShared.swift
//  Yattee
//
//  Live Activity data and the button intent shared by the app and the widget extension.
//

#if os(iOS)
import Foundation
import ActivityKit
import AppIntents

/// The lock-screen card that shows the sleep timer next to the playing video.
struct SleepTimerActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var title: String
        var author: String
        /// When the countdown ends; nil when no countdown is running.
        var endDate: Date?
        /// The timer stops playback when the current video ends.
        var endsWithVideo: Bool
    }
}

/// Lets the app run the intent: the widget extension has no player to change.
@MainActor
enum SleepTimerIntentBridge {
    static var handler: ((Int) -> Void)?
}

/// Sets the sleep timer from a lock-screen button. It is compiled into both the
/// app and the extension, so iOS runs it in the app's process.
struct SetSleepTimerIntent: LiveActivityIntent {
    static let offValue = 0
    static let endOfVideoValue = -1

    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let isDiscoverable = false

    /// Minutes, or `offValue` / `endOfVideoValue`.
    @Parameter(title: "Minutes")
    var minutes: Int

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult {
        let minutes = minutes
        await MainActor.run { SleepTimerIntentBridge.handler?(minutes) }
        return .result()
    }
}
#endif
