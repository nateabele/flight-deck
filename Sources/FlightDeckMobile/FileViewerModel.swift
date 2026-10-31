import FleetKit
import Foundation
import Observation
import UIKit

/// A file on the Mac, read in `FileLimits.textChunk` pieces as the reader scrolls toward the
/// end of what has arrived.
///
/// **Buffered because transcripts link big files.** A build log or a generated source is as
/// likely a target as a README, and fetching one whole would hold the screen on a spinner for
/// the length of a cellular download, then hand SwiftUI one `Text` it cannot lay out. So the
/// first chunk draws at once, the next is asked for only when the end of this one comes into
/// view, and `maxBuffered` is where it stops: past that the reader is told how much is left
/// rather than the phone holding the whole thing.
@MainActor
@Observable
final class FileViewerModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    let route: FileRoute
    private(set) var phase: Phase = .loading
    /// The Mac's absolute path, once the first reply names it.
    private(set) var resolvedPath: String?
    /// The file's size on the Mac, in bytes.
    private(set) var size: Int64 = 0
    /// Bytes read so far; the next request's offset.
    private(set) var loaded: Int64 = 0
    private(set) var isLoadingMore = false
    private(set) var moreFailed = false

    /// Markdown: the blocks safe to draw — the last split block is held back until the file's
    /// end arrives, because the chunk boundary may fall inside it (half a fence, half a table).
    private(set) var blocks: [PlanBlocks.Block] = []
    /// Text: the file in `linesPerGroup`-line runs, so a long file is many small views a lazy
    /// stack can recycle rather than one `Text` the size of the file.
    private(set) var groups: [String] = []
    private(set) var lineCount = 0

    private(set) var image: UIImage?
    private(set) var downsampledFrom: (width: Int, height: Int)?

    nonisolated static let linesPerGroup = 40
    /// The most text the phone keeps. Generous for anything a person reads on a phone, and a
    /// bound on what one screen can cost.
    static let maxBuffered: Int64 = 16 * 1_048_576

    /// Strong: nothing the fleet holds points back at a viewer, so there is no cycle to break.
    private let reader: any FileReading
    private let maxPixel: Int
    /// UTF-8 bytes from the end of the last chunk that did not complete a character.
    private var carry = Data()
    /// The text decoded so far (markdown), or the unfinished last line (text).
    private var text = ""
    private var partialLine = ""

    init(route: FileRoute, reader: any FileReading, maxPixel: Int = FileViewerModel.screenPixels) {
        self.route = route
        self.reader = reader
        self.maxPixel = maxPixel
    }

    /// The device's long side in pixels: an image sent at this size fills the screen at 1:1.
    static var screenPixels: Int {
        let bounds = UIScreen.main.nativeBounds
        return Int(max(bounds.width, bounds.height))
    }

    var isComplete: Bool { loaded >= size && phase == .loaded }
    var isTruncated: Bool { loaded < size && loaded >= Self.maxBuffered }

    func start() {
        guard phase != .loaded, !isLoadingMore else { return }
        phase = .loading
        fetch()
    }

    /// The end of what is drawn has come into view.
    func loadMore() {
        guard phase == .loaded, !isLoadingMore, loaded < size, loaded < Self.maxBuffered else { return }
        moreFailed = false
        fetch()
    }

    private func fetch() {
        isLoadingMore = true
        let isImage = route.link.kind == .image
        reader.readFile(
            session: route.session, path: route.link.path, offset: loaded,
            limit: FileLimits.textChunk, maxPixel: isImage ? maxPixel : nil
        ) { [weak self] result in
            guard let self else { return }
            self.isLoadingMore = false
            switch result {
            case .success(let chunk): self.accept(chunk)
            case .failure(let error): self.fail(error)
            }
        }
    }

    private func fail(_ error: FleetRequestError) {
        if phase == .loaded { moreFailed = true; return }
        phase = .failed(Self.message(for: error, path: route.link.path))
    }

    func accept(_ chunk: WireFileChunk) {
        resolvedPath = chunk.path
        size = chunk.size
        loaded = chunk.offset + Int64(chunk.data.count)
        switch route.link.kind {
        case .image:
            guard let image = UIImage(data: chunk.data) else {
                phase = .failed("This image couldn't be decoded.")
                return
            }
            self.image = image
            if chunk.downsampled, let w = chunk.pixelWidth, let h = chunk.pixelHeight { downsampledFrom = (w, h) }
            phase = .loaded
        case .markdown, .text:
            // A NUL in the first chunk is a binary file with a text-looking name; drawing it
            // as replacement characters helps nobody.
            if chunk.offset == 0, chunk.data.prefix(8_192).contains(0) {
                phase = .failed("This file isn't text.")
                return
            }
            append(decode(chunk.data, final: chunk.isLast), final: chunk.isLast)
            phase = .loaded
            // Asked for a line not yet here: keep reading toward it.
            if let line = route.link.line, line > lineCount, !chunk.isLast, case .text = route.link.kind {
                loadMore()
            }
        }
    }

    /// UTF-8 decode that never splits a character across chunks: trailing bytes of an
    /// unfinished sequence wait in `carry` for the next one.
    private func decode(_ data: Data, final: Bool) -> String {
        var bytes = carry + data
        carry = Data()
        if !final {
            let cut = Self.completeUTF8Prefix(bytes)
            carry = bytes.suffix(from: bytes.startIndex + cut)
            bytes = bytes.prefix(cut)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// How many leading bytes of `bytes` end on a character boundary.
    nonisolated static func completeUTF8Prefix(_ bytes: Data) -> Int {
        let array = [UInt8](bytes.suffix(4))
        let base = bytes.count - array.count
        // Walk back over continuation bytes to the lead byte of the last sequence.
        var i = array.count - 1
        while i >= 0, array[i] & 0xC0 == 0x80 { i -= 1 }
        guard i >= 0 else { return bytes.count }
        let lead = array[i]
        let need = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
        return array.count - i >= need ? bytes.count : base + i
    }

    private func append(_ piece: String, final: Bool) {
        switch route.link.kind {
        case .markdown:
            // CRLF is one `Character` in Swift, so a split on "\n" would never see it.
            text = (text + piece).replacingOccurrences(of: "\r\n", with: "\n")
            let split = PlanBlocks.split(Self.fencingFrontMatter(text)).blocks
            blocks = final ? split : Array(split.dropLast())
        case .text:
            var lines = (partialLine + piece).replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            partialLine = final ? "" : (lines.popLast() ?? "")
            if final, lines.last == "" { lines.removeLast() }
            appendLines(lines)
        case .image:
            break
        }
    }

    private func appendLines(_ lines: [String]) {
        var rest = lines[...]
        if let last = groups.last, lineCount % Self.linesPerGroup != 0 {
            let room = Self.linesPerGroup - lineCount % Self.linesPerGroup
            let take = rest.prefix(room)
            if !take.isEmpty { groups[groups.count - 1] = last + "\n" + take.joined(separator: "\n") }
            rest = rest.dropFirst(take.count)
            lineCount += take.count
        }
        while !rest.isEmpty {
            let take = rest.prefix(Self.linesPerGroup)
            groups.append(take.joined(separator: "\n"))
            rest = rest.dropFirst(take.count)
            lineCount += take.count
        }
    }

    /// YAML front matter (a skill's, a post's) as a fenced block. Left alone, its closing
    /// `---` turns the lines above it into one large setext heading.
    nonisolated static func fencingFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") else { return markdown }
        let body = markdown.dropFirst(4)
        guard let close = body.range(of: "\n---\n") ?? (body.hasSuffix("\n---") ? body.range(of: "\n---", options: .backwards) : nil)
        else { return markdown }
        return "```yaml\n" + body[..<close.lowerBound] + "\n```\n" + body[close.upperBound...]
    }

    /// The error a reader sees, in words about the file rather than about the socket.
    nonisolated static func message(for error: FleetRequestError, path: String) -> String {
        switch error {
        case .disconnected:
            return "Not connected to your Mac."
        case .server(let code):
            switch code {
            case "not_found": return "Couldn't find \(path) on your Mac."
            case "unknown_session": return "This session is no longer open on your Mac."
            case "not_an_image": return "This file isn't an image the Mac can read."
            case "unsupported", "unhandled": return "Update Flight Deck on your Mac to open files from the phone."
            default: return "Couldn't read this file."
            }
        }
    }
}
