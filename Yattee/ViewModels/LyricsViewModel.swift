//
//  LyricsViewModel.swift
//  Yattee
//
//  Loads caption choices and the selected lyrics without retaining stale video results.
//

import Foundation
import SwiftUI

@MainActor
@Observable
final class LyricsViewModel {
    private(set) var videoID: String?
    private(set) var tracks: [Caption] = []
    var selectedTrack: Caption?
    private(set) var lines: [LyricLine] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var instance: Instance?
    @ObservationIgnored private var contentService: ContentService?

    func loadTracks(videoID: String?, instance: Instance?, contentService: ContentService?) async {
        self.videoID = videoID
        self.instance = instance
        self.contentService = contentService
        tracks = []
        selectedTrack = nil
        lines = []
        errorMessage = nil
        isLoading = false
        guard let videoID, let instance, let contentService else { return }
        do {
            let captions = try await contentService.captions(videoID: videoID, instance: instance)
            guard !Task.isCancelled, self.videoID == videoID else { return }
            tracks = captions
            selectedTrack = Caption.preferred(in: captions)
        } catch {
            guard !Task.isCancelled, self.videoID == videoID else { return }
            LoggingService.shared.warning("Could not load lyric tracks for \(videoID): \(error.localizedDescription)", category: .player)
        }
    }

    func loadLyrics() async {
        lines = []
        errorMessage = nil
        guard let videoID, let selectedTrack, let instance, let contentService else { return }
        isLoading = true
        defer {
            if self.videoID == videoID, self.selectedTrack == selectedTrack, !Task.isCancelled {
                isLoading = false
            }
        }
        do {
            let lyrics = try await contentService.lyrics(videoID: videoID, caption: selectedTrack, instance: instance)
            guard !Task.isCancelled, self.videoID == videoID, self.selectedTrack == selectedTrack else { return }
            lines = lyrics
        } catch {
            guard !Task.isCancelled, self.videoID == videoID, self.selectedTrack == selectedTrack else { return }
            errorMessage = error.localizedDescription
            LoggingService.shared.warning("Could not load lyrics for \(videoID): \(error.localizedDescription)", category: .player)
        }
    }
}
