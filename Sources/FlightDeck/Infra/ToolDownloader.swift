import Foundation

/// Fetches one release asset to a local file the caller then owns (and deletes). A protocol so
/// `ToolResolverTests` never touches the network: the checksum and unpack paths run against
/// stub files instead.
protocol ToolDownloading: Sendable {
    /// `progress` gets a fraction in 0...1 when the server sent a length, and is not called
    /// otherwise.
    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// The real downloader: one `URLSession` download task per fetch, with a delegate for progress.
///
/// **Why not `URLSession.download(from:delegate:)`.** The async API's per-task delegate is a
/// `URLSessionTaskDelegate`; `didWriteData` is a download-delegate method it does not promise to
/// call, and a multi-hundred-megabyte gcloud tarball with no progress reads as a hang. A session
/// owned by its delegate does call it.
struct URLSessionToolDownloader: ToolDownloading {
    func fetch(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = Delegate(progress: progress)
        // The session retains its delegate until invalidated; `finishTasksAndInvalidate` below
        // breaks that cycle once the single task is done.
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let task = session.downloadTask(with: url)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        // Set before `resume()` and read only from the session's serial delegate queue after it.
        var continuation: CheckedContinuation<URL, Error>?
        var task: URLSessionDownloadTask?
        private var moved: URL?

        init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        }

        /// URLSession deletes `location` as soon as this returns, so the file is moved out
        /// here, synchronously — completion is reported from `didCompleteWithError`, which
        /// is also where an HTTP error status turns into a failure instead of a saved error page.
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("flightdeck-tool-\(UUID().uuidString)")
            moved = (try? FileManager.default.moveItem(at: location, to: destination)) == nil ? nil : destination
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let continuation else { return }
            self.continuation = nil
            if let error { return continuation.resume(throwing: error) }
            let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let moved else {
                if let moved { try? FileManager.default.removeItem(at: moved) }
                return continuation.resume(throwing: URLError(.badServerResponse,
                                                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"]))
            }
            continuation.resume(returning: moved)
        }
    }
}
