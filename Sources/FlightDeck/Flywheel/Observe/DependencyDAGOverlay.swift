import SwiftUI

/// Pure click→node resolution for the DAG overlay: maps a view-space point back to graph
/// space via the camera's exact inverse, then finds the node whose centered `nodeSize` box
/// (in graph space) contains it. Kept pure and unit-tested here so `DependencyDAGOverlay`'s
/// body carries no untested geometry — per AGENTS.md rule 2, agents can't drive the real GUI,
/// so any hit-testing logic left in the view body would be unverifiable by an agent.
struct DAGHitTester {
    static func node(at viewPoint: CGPoint, layout: DependencyGraphLayout, camera: DAGCamera,
                      viewport: CGSize, nodeSize: CGSize) -> String? {
        let graphPoint = camera.graphPoint(fromViewPoint: viewPoint, viewport: viewport)
        let halfWidth = nodeSize.width / 2
        let halfHeight = nodeSize.height / 2

        // Lexicographic id order makes the tie-break deterministic if two boxes ever overlap
        // (real layouts don't — DependencyGraphLayout spaces every rank/column apart — but a
        // pure function shouldn't depend on Dictionary's undefined iteration order regardless).
        for id in layout.nodes.keys.sorted() {
            guard let candidate = layout.nodes[id] else { continue }
            let box = CGRect(x: candidate.position.x - halfWidth, y: candidate.position.y - halfHeight,
                              width: nodeSize.width, height: nodeSize.height)
            if box.contains(graphPoint) { return id }
        }
        return nil
    }
}

/// Whole-project dependency DAG, rendered as a `Canvas` with a pannable/zoomable camera
/// centered on the selected bead. Every drawn position — node cards AND edge endpoints —
/// is produced by mapping `DependencyGraphLayout.Node.position` through the ONE
/// `camera.transform(viewport:)`, so cards and arrows share a coordinate space and cannot
/// desync (the failure the HTML mockups hit). All non-trivial geometry (rank layout, camera
/// math, hit-testing) lives in the three composed, separately-tested pure types; this body is
/// GUI-verified by hand (AGENTS.md rule 2: agents can't drive the real GUI here).
struct DependencyDAGOverlay: View {
    let projection: FlywheelProjection
    let selectedBeadID: String?
    let onSelectNode: (String) -> Void
    let onJumpToTab: (String) -> Void
    let onClose: () -> Void

    /// Fixed card geometry shared by layout, drawing, and hit-testing — a single constant
    /// rather than three call sites risking drift is what keeps the box `DAGHitTester` tests
    /// against the box actually drawn.
    private static let nodeSize = CGSize(width: 132, height: 48)
    private static let spacing = CGSize(width: 40, height: 80)
    private static let minimapSize = CGSize(width: 160, height: 100)

    @State private var camera = DAGCamera(scale: 1, center: .zero)
    @State private var hasCenteredInitialCamera = false
    @GestureState private var panTranslation: CGSize = .zero
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        let layout = buildLayout()

        GeometryReader { proxy in
            let viewport = proxy.size
            let liveCamera = displayCamera(base: camera, viewport: viewport)

            ZStack(alignment: .topTrailing) {
                // The Canvas and its gestures live on one background layer so the close
                // button and minimap (drawn on top, below) keep normal tap priority instead
                // of racing the pan/tap gestures attached here.
                Canvas { context, size in
                    draw(layout: layout, camera: liveCamera, in: &context, size: size)
                }
                .contentShape(Rectangle())
                .gesture(panGesture)
                .gesture(magnifyGesture)
                .onTapGesture { location in
                    guard let hit = DAGHitTester.node(at: location, layout: layout, camera: liveCamera,
                                                       viewport: viewport, nodeSize: Self.nodeSize) else { return }
                    if hit == selectedBeadID {
                        onJumpToTab(hit)
                    } else {
                        onSelectNode(hit)
                    }
                }

                minimap(layout: layout, viewport: viewport)
                    .padding(12)

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            .onAppear {
                guard !hasCenteredInitialCamera else { return }
                hasCenteredInitialCamera = true
                centerCamera(on: selectedBeadID, layout: layout)
            }
            .onChange(of: selectedBeadID) { _, newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    centerCamera(on: newValue, layout: layout)
                }
            }
        }
    }

    /// Node set + edges pulled straight from the projection: every bead the poll knows about,
    /// plus any id an edge references but `beadsByID` doesn't (a reservation edge's endpoints
    /// are agent names, not bead ids) — left out of the layout call would mean an edge whose
    /// arrow has nowhere to land.
    private func buildLayout() -> DependencyGraphLayout {
        var ids = Set(projection.beadsByID.keys)
        for edge in projection.depEdges {
            ids.insert(edge.from)
            ids.insert(edge.to)
        }

        var statusByBead: [String: AgentStatus] = [:]
        for agent in projection.agents {
            if let bead = agent.bead { statusByBead[bead.id] = agent.status }
            statusByBead[agent.name] = agent.status
        }

        return DependencyGraphLayout.layout(beadIDs: Array(ids), edges: projection.depEdges,
                                             statusByBead: statusByBead, nodeSize: Self.nodeSize,
                                             spacing: Self.spacing)
    }

    /// The gesture-in-progress camera: `camera` plus whatever the live pan/pinch delta is,
    /// so drawing and hit-testing both read a camera that already reflects the finger that
    /// hasn't lifted yet, rather than jumping on gesture end.
    private func displayCamera(base: DAGCamera, viewport: CGSize) -> DAGCamera {
        var live = base
        live.scale *= magnification
        if panTranslation != .zero {
            // Panning drags the graph, so the camera center moves opposite the gesture and
            // scaled into graph units (view units / scale) — dividing by zero would only
            // happen at scale 0, which `fitting`/`centered` never produce.
            live.center.x -= panTranslation.width / live.scale
            live.center.y -= panTranslation.height / live.scale
        }
        return live
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($panTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                camera.center.x -= value.translation.width / camera.scale
                camera.center.y -= value.translation.height / camera.scale
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($magnification) { value, state, _ in
                state = value
            }
            .onEnded { value in
                camera.scale = max(0.1, min(4, camera.scale * value))
            }
    }

    private func centerCamera(on beadID: String?, layout: DependencyGraphLayout) {
        guard let beadID, let node = layout.nodes[beadID] else { return }
        camera = DAGCamera.centered(on: node.position, scale: camera.scale)
    }

    private func draw(layout: DependencyGraphLayout, camera: DAGCamera, in context: inout GraphicsContext, size: CGSize) {
        let transform = camera.transform(viewport: size)

        for edge in projection.depEdges {
            guard let from = layout.nodes[edge.from], let to = layout.nodes[edge.to] else { continue }
            var path = Path()
            path.move(to: from.position.applying(transform))
            path.addLine(to: to.position.applying(transform))
            let style: StrokeStyle = edge.kind == .reservation
                ? StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                : StrokeStyle(lineWidth: 1.5)
            context.stroke(path, with: .color(.secondary), style: style)
        }

        for (id, node) in layout.nodes {
            let center = node.position.applying(transform)
            let rect = CGRect(x: center.x - Self.nodeSize.width / 2, y: center.y - Self.nodeSize.height / 2,
                               width: Self.nodeSize.width, height: Self.nodeSize.height)
            let cardShape = RoundedRectangle(cornerRadius: 6)
            let isRootCause = id == layout.rootCauseID
            let isSelected = id == selectedBeadID
            context.fill(cardShape.path(in: rect), with: .color(isRootCause ? .orange.opacity(0.25) : .gray.opacity(0.15)))
            context.stroke(cardShape.path(in: rect), with: .color(isSelected ? .accentColor : .secondary),
                            lineWidth: isSelected ? 2 : 1)
            context.draw(Text(id).font(.caption), at: center)
        }
    }

    /// Small fixed-scale overview in the corner, fit to the whole graph's bounds — orientation
    /// when the main camera is zoomed/panned away from the rest of the DAG.
    private func minimap(layout: DependencyGraphLayout, viewport: CGSize) -> some View {
        let bounds = layout.nodes.values.reduce(CGRect.null) { partial, node in
            partial.union(CGRect(x: node.position.x - Self.nodeSize.width / 2, y: node.position.y - Self.nodeSize.height / 2,
                                  width: Self.nodeSize.width, height: Self.nodeSize.height))
        }
        let minimapCamera = bounds.isNull || bounds.isEmpty
            ? DAGCamera(scale: 1, center: .zero)
            : DAGCamera(scale: 1, center: .zero).fitting(bounds, viewport: Self.minimapSize, padding: 0.85)

        return Canvas { context, size in
            let transform = minimapCamera.transform(viewport: size)
            for (_, node) in layout.nodes {
                let center = node.position.applying(transform)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
                              with: .color(node.id == selectedBeadID ? .accentColor : .secondary))
            }
        }
        .frame(width: Self.minimapSize.width, height: Self.minimapSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
    }
}
