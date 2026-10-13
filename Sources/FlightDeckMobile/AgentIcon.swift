import SwiftUI

/// One agent as a circular provider icon: the phone's copy of the Mac's `AgentBadge`, the same
/// disc, mark and colours, over the same `Agent…` images (copied into this app's catalog; the
/// marks are `@lobehub/icons-static-svg`, MIT). Keyed on the agent's wire id, since the phone
/// has no `AgentID`; an id a newer Mac sends that this build doesn't know draws nothing.
struct AgentIcon: View {
    let agent: String
    var size: CGFloat = 24

    private struct Style {
        let asset: String
        let disc: Color
        let mark: Color
    }

    private static func style(_ agent: String) -> Style? {
        switch agent {
        case "claude": Style(asset: "AgentClaude", disc: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255), mark: .white)
        case "codex": Style(asset: "AgentCodex", disc: .black, mark: .white)
        case "grok": Style(asset: "AgentGrok", disc: .black, mark: .white)
        case "gemini": Style(asset: "AgentGemini", disc: .white, mark: Color(red: 0x31 / 255, green: 0x86 / 255, blue: 0xFF / 255))
        case "opencode": Style(asset: "AgentOpenCode", disc: .black, mark: .white)
        default: nil
        }
    }

    /// Whether this build has an icon for `agent`.
    static func known(_ agent: String) -> Bool { style(agent) != nil }

    var body: some View {
        if let style = Self.style(agent) {
            Circle()
                .fill(style.disc)
                .overlay(
                    Image(style.asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(style.mark)
                        .frame(width: size * 0.6, height: size * 0.6)
                )
                // A black or white disc is near the background in one appearance or the other;
                // the hairline keeps it a visible circle on either.
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
