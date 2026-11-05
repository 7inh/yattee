//
//  OpenLinkSheet.swift
//  Yattee
//
//  Opens or downloads YouTube and Invidious links.
//

import Foundation
import SwiftUI

struct OpenLinkSheet: View {
    @Environment(\.appEnvironment) private var appEnvironment
    @Environment(\.dismiss) private var dismiss
    var prefilledURL: URL? = nil
    @State private var text = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var urls: [URL] {
        text.split(whereSeparator: \.isWhitespace).compactMap { URL(string: String($0)) }.prefix(200).map { $0 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("YouTube or Invidious links") {
                    TextEditor(text: $text).frame(minHeight: 120).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                Button("Play") { Task { await perform(download: false) } }
                Button("Download audio") { Task { await perform(download: true) } }
                if isLoading { ProgressView() }
            }
            .disabled(isLoading)
            .navigationTitle("Open Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { sheetCloseToolbarItem { dismiss() } }
        }
        .onAppear { text = prefilledURL?.absoluteString ?? "" }
    }

    private func perform(download: Bool) async {
        guard let appEnvironment, !urls.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        let resolver = LinkVideoResolver(appEnvironment: appEnvironment)
        do {
            if download {
                let result = await resolver.downloadLinks(urls)
                if result.failed > 0 { errorMessage = "Downloaded \(result.succeeded); failed \(result.failed)."; return }
            } else {
                for (index, url) in urls.enumerated() {
                    if index == 0, urls.count == 1 {
                        let destination = try await resolver.resolveDestination(url)
                        if case .video(.loaded(let video), _) = destination {
                            await resolver.play(video, from: url, startTime: URLRouter().parseTimestamp(url))
                        } else { appEnvironment.navigationCoordinator.navigateToOpenedLink(destination) }
                    } else {
                        let (video, _, _, _) = try await resolver.resolve(url)
                        if index == 0 { appEnvironment.playerService.openVideo(video) }
                        else { appEnvironment.queueManager.addToQueue(video) }
                    }
                }
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
