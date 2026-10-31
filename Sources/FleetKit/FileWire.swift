import Foundation

/// One read of a file on the Mac, the reply to `FleetRequest.fileRead`: what the phone shows
/// when a link in a transcript names a local file.
///
/// **A byte range, never the whole file.** A transcript links logs and generated sources as
/// readily as a README, and one frame is capped at `TimelineLimits.maximumMessageSize` — a
/// 30 MB log sent whole would be refused by the phone's own receive limit and cost the socket.
/// So the phone asks for `FileLimits.textChunk` at a time and pages on as the reader scrolls,
/// and `size` says how much is left.
public struct WireFileChunk: Codable, Equatable, Sendable {
    /// The file actually read: absolute, symlinks resolved. A relative link in a markdown file
    /// the phone opened resolves against this, not against the link that reached it.
    public let path: String
    /// The whole file's size in bytes, or for `downsampled` the size of `data`.
    public let size: Int64
    /// Where `data` starts in the file.
    public let offset: Int64
    public let data: Data
    /// `data` is an image the Mac re-encoded at `maxPixel` rather than the file's own bytes.
    /// The original's pixel size rides beside it so the viewer can say what was scaled.
    public let downsampled: Bool
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(path: String, size: Int64, offset: Int64, data: Data, downsampled: Bool = false,
                pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.path = path; self.size = size; self.offset = offset; self.data = data
        self.downsampled = downsampled; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    /// Whether this chunk reaches the end of the file.
    public var isLast: Bool { offset + Int64(data.count) >= size }
}

public enum FileLimits {
    /// Bytes the phone asks for per text read. Small enough that the first screen of a
    /// markdown file lands in one round trip over a weak link, large enough that a long file
    /// is a handful of reads rather than hundreds.
    public static let textChunk = 262_144
    /// The most the Mac sends in one reply, whatever it was asked for. Base64 grows it by a
    /// third, which keeps a reply well under `TimelineLimits.maximumMessageSize`.
    public static let maxChunk = 1_048_576
    /// The largest image the Mac sends as its own bytes; anything bigger, in bytes or in
    /// pixels, is re-encoded at the requested `maxPixel`.
    public static let maxImageBytes = 2_097_152
}
