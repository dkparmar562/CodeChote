import SwiftUI

/// A provider's logo on a rounded tile. Most come from the asset catalog; Kilo Code and Antigravity are
/// drawn here as simple marks in their colours.
struct AgentIcon: View {
    let agent: AgentKind
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(agent.tint.gradient)
            .frame(width: size, height: size)
            .overlay { glyph.foregroundStyle(agent.glyphColor) }
    }

    @ViewBuilder private var glyph: some View {
        if let asset = agent.brandAsset {
            Image(asset).resizable().scaledToFit().padding(size * 0.22)
        } else if agent == .kilo {
            KiloMark().padding(size * 0.24)
        } else {
            AntigravityMark().padding(size * 0.22)
        }
    }
}

/// A bold "K" built from a stem and two arms.
private struct KiloMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height, t = w * 0.2
            var path = Path()
            path.addRect(CGRect(x: 0, y: 0, width: t, height: h))
            var arm = Path()
            arm.move(to: CGPoint(x: t, y: h * 0.55))
            arm.addLine(to: CGPoint(x: w - t * 0.1, y: 0))
            arm.addLine(to: CGPoint(x: w, y: 0))
            arm.addLine(to: CGPoint(x: w, y: t * 0.9))
            arm.addLine(to: CGPoint(x: t * 1.6, y: h * 0.62))
            arm.closeSubpath()
            var leg = Path()
            leg.move(to: CGPoint(x: t * 1.2, y: h * 0.5))
            leg.addLine(to: CGPoint(x: w, y: h - t * 0.9))
            leg.addLine(to: CGPoint(x: w, y: h))
            leg.addLine(to: CGPoint(x: w - t * 0.9, y: h))
            leg.addLine(to: CGPoint(x: t * 0.6, y: h * 0.62))
            leg.closeSubpath()
            path.addPath(arm); path.addPath(leg)
            context.fill(path, with: .foreground)
        }
    }
}

/// An arch with a lifted dot: "anti-gravity".
private struct AntigravityMark: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var arch = Path()
            arch.move(to: CGPoint(x: w * 0.08, y: h))
            arch.addCurve(to: CGPoint(x: w * 0.5, y: h * 0.28), control1: CGPoint(x: w * 0.2, y: h * 0.55), control2: CGPoint(x: w * 0.35, y: h * 0.28))
            arch.addCurve(to: CGPoint(x: w * 0.92, y: h), control1: CGPoint(x: w * 0.65, y: h * 0.28), control2: CGPoint(x: w * 0.8, y: h * 0.55))
            context.stroke(arch, with: .foreground, style: StrokeStyle(lineWidth: w * 0.16, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: w * 0.4, y: 0, width: w * 0.2, height: w * 0.2)), with: .foreground)
        }
    }
}

extension TabsModel {
    /// What "start this provider" does: native chat, its CLI in a terminal, or the VS Code tab.
    func launch(_ agent: AgentKind, folder: String) {
        switch agent.tier {
        case .chat: open(.chat(agent: agent, session: nil), detail: folder)
        case .terminal: open(.agentTerminal(agent), title: agent.title, detail: folder)
        case .workbench: open(.workbench)
        }
    }
}

extension AgentKind {
    /// One line on what opening it does, for the new-tab page.
    var launchNote: String {
        switch tier {
        case .chat: (self == .claude || self == .codex) ? "Native chat" : "Native chat (experimental)"
        case .terminal: "Runs `\(command ?? title)` in a terminal"
        case .workbench: "Opens in the VS Code tab"
        }
    }
}
