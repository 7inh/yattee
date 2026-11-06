//
//  ResumeConfirmationDialog.swift
//  Yattee
//
//  Native confirmation dialog for resuming a partially watched video.
//

import Foundation
import SwiftUI

private struct ResumeConfirmationDialog: ViewModifier {
    let videoTitle: String
    @Binding var resumeTime: TimeInterval?
    let onContinue: (TimeInterval) -> Void
    let onStartOver: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: videoTitle),
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: resumeTime
            ) { time in
                Button(String(localized: "resume.action.continueAt \(time.formattedAsTimestamp)")) {
                    onContinue(time)
                }
                Button(String(localized: "resume.action.startFromBeginning")) {
                    onStartOver()
                }
                Button(String(localized: "common.cancel"), role: .cancel) {}
            }
            .dismissesOnExternalNavigation(isPresented)
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { resumeTime != nil },
            set: { presented in
                if !presented {
                    resumeTime = nil
                }
            }
        )
    }
}

extension View {
    /// Offers native resume choices, using the timestamp captured when playback was requested.
    func resumeConfirmationDialog(
        videoTitle: String,
        resumeTime: Binding<TimeInterval?>,
        onContinue: @escaping (TimeInterval) -> Void,
        onStartOver: @escaping () -> Void
    ) -> some View {
        modifier(ResumeConfirmationDialog(
            videoTitle: videoTitle,
            resumeTime: resumeTime,
            onContinue: onContinue,
            onStartOver: onStartOver
        ))
    }
}
