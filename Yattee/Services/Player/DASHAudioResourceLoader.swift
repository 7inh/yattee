//
//  DASHAudioResourceLoader.swift
//  Yattee
//
//  Serves an in-memory HLS playlist; AVPlayer fetches its absolute HTTPS media URLs.
//

import Foundation
@preconcurrency import AVFoundation

final class DASHAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {
    let url = URL(string: "yattee-audio://playlist/\(UUID().uuidString).m3u8")!
    private let data: Data

    init(playlist: String) {
        data = Data(playlist.utf8)
        super.init()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard request.request.url == url else { return false }
        if let information = request.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = true
        }
        if let requestedData = request.dataRequest {
            let offset = max(requestedData.requestedOffset, requestedData.currentOffset)
            guard offset >= 0, offset <= Int64(data.count), requestedData.requestedOffset >= 0,
                  requestedData.requestedLength >= 0 else {
                request.finishLoading(with: DASHAudioError.invalidRange)
                return true
            }
            let remaining = max(Int64(requestedData.requestedLength) - (offset - requestedData.requestedOffset), 0)
            let count = requestedData.requestsAllDataToEndOfResource
                ? data.count - Int(offset) : Int(min(remaining, Int64(data.count) - offset))
            requestedData.respond(with: data.subdata(in: Int(offset)..<(Int(offset) + count)))
        }
        request.finishLoading()
        return true
    }
}
