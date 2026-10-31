import FleetKit
import SwiftUI

/// A file a transcript linked, read from the Mac: markdown drawn the way the plan reader draws
/// a plan, text in a face meant for reading, an image at the size of the screen.
///
/// **Markdown is the plan reader's rendering without its margin.** Same split, same segments,
/// same serif — a README two taps from the timeline should read like the plans the phone
/// already shows — but no notes column and no passage menu, because there is nothing behind
/// a file to send a note to.
struct FileViewerScreen: View {
    let route: FileRoute
    @State private var model: FileViewerModel
    @State private var scrolledToLine = false

    init(route: FileRoute, reader: any FileReading) {
        self.route = route
        self._model = State(initialValue: FileViewerModel(route: route, reader: reader))
    }

    var body: some View {
        content
            .navigationTitle(route.link.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .task { model.start() }
            .opensFileLinks(session: route.session, directory: model.resolvedPath.map { ($0 as NSString).deletingLastPathComponent })
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { model.start() }.font(.subheadline)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            switch route.link.kind {
            case .markdown: markdown
            case .text(let code): text(code: code)
            case .image: image
            }
        }
    }

    // MARK: Markdown

    private var markdown: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PlanReaderStyle.blockSpacing) {
                header
                ForEach(model.blocks, id: \.index) { block in
                    VStack(alignment: .leading, spacing: PlanReaderStyle.segmentSpacing) {
                        ForEach(Array(PlanReaderStyle.segments(of: block.text).enumerated()), id: \.offset) { _, segment in
                            PlanSegmentView(segment: segment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    // MARK: Text

    private func text(code: Bool) -> some View {
        let target = route.link.line.map { $0 - 1 }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header.padding(.bottom, 12)
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { index, group in
                        let first = index * FileViewerModel.linesPerGroup
                        Group {
                            if code {
                                codeLines(group, firstLine: first, highlight: target)
                            } else {
                                Text(FileTextStyle.attributed(group, firstLine: first, highlight: target))
                                    .font(.body)
                                    .lineSpacing(6)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(index)
                    }
                    footer
                }
                .padding(.horizontal, code ? 14 : 20)
                .padding(.vertical, 16)
            }
            // Once: a reader who scrolls on and buffers more must not be pulled back.
            .onChange(of: model.lineCount, initial: true) { _, count in
                guard !scrolledToLine, let target, target < count else { return }
                scrolledToLine = true
                // A turn later: in the same pass the lazy stack has not laid the rows out yet,
                // and a scroll to an id it has not placed silently stays at the top.
                DispatchQueue.main.async {
                    proxy.scrollTo(target / FileViewerModel.linesPerGroup, anchor: .top)
                }
            }
        }
    }

    /// A group of source lines, each beside its number in a gutter.
    ///
    /// **A row per line, not one `Text` per group with a gutter column beside it.** Lines wrap
    /// at phone width, and a number column drawn separately has no way to know that line 12
    /// took three rows: from the first long line on, every number would sit against the wrong
    /// code. A row per line keeps each number on its own line's first row, wrapped or not. The
    /// cost is that a selection stops at the end of a line.
    private func codeLines(_ group: String, firstLine: Int, highlight: Int?) -> some View {
        let lines = group.split(separator: "\n", omittingEmptySubsequences: false)
        let digits = FileTextStyle.gutterDigits(lineCount: model.lineCount)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                let number = firstLine + offset
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: String(number + 1))
                        .foregroundStyle(.tertiary)
                        .frame(width: FileTextStyle.gutterWidth(digits: digits), alignment: .trailing)
                        .accessibilityHidden(true)
                    Text(verbatim: String(line))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.footnote, design: .monospaced))
                .padding(.vertical, 1)
                .background(number == highlight ? Color.yellow.opacity(0.3) : .clear)
            }
        }
    }

    // MARK: Image

    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    private var image: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                if let image = model.image {
                    let scale = max(1, min(8, zoom * pinch))
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width * scale)
                        .frame(minHeight: geometry.size.height)
                        .gesture(MagnifyGesture()
                            .updating($pinch) { value, state, _ in state = value.magnification }
                            .onEnded { value in zoom = max(1, min(8, zoom * value.magnification)) })
                        .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2.5 } }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let image = model.image {
                Text(FileTextStyle.imageCaption(shown: image, original: model.downsampledFrom))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(8).frame(maxWidth: .infinity)
                    .background(.bar)
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        Text(FileTextStyle.subtitle(path: model.resolvedPath ?? route.link.path, size: model.size))
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    /// The end of what has arrived. Appearing asks for the next chunk, so reading on is all it
    /// takes to buffer on.
    @ViewBuilder private var footer: some View {
        if model.isTruncated {
            Text(FileTextStyle.truncatedNote(shown: model.loaded, of: model.size))
                .font(.footnote).foregroundStyle(.secondary).padding(.top, 12)
        } else if model.moreFailed {
            Button("Couldn't load the rest. Retry") { model.loadMore() }.font(.footnote).padding(.top, 12)
        } else if model.loaded < model.size {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 20)
                .onAppear { model.loadMore() }
        }
    }
}

/// What the file viewer says and how its text is marked, decided apart from SwiftUI.
enum FileTextStyle {
    static func subtitle(path: String, size: Int64) -> String {
        size > 0 ? "\(path) · \(bytes(size))" : path
    }

    static func truncatedNote(shown: Int64, of size: Int64) -> String {
        "Showing the first \(bytes(shown)) of \(bytes(size)). Open it on your Mac for the rest."
    }

    static func imageCaption(shown image: UIImage, original: (width: Int, height: Int)?) -> String {
        let w = Int(image.size.width * image.scale), h = Int(image.size.height * image.scale)
        guard let original else { return "\(w) × \(h)" }
        return "\(original.width) × \(original.height), shown at \(w) × \(h)"
    }

    /// How many digits the gutter holds: the longest number shown, never fewer than three, so
    /// the column does not widen at line 10 and again at 100 as a file buffers in.
    static func gutterDigits(lineCount: Int) -> Int {
        max(3, String(max(1, lineCount)).count)
    }

    /// The gutter's width for `digits` numerals in the footnote monospace.
    static func gutterWidth(digits: Int) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        return ceil(("0" as NSString).size(withAttributes: [.font: font]).width * CGFloat(digits))
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// A group of lines, with line `highlight` (0-based, file-wide) washed when it falls here.
    static func attributed(_ group: String, firstLine: Int, highlight: Int?) -> AttributedString {
        var out = AttributedString(group)
        guard let highlight, highlight >= firstLine, highlight < firstLine + FileViewerModel.linesPerGroup else { return out }
        let lines = group.split(separator: "\n", omittingEmptySubsequences: false)
        let index = highlight - firstLine
        guard index < lines.count else { return out }
        let start = lines[..<index].reduce(0) { $0 + $1.count + 1 }
        let lower = out.index(out.startIndex, offsetByCharacters: start)
        let upper = out.index(lower, offsetByCharacters: lines[index].count)
        out[lower..<upper].backgroundColor = .yellow.opacity(0.3)
        return out
    }
}
