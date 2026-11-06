//
//  PlayerPanelScrollDetents.swift
//  Yattee
//
//  Selects snap destinations between the player, cover and freely scrolling queue.
//

import Foundation

struct PlayerPanelScrollDetents: Sendable {
    // Leave C inside the scroll range despite pixel rounding at the bottom edge.
    static let fullQueueScrollMargin: CGFloat = 2

    let halfOpenOffset: CGFloat
    let fullQueueOffset: CGFloat

    /// Keep C reachable even after the player has finished morphing.
    func minimumContentHeight(viewportHeight: CGFloat) -> CGFloat {
        fullQueueOffset + Self.fullQueueScrollMargin + max(0, viewportHeight)
    }

    /// Natural content includes the player, queue rows and normal bottom inset.
    func bottomFillerHeight(naturalContentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, minimumContentHeight(viewportHeight: viewportHeight) - naturalContentHeight)
    }

    static func viewportHeight(containerHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat) -> CGFloat {
        max(0, containerHeight - topInset - bottomInset)
    }

    static func maximumOffset(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        max(0, contentHeight - max(0, viewportHeight))
    }

    static func clampedOffset(_ offset: CGFloat, maximumOffset: CGFloat) -> CGFloat {
        min(max(0, offset), max(0, maximumOffset))
    }

    /// Reaching A during a gesture from B/C must not enable dismissal mid-drag.
    static func allowsDismissal(offset: CGFloat, gestureStartOffset: CGFloat?) -> Bool {
        offset <= 1 && (gestureStartOffset ?? offset) <= 1
    }

    /// A nil destination leaves native queue scrolling or top-edge dismissal alone.
    func targetOffset(
        startOffset: CGFloat,
        releaseOffset: CGFloat,
        velocity: CGFloat,
        maximumOffset: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat? {
        let tolerance: CGFloat = 1
        let flickVelocity: CGFloat = 250

        // Clamp free queue scrolling only beyond C. An undersized content range
        // must never turn its bottom edge into a fourth panel detent.
        if maximumOffset >= fullQueueOffset, startOffset >= fullQueueOffset - tolerance,
           releaseOffset > fullQueueOffset, releaseOffset > maximumOffset {
            return Self.clampedOffset(releaseOffset, maximumOffset: maximumOffset)
        }

        // Only releases still inside the queue retain native scrolling. Once
        // the finger crosses C, the same gesture can collapse the panel.
        if maximumOffset >= fullQueueOffset, startOffset >= fullQueueOffset - tolerance, releaseOffset > fullQueueOffset {
            return nil
        }
        if startOffset <= tolerance, releaseOffset <= 0 {
            return nil
        }

        // Keep the real coordinates. During a geometry update, fall back to a
        // reachable detent instead of resting in the B-to-C transition.
        let offsets: [CGFloat] = [0, halfOpenOffset, fullQueueOffset].filter { $0 <= max(0, maximumOffset) }
        let nearestOffset = offsets.min { abs($0 - releaseOffset) < abs($1 - releaseOffset) }
        guard abs(velocity) >= flickVelocity else { return nearestOffset }

        // A flick advances at least one detent. Project from the release so a
        // long drag or fast flick can also pass B on its way between A and C.
        let projectedOffset = releaseOffset + velocity * 0.2
        let projectedDetent = offsets.min { abs($0 - projectedOffset) < abs($1 - projectedOffset) } ?? 0
        let panelStartOffset = min(fullQueueOffset, max(0, startOffset))
        if velocity >= flickVelocity {
            let nextOffset = offsets.first { $0 > panelStartOffset + tolerance } ?? offsets.last ?? 0
            return max(nextOffset, projectedDetent)
        }
        let previousOffset = offsets.last { $0 < panelStartOffset - tolerance } ?? 0
        return min(previousOffset, projectedDetent)
    }
}
