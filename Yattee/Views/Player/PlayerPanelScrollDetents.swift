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

    /// Limits queue deceleration so momentum cannot collapse the player.
    func queueTargetOffset(startOffset: CGFloat, proposedOffset: CGFloat) -> CGFloat {
        guard startOffset >= fullQueueOffset - 1 else { return proposedOffset }
        return max(fullQueueOffset, proposedOffset)
    }

    /// A nil destination leaves native queue scrolling or top-edge dismissal alone.
    func targetOffset(startOffset: CGFloat, releaseOffset: CGFloat, velocity: CGFloat) -> CGFloat? {
        let tolerance: CGFloat = 1
        let flickVelocity: CGFloat = 250

        // A gesture that began inside the queue can return to its top, but
        // collapsing the player requires another gesture from that boundary.
        if startOffset > fullQueueOffset + tolerance {
            return releaseOffset < fullQueueOffset ? fullQueueOffset : nil
        }
        if startOffset >= fullQueueOffset - tolerance, releaseOffset > fullQueueOffset {
            return nil
        }
        if startOffset <= tolerance, releaseOffset <= 0 {
            return nil
        }

        let offsets: [CGFloat] = [0, halfOpenOffset, fullQueueOffset]
        if velocity >= flickVelocity {
            return offsets.first { $0 > startOffset + tolerance } ?? fullQueueOffset
        }
        if velocity <= -flickVelocity {
            return offsets.last { $0 < startOffset - tolerance } ?? 0
        }
        return offsets.min { abs($0 - releaseOffset) < abs($1 - releaseOffset) }
    }
}
