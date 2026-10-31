import FleetKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Answers a phone's `file.read`: a link in a transcript named a file on this Mac and the
/// reader tapped it.
///
/// **No new boundary, and none pretended.** A paired phone can already type any command into
/// any tab's shell, so refusing it a file it could `cat` there would protect nothing. What
/// this does keep is the shape of a read: a regular file, a bounded range per reply, and a
/// relative path resolved where the agent that wrote it was working — never against this
/// process's own cwd, which is `/` for an app launched from Finder.
///
/// Like `TimelineService`, the resolution is main-actor (it asks the store) and the I/O is
/// not: a large image's decode is tens of milliseconds the Mac's own UI should not stall on.
@MainActor
final class FileReadService {
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func read(
        session: UUID, path: String, offset: Int64, limit: Int, maxPixel: Int?
    ) async -> Result<WireFileChunk, TimelineErrorCode> {
        guard let bases = store.fileBases(of: session) else { return .failure("unknown_session") }
        return await Task.detached(priority: .userInitiated) {
            guard let url = Self.resolve(path, bases: bases) else { return .failure("not_found") }
            if let maxPixel { return Self.image(at: url, maxPixel: maxPixel) }
            return Self.bytes(at: url, offset: offset, limit: limit)
        }.value
    }

    /// The file `path` names, or `nil` when no candidate is a regular file. `file://` and
    /// percent-escapes are undone here rather than on the phone so the CLI can send either.
    /// A relative path is tried against each base in turn, because a tab that followed its
    /// agent into a worktree still has links in its history written from the project root.
    nonisolated static func resolve(_ path: String, bases: [String]) -> URL? {
        var raw = path
        if let url = URL(string: raw), url.isFileURL { raw = url.path }
        else if raw.contains("%"), let decoded = raw.removingPercentEncoding { raw = decoded }
        raw = (raw as NSString).expandingTildeInPath
        guard !raw.isEmpty else { return nil }
        let candidates = raw.hasPrefix("/")
            ? [raw]
            : bases.map { ($0 as NSString).appendingPathComponent(raw) }
        for candidate in candidates {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return url
            }
        }
        return nil
    }

    /// Up to `limit` bytes from `offset`, clamped to `FileLimits.maxChunk` whatever was asked.
    nonisolated static func bytes(at url: URL, offset: Int64, limit: Int) -> Result<WireFileChunk, TimelineErrorCode> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .failure("unreadable") }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .failure("unreadable") }
        let start = min(max(0, offset), Int64(size))
        let count = min(max(0, limit), FileLimits.maxChunk)
        do {
            try handle.seek(toOffset: UInt64(start))
            let data = try handle.read(upToCount: count) ?? Data()
            return .success(WireFileChunk(path: url.path, size: Int64(size), offset: start, data: data))
        } catch {
            return .failure("unreadable")
        }
    }

    /// The image itself when it already fits — in pixels and in `FileLimits.maxImageBytes` —
    /// otherwise a re-encode whose long side is `maxPixel`. Downsampled here rather than on
    /// the phone because the point is not to send a 40 MB photo over cellular to show it at
    /// the width of a phone.
    nonisolated static func image(at url: URL, maxPixel: Int) -> Result<WireFileChunk, TimelineErrorCode> {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return .failure("not_an_image") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
        let longSide = max(width ?? .max, height ?? .max)
        let pixel = max(1, maxPixel)

        if longSide <= pixel, fileSize <= FileLimits.maxImageBytes, let data = try? Data(contentsOf: url) {
            return .success(WireFileChunk(path: url.path, size: Int64(data.count), offset: 0, data: data,
                                          pixelWidth: width, pixelHeight: height))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixel,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return .failure("not_an_image") }
        // PNG only where there is transparency to keep: a screenshot-sized PNG re-encoded as
        // PNG is still megabytes, and JPEG is what makes the downsample worth the trip.
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(thumbnail.alphaInfo)
        let type = (opaque ? UTType.jpeg : UTType.png).identifier as CFString
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, type, 1, nil) else {
            return .failure("not_an_image")
        }
        CGImageDestinationAddImage(destination, thumbnail,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return .failure("not_an_image") }
        let data = out as Data
        return .success(WireFileChunk(path: url.path, size: Int64(data.count), offset: 0, data: data,
                                      downsampled: true, pixelWidth: width, pixelHeight: height))
    }
}
