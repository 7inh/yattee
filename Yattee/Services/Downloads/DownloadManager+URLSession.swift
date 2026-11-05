//
//  DownloadManager+URLSession.swift
//  Yattee
//
//  Background byte-range download callbacks.
//

import Foundation

extension DownloadManager {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                               didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in self.receivedProgress(id: id, taskID: taskID, bytes: totalBytesWritten) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: copy)
            let response = downloadTask.response as? HTTPURLResponse
            let taskID = downloadTask.taskIdentifier
            Task { @MainActor in self.receivedRange(id: id, taskID: taskID, response: response, location: copy) }
        } catch {
            Task { @MainActor in self.failed(id, taskID: downloadTask.taskIdentifier, error: error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled,
              let id = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in self.failed(id, taskID: taskID, error: error) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
