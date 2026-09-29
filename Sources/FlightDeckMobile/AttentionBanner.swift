import SwiftUI

/// The in-app "needs you" banner (spec §4.2): top of the screen, ~4 s, swipe up or tap.
struct AttentionBanner: View {
    let banner: IntakeBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark").font(.footnote.weight(.bold))
                    .frame(width: 26, height: 26).foregroundStyle(.black)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange))
                VStack(alignment: .leading, spacing: 1) {
                    // Two lines: the words that say what it needs come last and one line cut them.
                    Text(banner.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(banner.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .gesture(DragGesture(minimumDistance: 10).onEnded { if $0.translation.height < 0 { onDismiss() } })
        .task(id: banner.id) {
            try? await Task.sleep(for: .seconds(4))
            onDismiss()
        }
        .onAppear { UIAccessibility.post(notification: .announcement, argument: "\(banner.title). \(banner.subtitle)") }
    }
}
