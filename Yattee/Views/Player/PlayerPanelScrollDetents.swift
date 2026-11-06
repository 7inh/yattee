//
//  PlayerPanelScrollDetents.swift
//  Yattee
//
//  Selects snap destinations between the player, cover and freely scrolling queue.
//

import Foundation

struct PlayerPanelScrollDetents: Sendable {
    let halfOpenOffset: CGFloat
    let fullQueueOffset: CGFloat

    /// Reaching A during a gesture from B/C must not enable dismissal mid-drag.
    static func allowsDismissal(offset: CGFloat, gestureStartOffset: CGFloat?) -> Bool {
        offset <= 1 && (gestureStartOffset ?? offset) <= 1
    }

    /// A nil destination leaves native queue scrolling or top-edge dismissal alone.
    func targetOffset(startOffset: CGFloat, releaseOffset: CGFloat, velocity: CGFloat) -> CGFloat? {
        let tolerance: CGFloat = 1
        let flickVelocity: CGFloat = 250

        // Only releases still inside the queue retain native scrolling. Once
        // the finger crosses C, the same gesture can collapse the panel.
        if startOffset >= fullQueueOffset - tolerance, releaseOffset > fullQueueOffset {
            return nil
        }
        if startOffset <= tolerance, releaseOffset <= 0 {
            return nil
        }

        let offsets: [CGFloat] = [0, halfOpenOffset, fullQueueOffset]
        let nearestOffset = offsets.min { abs($0 - releaseOffset) < abs($1 - releaseOffset) }
        guard abs(velocity) >= flickVelocity else { return nearestOffset }

        // A flick advances at least one detent. Project from the release so a
        // long drag or fast flick can also pass B on its way between A and C.
        let projectedOffset = releaseOffset + velocity * 0.2
        let projectedDetent = offsets.min { abs($0 - projectedOffset) < abs($1 - projectedOffset) } ?? 0
        let panelStartOffset = min(fullQueueOffset, max(0, startOffset))
        if velocity >= flickVelocity {
            let nextOffset = offsets.first { $0 > panelStartOffset + tolerance } ?? fullQueueOffset
            return max(nextOffset, projectedDetent)
        }
        let previousOffset = offsets.last { $0 < panelStartOffset - tolerance } ?? 0
        return min(previousOffset, projectedDetent)
    }
}
