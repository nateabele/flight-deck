import SwiftUI

/// The chrome shared by the two panels that float over the terminal: `ToolOverlay` and
/// `TerminalSearchBar`.
///
/// It exists so the pair cannot drift apart. They stack in the same top-right corner and are
/// frequently on screen together, so two different treatments there read as two unrelated
/// pieces of UI — which is why both previously hard-coded the same material, border and
/// shadow, and why Liquid Glass had to arrive at both at once rather than just the tools bar.
///
/// Glass is applied only where the system actually has it. The deployment target is macOS
/// 14.0 while `glassEffect` is macOS 26.0+, so the fallback is not hypothetical: it is the
/// literal previous appearance, kept verbatim. Glass draws its own edge and shadow, so the
/// explicit border and drop shadow belong to the fallback path only — layering a hard
/// `.separator` stroke over glass fights the material rather than defining it.
struct FloatingChrome: ViewModifier {
    var cornerRadius: CGFloat = 8

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator))
                .shadow(radius: 4, y: 2)
        }
    }
}

extension View {
    /// Applies `FloatingChrome`. Both call sites use the default radius; the parameter exists
    /// so a future panel can differ without either of them growing a second treatment.
    func floatingChrome(cornerRadius: CGFloat = 8) -> some View {
        modifier(FloatingChrome(cornerRadius: cornerRadius))
    }
}
