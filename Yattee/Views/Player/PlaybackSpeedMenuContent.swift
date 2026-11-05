//
//  PlaybackSpeedMenuContent.swift
//  Yattee
//
//  Shared playback speed choices for iOS player menus.
//

import SwiftUI

#if os(iOS)

struct PlaybackSpeedMenuContent: View {
    let currentRate: PlaybackRate
    let onRateChanged: (PlaybackRate) -> Void

    var body: some View {
        ForEach(PlaybackRate.allCases) { rate in
            Button {
                onRateChanged(rate)
            } label: {
                HStack {
                    Text(rate.displayText)
                    if currentRate == rate {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
}

#endif
