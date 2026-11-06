//
//  PlayPauseSymbol.swift
//  Yattee
//
//  Shared transport glyph and press feedback for full and compact players.
//

import Foundation
import SwiftUI

struct PlayPauseSymbol: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPlaying: Bool

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace.downUp))
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: isPlaying)
    }
}

struct PlayPauseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
