//
//  YatteeLiveActivityBundle.swift
//  YatteeLiveActivity
//
//  Lock-screen and Dynamic Island card for setting the sleep timer.
//

import SwiftUI
import WidgetKit
import ActivityKit
import AppIntents

@main
struct YatteeLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        SleepTimerLiveActivity()
    }
}

struct SleepTimerLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepTimerActivityAttributes.self) { context in
            SleepTimerLockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "moon.zzz.fill")
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SleepTimerStatusText(state: context.state)
                        .font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    SleepTimerButtons(state: context.state)
                }
            } compactLeading: {
                Image(systemName: "moon.zzz.fill")
            } compactTrailing: {
                SleepTimerStatusText(state: context.state, compact: true)
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "moon.zzz.fill")
            }
        }
    }
}

private struct SleepTimerLockScreenView: View {
    let state: SleepTimerActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "moon.zzz.fill")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(state.author)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                SleepTimerStatusText(state: state)
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
            SleepTimerButtons(state: state)
        }
        .foregroundStyle(.white)
    }
}

private struct SleepTimerStatusText: View {
    let state: SleepTimerActivityAttributes.ContentState
    var compact = false

    var body: some View {
        if let endDate = state.endDate, endDate > .now {
            Text(timerInterval: Date.now...endDate, countsDown: true)
                .multilineTextAlignment(.trailing)
        } else if state.endsWithVideo {
            Text(compact ? "End" : "End of video")
        } else {
            Text("Off")
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

private struct SleepTimerButtons: View {
    let state: SleepTimerActivityAttributes.ContentState

    private var isActive: Bool {
        (state.endDate.map { $0 > .now } ?? false) || state.endsWithVideo
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach([15, 30, 45, 60], id: \.self) { minutes in
                Button(intent: SetSleepTimerIntent(minutes: minutes)) {
                    label("\(minutes)m")
                }
            }
            Button(intent: SetSleepTimerIntent(minutes: SetSleepTimerIntent.endOfVideoValue)) {
                label("End")
            }
            if isActive {
                Button(intent: SetSleepTimerIntent(minutes: SetSleepTimerIntent.offValue)) {
                    Image(systemName: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel("Turn off sleep timer")
            }
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.white)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
    }
}
