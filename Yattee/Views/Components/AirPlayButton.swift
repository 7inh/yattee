//
//  AirPlayButton.swift
//  Yattee
//
//  SwiftUI wrapper for AVRoutePickerView to show AirPlay device selection.
//

import AVKit
import SwiftUI

import UIKit

struct AirPlayButton: UIViewRepresentable {
    var tintColor: UIColor = .white

    func makeUIView(context: Context) -> AVRoutePickerView {
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = tintColor
        routePicker.activeTintColor = .systemBlue
        return routePicker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tintColor
    }
}
