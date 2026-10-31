import FleetKit
import SwiftUI
import UIKit

/// What a visual card decides before any bytes arrive, apart from SwiftUI so it can be tested.
enum VisualBlockStyle {
    /// Used when the Mac did not say (an older Mac, or a kind with no natural shape).
    static let defaultAspect: Double = 16.0 / 9.0
    /// Bounds on a width-over-height the Mac sends, so a one-pixel-tall strip or a skyscraper
    /// cannot make the card absurd.
    static let minAspect: Double = 0.5
    static let maxAspect: Double = 4.0

    /// The card's width over height, from `aspect`, so its frame is the right size before the
    /// snapshot arrives and nothing below it moves when it does.
    static func aspect(for ref: WireVisualRef?) -> Double {
        guard let a = ref?.aspect, a.isFinite, a > 0 else { return defaultAspect }
        return min(max(a, minAspect), maxAspect)
    }

    /// A phone shows the narrow snapshot when there is one: the wide one is drawn for a desktop
    /// and would be a thumbnail here.
    static func size(for ref: WireVisualRef) -> String? {
        let sizes = ref.sizes ?? []
        return sizes.contains("narrow") ? "narrow" : sizes.first
    }

    /// The first state is the default (the manifest's own rule).
    static func state(for ref: WireVisualRef) -> String? { ref.states.first }
}

/// A plan's `fd-visual` block, inline in the reader: the snapshot, a filmstrip of its other
/// states, and the caption. Tapping opens the live viewer.
///
/// **The frame is laid out from `ref.aspect` alone.** The picture, the thumbnails and the viewer
/// arrive later, and every one lands in space that was already reserved, so the reader does not
/// jump under a thumb. The filmstrip row is there from the first layout whenever the ref says
/// there is more than one state or any alternate, for the same reason.
struct VisualBlockCard: View {
    let intake: UUID
    let id: String
    let caption: String
    /// nil: the plan names a visual the Mac's list does not carry yet (a `pending` placeholder, or
    /// one that has not landed).
    let ref: WireVisualRef?

    @Environment(\.visualLoader) private var loader
    @State private var selected: String?
    @State private var images: [String: UIImage] = [:]
    @State private var viewing = false

    private static let thumbHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            frame
            if let ref, hasFilmstrip(ref) { filmstrip(ref) }
            if !caption.isEmpty {
                Text(caption).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: ref?.revision) { await loadSnapshots() }
        .fullScreenCover(isPresented: $viewing) {
            if let ref { VisualViewerScreen(intake: intake, ref: ref, initialState: current(ref)) }
        }
    }

    private func current(_ ref: WireVisualRef) -> String? { selected ?? VisualBlockStyle.state(for: ref) }

    private var frame: some View {
        let aspect = VisualBlockStyle.aspect(for: ref)
        return Color(.secondarySystemBackground)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let ref, let image = images[current(ref) ?? ""] {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if ref != nil {
                    ProgressView()
                } else {
                    VStack(spacing: 4) {
                        Image(systemName: "hourglass").imageScale(.large)
                        Text("Waiting for \(id)").font(.footnote)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { if ref != nil { viewing = true } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(caption.isEmpty ? "Visual \(id)" : caption)
            .accessibilityHint(ref == nil ? "Not available yet" : "Opens the visual full screen")
            .accessibilityAddTraits(ref == nil ? [] : .isButton)
    }

    private func hasFilmstrip(_ ref: WireVisualRef) -> Bool { ref.states.count > 1 || !ref.alternates.isEmpty }

    private func filmstrip(_ ref: WireVisualRef) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ref.states, id: \.self) { state in
                    let on = current(ref) == state
                    Button { selected = state } label: {
                        Color(.secondarySystemBackground)
                            .frame(width: Self.thumbHeight * VisualBlockStyle.aspect(for: ref), height: Self.thumbHeight)
                            .overlay {
                                if let image = images[state] { Image(uiImage: image).resizable().scaledToFit() }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                               lineWidth: on ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("State \(state)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                // Alternates are other revisions; their files are not in this ref, so they are
                // named here and open from the viewer once the Mac lists them.
                ForEach(Array(ref.alternates.enumerated()), id: \.offset) { _, alt in
                    Text(alt.kind).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8).frame(height: Self.thumbHeight)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange.opacity(0.15)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.6), lineWidth: 1))
                        .accessibilityLabel("Alternate: \(alt.kind)\(alt.reason.map { ", \($0)" } ?? "")")
                }
            }
        }
        .frame(height: Self.thumbHeight + 4)
    }

    /// The default state's snapshot first, so the card fills as soon as the one picture does,
    /// then the rest of the filmstrip.
    private func loadSnapshots() async {
        guard let ref, let loader else { return }
        let size = VisualBlockStyle.size(for: ref)
        let states: [String?] = ref.states.isEmpty ? [nil] : ref.states.map { Optional($0) }
        for state in states {
            guard let data = await loader.snapshot(intake: intake, ref: ref, state: state, size: size),
                  let image = UIImage(data: data) else { continue }
            images[state ?? ""] = image
        }
    }
}
