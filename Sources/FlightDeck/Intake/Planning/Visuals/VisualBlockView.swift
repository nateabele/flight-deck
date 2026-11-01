import AppKit
import IntakeKit

/// One `fd-visual` block in the plan (spec §8, option B of the approved render): a header, the
/// body with the selected representation, and a filmstrip of every representation underneath.
///
/// - **Header:** the title, a chip with the shown representation's kind (★ when it is the
///   primary), the manifest's **states** and **sizes** as segmented controls, Compare, and Ask
///   when the block has somewhere to send it.
/// - **Body:** the live web view while the block holds one (`VisualLivePool`), otherwise the
///   snapshot: the revision's stored `snapshot@<state>-<size>.png` if its manifest lists one, or a
///   picture `VisualRenderHost` drew in memory.
/// - **Filmstrip:** a thumbnail per representation, ★ on the primary, an amber outline and the
///   reason on an alternate a round proposed, and "＋ Another view…".
/// - **Compare** splits the body two-up, the primary on the left and another on the right with
///   "Make primary", and collapses back on Done. Both panes are pictures: a compare never takes a
///   second live web view.
///
/// The height is fixed by the model (`VisualBlockLayout`), never by what is drawn, because the
/// text below the block is laid out to it. Laid over the block's hidden source by
/// `VisualBlockOverlay` (V-R1).
@MainActor
final class VisualBlockView: NSView {
    private(set) var model: VisualBlockModel
    private(set) var caption: String
    var store: (any VisualStoreReading)?
    /// Make the representation with this revision the primary. Nil disables the button: the
    /// block state's only writer is ThreadRunner (spec §3), which P2a does not reach from here.
    var onMakePrimary: ((Int) -> Void)? { didSet { rebuildBody() } }
    /// Open the block's thread with a `makeVisual` request filled in. Nil disables the tile.
    var onAnotherView: (() -> Void)? { didSet { rebuildFilmstrip() } }
    /// Ask about this visual in its thread. Nil hides the button.
    var onAsk: (() -> Void)? { didSet { rebuildHeader() } }

    /// The representation in the body (and on the right in Compare).
    private(set) var selected: Int
    private(set) var state: String?
    private(set) var size: String?
    private(set) var comparing = false
    private(set) var isLive = false
    /// What the block's body shows, in words: VoiceOver reads it as the block's value, and a UI
    /// test reads it to know the diagram was drawn ("live, drawn"), not just laid out.
    private(set) var drawState = "picture" { didSet { setAccessibilityValue(drawState) } }
    /// What the live page last said: drawn, or Mermaid's error.
    private(set) var liveStatus: VisualRenderStatus?

    private let header = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let chip = NSTextField(labelWithString: "")
    private let compareLabel = NSTextField(labelWithString: "")
    private var statesControl: NSSegmentedControl?
    private var sizesControl: NSSegmentedControl?
    private let compareButton = NSButton(title: "Compare", target: nil, action: nil)
    private var askButton: NSButton?
    private let body = NSView()
    private let mainPane = VisualPane()
    private let otherPane = VisualPane()
    private let filmstrip = NSView()
    private var tiles: [VisualTile] = []
    private let addTile = VisualTile()
    private let placeholder = FlippedBox()
    private var web: VisualWebView?
    /// Web views that left live mode and are waiting for their picture to be taken.
    private var retiring: [VisualWebView] = []

    override var isFlipped: Bool { true }

    init(model: VisualBlockModel, caption: String, store: (any VisualStoreReading)?) {
        self.model = model
        self.caption = caption
        self.store = store
        selected = model.primaryIndex
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: VisualBlockLayout.height(for: model)))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("visual-block-\(model.id)")
        [header, body, filmstrip, placeholder].forEach(addSubview)
        header.wantsLayer = true
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        chip.font = .systemFont(ofSize: 12)
        chip.alignment = .center
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 10
        chip.layer?.borderWidth = 1
        compareLabel.font = .systemFont(ofSize: 12)
        compareLabel.textColor = .secondaryLabelColor
        compareButton.bezelStyle = .rounded
        compareButton.controlSize = .small
        compareButton.target = self
        compareButton.action = #selector(toggleCompare)
        compareButton.setAccessibilityIdentifier("visual-compare")
        [titleField, chip, compareLabel, compareButton].forEach(header.addSubview)
        body.addSubview(mainPane)
        body.addSubview(otherPane)
        otherPane.onMakePrimary = { [weak self] in self?.makePrimary() }
        addTile.isAdd = true
        addTile.onClick = { [weak self] in self?.onAnotherView?() }
        filmstrip.wantsLayer = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A new model or caption (the plan was edited, or a round landed). The selection survives
    /// when the representation it named is still there.
    func update(model: VisualBlockModel, caption: String) {
        guard model != self.model || caption != self.caption else { return }
        let shown = self.model.representations.indices.contains(selected) ? self.model.representations[selected].revision.r : nil
        self.model = model
        self.caption = caption
        selected = shown.flatMap { r in model.representations.firstIndex { $0.revision.r == r } } ?? model.primaryIndex
        if model.representations.count < 2 { comparing = false }
        if isLive { goSnapshot() }
        apply()
    }

    // MARK: - Building

    private func apply() {
        let ready = !model.representations.isEmpty
        header.isHidden = !ready
        body.isHidden = !ready
        filmstrip.isHidden = model.representations.count < 2
        placeholder.isHidden = ready
        if ready { rebuildHeader(); rebuildBody(); rebuildFilmstrip() } else { rebuildPlaceholder() }
        setAccessibilityLabel(accessibilitySummary)
        needsLayout = true
        updateColors()
    }

    private var accessibilitySummary: String {
        switch model.content {
        case .missing: "Missing visual \(model.id)"
        case .pending: "Visual \(model.id) requested, not made yet"
        case .ready(let reps): "Visual: \(model.title ?? caption), \(reps[selected].label)"
        }
    }

    private var shown: VisualBlockModel.Representation? {
        model.representations.indices.contains(selected) ? model.representations[selected] : nil
    }

    private func rebuildHeader() {
        guard let rep = shown else { return }
        titleField.stringValue = model.title ?? (caption.isEmpty ? model.id : caption)
        chip.stringValue = comparing ? "" : (rep.isPrimary ? "★ " : "") + rep.label
        chip.isHidden = comparing
        compareLabel.stringValue = comparing ? "Comparing 2 of \(model.representations.count)" : ""
        compareLabel.isHidden = !comparing
        compareButton.title = comparing ? "Done" : "Compare"
        compareButton.isHidden = model.representations.count < 2
        statesControl?.removeFromSuperview()
        sizesControl?.removeFromSuperview()
        statesControl = segmented(rep.revision.manifest.states, current: state, action: #selector(stateChosen(_:)), id: "visual-states")
        sizesControl = segmented(rep.revision.manifest.sizes, current: size, action: #selector(sizeChosen(_:)), id: "visual-sizes")
        askButton?.removeFromSuperview()
        askButton = nil
        if onAsk != nil {
            let ask = NSButton(title: "✦ Ask", target: self, action: #selector(askTapped))
            ask.bezelStyle = .rounded
            ask.controlSize = .small
            header.addSubview(ask)
            askButton = ask
        }
        needsLayout = true
    }

    private func segmented(_ names: [String], current: String?, action: Selector, id: String) -> NSSegmentedControl? {
        guard names.count > 1, !comparing else { return nil }
        let control = NSSegmentedControl(labels: names, trackingMode: .selectOne, target: self, action: action)
        control.controlSize = .small
        control.selectedSegment = current.flatMap { names.firstIndex(of: $0) } ?? 0
        control.setAccessibilityIdentifier(id)
        header.addSubview(control)
        return control
    }

    private func rebuildBody() {
        guard let rep = shown else { return }
        let primary = model.representations[model.primaryIndex]
        if comparing {
            let other = selected == model.primaryIndex ? model.representations[(model.primaryIndex + 1) % model.representations.count] : rep
            mainPane.configure(title: "★ " + primary.label, makePrimary: nil)
            otherPane.configure(title: other.label, makePrimary: onMakePrimary == nil ? false : true)
            otherPane.isHidden = false
            picture(primary, into: mainPane)
            picture(other, into: otherPane)
        } else {
            mainPane.configure(title: nil, makePrimary: nil)
            otherPane.isHidden = true
            picture(rep, into: mainPane)
        }
        needsLayout = true
    }

    private func rebuildFilmstrip() {
        tiles.forEach { $0.removeFromSuperview() }
        tiles = []
        addTile.removeFromSuperview()
        guard model.representations.count > 1 else { return }
        for (i, rep) in model.representations.enumerated() {
            let tile = VisualTile()
            tile.label = rep.isPrimary ? "\(rep.label) ★" : rep.label
            tile.reason = rep.proposedByRound ? rep.reason : nil
            tile.proposed = rep.proposedByRound
            tile.isSelected = comparing ? i == otherIndex : i == selected
            tile.onClick = { [weak self] in self?.choose(i) }
            tile.setAccessibilityIdentifier("visual-tile-\(i)")
            filmstrip.addSubview(tile)
            tiles.append(tile)
            picture(rep, thumbnail: tile)
        }
        addTile.label = "＋ Another view…"
        addTile.isEnabled = onAnotherView != nil
        filmstrip.addSubview(addTile)
        needsLayout = true
    }

    private var otherIndex: Int {
        selected == model.primaryIndex ? (model.primaryIndex + 1) % model.representations.count : selected
    }

    private func rebuildPlaceholder() {
        placeholder.subviews.forEach { $0.removeFromSuperview() }
        let missing = model.content == .missing
        let line1 = NSTextField(labelWithString: missing ? "Missing visual · \(model.id)" : "Visual requested · \(model.id)")
        line1.font = .systemFont(ofSize: 13, weight: .medium)
        line1.textColor = .secondaryLabelColor
        let line2 = NSTextField(labelWithString: caption.isEmpty
                                ? (missing ? "No revision of it is on disk." : "It shows here once it is made.")
                                : caption)
        line2.font = .systemFont(ofSize: 12)
        line2.textColor = .tertiaryLabelColor
        line2.lineBreakMode = .byTruncatingTail
        [line1, line2].forEach(placeholder.addSubview)
        placeholder.setAccessibilityIdentifier("visual-placeholder")
        needsLayout = true
    }

    // MARK: - Pictures

    /// The key a revision's picture is stored and cached under, in this block's state and size.
    private func snapshotKey(_ rep: VisualBlockModel.Representation) -> VisualSnapshotKey {
        let m = rep.revision.manifest
        let s = state.flatMap { m.states.contains($0) ? $0 : nil } ?? m.states.first ?? "default"
        let z = size.flatMap { m.sizes.contains($0) ? $0 : nil } ?? m.sizes.first ?? "default"
        return VisualSnapshotKey(state: s, size: z)
    }

    /// Pictures are drawn only once the overlay says the block is near the screen.
    private(set) var wantsPictures = false
    func setWantsPictures(_ wants: Bool) {
        guard wants != wantsPictures else { return }
        wantsPictures = wants
        if wants { rebuildBody(); rebuildFilmstrip() }
    }

    private func picture(_ rep: VisualBlockModel.Representation, into pane: VisualPane) {
        pane.image = (pane === mainPane && !comparing && !hasStored(rep) ? fitted(rep) : nil) ?? storedOrCached(rep)
        if pane.image == nil { pane.message = wantsPictures ? "Drawing…" : nil }
        fetch(rep) { [weak pane] image in pane?.image = image; if image == nil { pane?.message = "No picture of this visual yet." } }
    }

    private func picture(_ rep: VisualBlockModel.Representation, thumbnail tile: VisualTile) {
        tile.image = storedOrCached(rep)
        fetch(rep) { [weak tile] image in tile?.image = image }
    }

    private func cacheKey(_ rep: VisualBlockModel.Representation, _ store: any VisualStoreReading, fit: Bool = false) -> VisualSnapshotCache.Key {
        VisualSnapshotCache.Key(store: VisualStoreIdentity.of(store), id: rep.revision.id, r: rep.revision.r, snapshot: snapshotKey(rep), fit: fit)
    }

    /// Whether the revision's manifest lists a stored snapshot for this state and size, which is
    /// then the picture; a live capture only stands in where there is none.
    private func hasStored(_ rep: VisualBlockModel.Representation) -> Bool {
        let name = snapshotKey(rep).fileName
        return rep.revision.manifest.files.contains { $0.path == name }
    }

    /// What the live view last drew, fitted to the body (`goSnapshot`), if it is still held.
    private func fitted(_ rep: VisualBlockModel.Representation) -> NSImage? {
        guard let store else { return nil }
        return VisualSnapshotCache.shared.image(cacheKey(rep, store, fit: true))
    }

    /// The revision's picture: one already decoded or drawn, else its stored snapshot, read through
    /// the store like every other file of the revision. A stored file is decoded once and kept in the
    /// shared cache under its key (V1 review, M6): a block asks for each picture on every redraw
    /// (a scroll tick, a selection, a variant change), on the main thread.
    private func storedOrCached(_ rep: VisualBlockModel.Representation) -> NSImage? {
        guard let store else { return nil }
        let key = cacheKey(rep, store)
        if let image = VisualSnapshotCache.shared.image(key) { return image }
        let name = snapshotKey(rep).fileName
        if rep.revision.manifest.files.contains(where: { $0.path == name }),
           let slice = store.read(rep.revision.id, r: rep.revision.r, name: name, offset: 0, limit: VisualStoreLimits.maxFileBytes),
           let image = NSImage(data: slice.data) {
            VisualSnapshotCache.shared.put(image, for: key)
            return image
        }
        return nil
    }

    private func fetch(_ rep: VisualBlockModel.Representation, done: @escaping (NSImage?) -> Void) {
        guard wantsPictures, let store, storedOrCached(rep) == nil else { return }
        VisualSnapshotCache.shared.fetch(cacheKey(rep, store), store: store, done: done)
    }

    // MARK: - Live

    /// Puts the shown representation in a live web view (`VisualLivePool` decided this block
    /// may have one). Not while comparing: both panes are pictures then.
    func goLive() {
        guard !isLive, !comparing, let rep = shown, let store else { return }
        let web = VisualWebView(store: store, frame: mainPane.contentFrame, fit: true)
        web.onStatus = { [weak self] status in self?.liveStatusChanged(status) }
        mainPane.attach(web.view)
        web.show(rep.revision.id, r: rep.revision.r, state: snapshotKey(rep).state, size: snapshotKey(rep).size)
        self.web = web
        isLive = true
        liveStatus = .loading
        drawState = "live, loading"
    }

    /// Back to the picture. What the live view drew is kept as the picture when there is none
    /// yet, so the block does not go blank as it scrolls away.
    ///
    /// **The web view stays until its picture is taken** (V1 review, M1). `takeSnapshot` is
    /// asynchronous and a view detached in the same turn can hand back a blank image, which then sat
    /// in the cache as the block's picture. The picture is filed under the fitted key: the live view
    /// is scaled to the body, so it is not the full-size render the plain key stands for.
    func goSnapshot() {
        guard isLive, let web else { return }
        isLive = false
        drawState = "picture"
        self.web = nil
        VisualLivePool.shared.release(self)
        var key: VisualSnapshotCache.Key?
        if let rep = shown, let store, case .rendered = liveStatus, !hasStored(rep), fitted(rep) == nil { key = cacheKey(rep, store, fit: true) }
        guard let key else {
            retire(web)
            rebuildBody()
            return
        }
        retiring.append(web)
        snapshotter(web) { [weak self] image in
            // A blank or empty capture (a view that had left its window) is not the block's picture.
            if let image, !Self.isBlank(image) { VisualSnapshotCache.shared.put(image, for: key) }
            guard let self else { return }
            self.retire(web)
            self.rebuildBody()
        }
        // A web view that never answers (the block left its window) must not be kept for ever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.retire(web)
        }
        rebuildBody()
    }

    /// Takes the live view's picture; replaceable so a test can hand back a blank one.
    var snapshotter: (VisualWebView, @escaping (NSImage?) -> Void) -> Void = { web, done in
        web.view.takeSnapshot(with: nil) { image, _ in MainActor.assumeIsolated { done(image) } }
    }

    /// True for a picture with nothing in it: no size, or one colour throughout (sampled on a grid).
    static func isBlank(_ image: NSImage) -> Bool {
        guard image.size.width >= 1, image.size.height >= 1,
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        var first: NSColor?
        let stepX = max(1, rep.pixelsWide / 24), stepY = max(1, rep.pixelsHigh / 24)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                guard let f = first else { first = c; continue }
                if abs(c.redComponent - f.redComponent) + abs(c.greenComponent - f.greenComponent) + abs(c.blueComponent - f.blueComponent) > 0.02 { return false }
            }
        }
        return true
    }

    /// The picture in the body pane (tests).
    var bodyImage: NSImage? { mainPane.image }

    private func retire(_ web: VisualWebView) {
        retiring.removeAll { $0 === web }
        mainPane.detachWeb(web.view)
        web.stop()
    }

    /// Whether a web view is still attached, live or waiting for its picture to be taken (tests).
    var holdsWebView: Bool { web != nil || !retiring.isEmpty }

    private func liveStatusChanged(_ status: VisualRenderStatus) {
        liveStatus = status
        switch status {
        case .loading: drawState = "live, loading"
        case .rendered: drawState = "live, drawn"
        case .failed(let message, _): drawState = "live, failed: \(message)"
        }
        if case .failed(let message, _) = status {
            body.setAccessibilityLabel("Mermaid could not draw this diagram: \(message)")
        }
    }

    // MARK: - Actions

    private func choose(_ index: Int) {
        guard model.representations.indices.contains(index) else { return }
        if comparing {
            guard index != model.primaryIndex else { return }
            selected = index
        } else {
            guard index != selected else { return }
            selected = index
            if isLive { goSnapshot() }
        }
        rebuildHeader(); rebuildBody(); rebuildFilmstrip()
        onNeedsLive?(self)
    }

    /// The overlay offers the block a live web view again after something the block did dropped
    /// it (another representation chosen, Compare closed).
    var onNeedsLive: ((VisualBlockView) -> Void)?

    @objc private func toggleCompare() {
        setComparing(!comparing)
    }

    func setComparing(_ on: Bool) {
        guard on != comparing, model.representations.count > 1 else { return }
        if on, isLive { goSnapshot() }
        comparing = on
        if !on, selected != model.primaryIndex, !model.representations.indices.contains(selected) { selected = model.primaryIndex }
        rebuildHeader(); rebuildBody(); rebuildFilmstrip()
        if !on { onNeedsLive?(self) }
    }

    /// Selects representation `index` (the filmstrip's click), for tests and renders.
    func select(_ index: Int) { choose(index) }

    private func makePrimary() {
        guard comparing else { return }
        onMakePrimary?(model.representations[otherIndex].revision.r)
    }

    @objc private func stateChosen(_ sender: NSSegmentedControl) {
        guard let rep = shown, rep.revision.manifest.states.indices.contains(sender.selectedSegment) else { return }
        state = rep.revision.manifest.states[sender.selectedSegment]
        refreshAfterVariantChange()
    }

    @objc private func sizeChosen(_ sender: NSSegmentedControl) {
        guard let rep = shown, rep.revision.manifest.sizes.indices.contains(sender.selectedSegment) else { return }
        size = rep.revision.manifest.sizes[sender.selectedSegment]
        refreshAfterVariantChange()
    }

    private func refreshAfterVariantChange() {
        if isLive, let rep = shown {
            liveStatus = .loading
            drawState = "live, loading"
            web?.show(rep.revision.id, r: rep.revision.r, state: snapshotKey(rep).state, size: snapshotKey(rep).size)
        } else {
            rebuildBody()
        }
        rebuildFilmstrip()
    }

    @objc private func askTapped() { onAsk?() }

    // MARK: - Layout and colour

    override func layout() {
        super.layout()
        let w = bounds.width
        if !placeholder.isHidden {
            placeholder.frame = bounds
            let labels = placeholder.subviews
            if labels.count == 2 {
                labels[0].frame = NSRect(x: 16, y: bounds.midY - 20, width: w - 32, height: 18)
                labels[1].frame = NSRect(x: 16, y: bounds.midY + 2, width: w - 32, height: 16)
            }
            return
        }
        let h = VisualBlockLayout.header
        header.frame = NSRect(x: 0, y: 0, width: w, height: h)
        var right = w - 12
        func placeRight(_ view: NSView?) {
            guard let view, !view.isHidden else { return }
            let size = view.fittingSize
            right -= size.width
            view.frame = NSRect(x: right, y: (h - size.height) / 2, width: size.width, height: size.height)
            right -= 8
        }
        placeRight(askButton)
        placeRight(compareButton)
        placeRight(sizesControl)
        placeRight(statesControl)
        var left: CGFloat = 14
        let title = titleField.fittingSize
        let titleWidth = min(title.width, max(60, right - left - 120))
        titleField.frame = NSRect(x: left, y: (h - title.height) / 2, width: titleWidth, height: title.height)
        left += titleWidth + 10
        if !chip.isHidden {
            let c = chip.fittingSize
            chip.frame = NSRect(x: left, y: (h - c.height - 4) / 2, width: c.width + 18, height: c.height + 4)
        }
        if !compareLabel.isHidden {
            let c = compareLabel.fittingSize
            compareLabel.frame = NSRect(x: left, y: (h - c.height) / 2, width: c.width, height: c.height)
        }
        // Inset a point at the sides, so the block's border still shows beside the white paper.
        body.frame = NSRect(x: 1, y: h, width: w - 2, height: VisualBlockLayout.body - (filmstrip.isHidden ? 1 : 0))
        let bw = body.frame.width
        if comparing {
            let half = (bw - 14 * 3) / 2
            mainPane.frame = NSRect(x: 13, y: 12, width: half, height: VisualBlockLayout.body - 24)
            otherPane.frame = NSRect(x: 27 + half, y: 12, width: half, height: VisualBlockLayout.body - 24)
        } else {
            mainPane.frame = body.bounds
        }
        filmstrip.frame = NSRect(x: 0, y: h + VisualBlockLayout.body, width: w, height: filmstrip.isHidden ? 0 : VisualBlockLayout.filmstrip)
        let count = CGFloat(tiles.count + 1)
        let gap: CGFloat = 12
        let tileWidth = min(180, (w - 28 - gap * (count - 1)) / count)
        for (i, tile) in (tiles + [addTile]).enumerated() {
            tile.frame = NSRect(x: 14 + CGFloat(i) * (tileWidth + gap), y: 12, width: tileWidth, height: VisualBlockLayout.filmstrip - 24)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ready = !model.representations.isEmpty
            layer?.borderColor = PlanTheme.wash(dark: 0.18, light: 0.16).cgColor
            layer?.backgroundColor = ready ? PlanTheme.wash(dark: 0.03, light: 0.02).cgColor : NSColor.clear.cgColor
            layer?.borderWidth = ready ? 1 : 1.5
            if !ready {
                // Dashed, so a missing visual reads as a hole in the plan and not as a broken card.
                layer?.borderWidth = 0
                placeholder.wantsLayer = true
                let dash = placeholder.layer?.sublayers?.first as? CAShapeLayer ?? CAShapeLayer()
                if dash.superlayer == nil { placeholder.layer?.addSublayer(dash) }
                dash.frame = bounds
                dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 10, cornerHeight: 10, transform: nil)
                dash.fillColor = NSColor.clear.cgColor
                dash.strokeColor = PlanTheme.wash(dark: 0.25, light: 0.22).cgColor
                dash.lineDashPattern = [5, 4]
                dash.lineWidth = 1.5
            }
            header.layer?.backgroundColor = PlanTheme.wash(dark: 0.05, light: 0.04).cgColor
            filmstrip.layer?.backgroundColor = PlanTheme.wash(dark: 0.05, light: 0.04).cgColor
            chip.layer?.borderColor = PlanTheme.wash(dark: 0.3, light: 0.3).cgColor
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if model.representations.isEmpty { updateColors() }
    }

    // Lines between the header, body and filmstrip.
    override func draw(_ dirtyRect: NSRect) {
        guard !model.representations.isEmpty else { return }
        PlanTheme.wash(dark: 0.14, light: 0.12).setFill()
        NSRect(x: 0, y: VisualBlockLayout.header - 1, width: bounds.width, height: 1).fill()
        if !filmstrip.isHidden { NSRect(x: 0, y: VisualBlockLayout.header + VisualBlockLayout.body, width: bounds.width, height: 1).fill() }
    }

    // MARK: - For tests

    /// Every picture the block shows is in: the body's (both panes in Compare) and each thumbnail's.
    var picturesReady: Bool {
        guard !model.representations.isEmpty else { return true }
        return mainPane.image != nil && (otherPane.isHidden || otherPane.image != nil) && tiles.allSatisfy { $0.image != nil }
    }

    var testSnapshot: (comparing: Bool, selected: Int, tiles: [String], chip: String, compareTitle: String, placeholder: String?) {
        (comparing, selected, tiles.map(\.label), chip.stringValue, compareButton.title,
         placeholder.isHidden ? nil : (placeholder.subviews.first as? NSTextField)?.stringValue)
    }
}

/// The body's one picture, or its live web view, on white paper (the page's own colour, so
/// switching between the two does not flash). In Compare it has a small header of its own.
@MainActor
final class VisualPane: NSView {
    var image: NSImage? { didSet { imageView.image = image; messageField.isHidden = image != nil || webView != nil } }
    var message: String? { didSet { messageField.stringValue = message ?? ""; messageField.isHidden = image != nil || message == nil } }
    var onMakePrimary: (() -> Void)?
    private let imageView = NSImageView()
    private let messageField = NSTextField(labelWithString: "")
    private let titleField = NSTextField(labelWithString: "")
    private let makePrimaryButton = NSButton(title: "Make primary", target: nil, action: nil)
    private var webView: NSView?
    private var titled = false

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 0
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignTop
        messageField.font = .systemFont(ofSize: 12)
        messageField.textColor = NSColor.black.withAlphaComponent(0.45)
        messageField.alignment = .center
        messageField.isHidden = true
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = NSColor.black.withAlphaComponent(0.8)
        makePrimaryButton.bezelStyle = .rounded
        makePrimaryButton.controlSize = .small
        makePrimaryButton.target = self
        makePrimaryButton.action = #selector(makePrimaryTapped)
        makePrimaryButton.setAccessibilityIdentifier("visual-make-primary")
        makePrimaryButton.appearance = NSAppearance(named: .aqua)
        [imageView, messageField, titleField, makePrimaryButton].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `title` nil is the plain body; `makePrimary` nil hides the button, false shows it disabled.
    func configure(title: String?, makePrimary: Bool?) {
        titled = title != nil
        titleField.stringValue = title ?? ""
        titleField.isHidden = title == nil
        makePrimaryButton.isHidden = makePrimary == nil
        makePrimaryButton.isEnabled = makePrimary == true
        layer?.cornerRadius = titled ? 8 : 0
        layer?.borderWidth = titled ? 1 : 0
        layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor
        needsLayout = true
    }

    var contentFrame: NSRect {
        let top: CGFloat = titled ? 30 : 0
        return NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top))
    }

    func attach(_ view: NSView) {
        webView?.removeFromSuperview()
        webView = view
        view.frame = contentFrame
        addSubview(view)
        messageField.isHidden = true
    }

    /// Takes `view` out (nil: whichever is there). A view that was replaced by a newer one is
    /// not this pane's any more, and is left to whoever holds it.
    func detachWeb(_ view: NSView? = nil) {
        if let view, view !== webView { view.removeFromSuperview(); return }
        webView?.removeFromSuperview()
        webView = nil
    }

    @objc private func makePrimaryTapped() { onMakePrimary?() }

    override func layout() {
        super.layout()
        if titled {
            titleField.frame = NSRect(x: 10, y: 7, width: bounds.width - 140, height: 16)
            let b = makePrimaryButton.fittingSize
            makePrimaryButton.frame = NSRect(x: bounds.width - b.width - 8, y: (30 - b.height) / 2, width: b.width, height: b.height)
        }
        let content = contentFrame
        imageView.frame = content.insetBy(dx: 4, dy: 4)
        messageField.frame = NSRect(x: 8, y: content.midY - 8, width: bounds.width - 16, height: 16)
        webView?.frame = content
    }

    override func draw(_ dirtyRect: NSRect) {
        guard titled else { return }
        NSColor.black.withAlphaComponent(0.04).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 30).fill()
        NSColor.black.withAlphaComponent(0.12).setFill()
        NSRect(x: 0, y: 29, width: bounds.width, height: 1).fill()
    }
}

/// A filmstrip thumbnail: the picture, its label, and for an alternate a round proposed, an amber
/// outline and the round's reason.
@MainActor
final class VisualTile: NSView {
    var image: NSImage? { didSet { imageView.image = image } }
    var label = "" { didSet { labelField.stringValue = label; setAccessibilityLabel(label) } }
    var reason: String? { didSet { reasonField.stringValue = reason ?? ""; reasonField.isHidden = reason == nil; toolTip = reason } }
    var proposed = false { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    var isAdd = false { didSet { imageView.isHidden = isAdd; needsDisplay = true } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5 } }
    var onClick: (() -> Void)?
    private let imageView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let reasonField = NSTextField(labelWithString: "")

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.wantsLayer = true
        imageView.layer?.backgroundColor = NSColor.white.cgColor
        imageView.layer?.cornerRadius = 4
        labelField.font = .systemFont(ofSize: 12)
        labelField.alignment = .center
        labelField.lineBreakMode = .byTruncatingTail
        reasonField.font = .systemFont(ofSize: 10)
        reasonField.textColor = .systemOrange
        reasonField.alignment = .center
        reasonField.lineBreakMode = .byTruncatingTail
        reasonField.isHidden = true
        [imageView, labelField, reasonField].forEach(addSubview)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }
    override func accessibilityPerformPress() -> Bool { if isEnabled { onClick?() }; return isEnabled }

    override func layout() {
        super.layout()
        let labelHeight: CGFloat = 16
        let reasonHeight: CGFloat = reasonField.isHidden ? 0 : 13
        if isAdd {
            labelField.frame = NSRect(x: 4, y: (bounds.height - labelHeight) / 2, width: bounds.width - 8, height: labelHeight)
            return
        }
        imageView.frame = NSRect(x: 6, y: 6, width: bounds.width - 12, height: bounds.height - 12 - labelHeight - reasonHeight)
        labelField.frame = NSRect(x: 4, y: bounds.height - 4 - labelHeight - reasonHeight, width: bounds.width - 8, height: labelHeight)
        reasonField.frame = NSRect(x: 4, y: bounds.height - 4 - reasonHeight, width: bounds.width - 8, height: reasonHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: isSelected || proposed ? 1 : 0.5, dy: isSelected || proposed ? 1 : 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if isAdd { path.setLineDash([4, 3], count: 2, phase: 0) }
        path.lineWidth = isSelected || proposed ? 2 : 1
        (isSelected ? NSColor.controlAccentColor : proposed ? NSColor.systemOrange : PlanTheme.wash(dark: 0.25, light: 0.22)).setStroke()
        path.stroke()
    }
}

/// A plain container laid out top-down, like the block itself.
final class FlippedBox: NSView {
    override var isFlipped: Bool { true }
}
