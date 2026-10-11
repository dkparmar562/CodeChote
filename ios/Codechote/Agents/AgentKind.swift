import SwiftUI

enum AgentKind: String, Codable, CaseIterable, Identifiable {
    case claude, codex, cursor, opencode, kilo, gemini, copilot, antigravity
    var id: String { rawValue }

    /// How the app can work with this provider.
    enum Tier {
        case chat       // native chat over the agent's headless mode
        case terminal   // its CLI, in a native terminal tab
        case workbench  // an extension that lives in the VS Code tab
    }

    var tier: Tier {
        switch self {
        case .claude, .codex, .cursor, .opencode, .kilo, .gemini, .copilot: .chat
        case .antigravity: .chat
        }
    }

    /// Providers with a native chat screen.
    static var chatKinds: [AgentKind] { allCases.filter { $0.tier == .chat } }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .kilo: "Kilo Code"
        case .gemini: "Gemini CLI"
        case .copilot: "GitHub Copilot"
        case .antigravity: "Antigravity"
        }
    }

    /// The program that starts it in a terminal.
    var command: String? {
        switch self {
        case .cursor: "cursor-agent"
        case .opencode: "opencode"
        case .kilo: "kilo"
        case .gemini: "gemini"
        case .copilot: "copilot"
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "agy"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        default: "sparkles"
        }
    }

    /// Asset-catalog logo, where one exists (the rest are drawn in `AgentIcon`).
    var brandAsset: String? {
        switch self {
        case .claude: "Brand-claude"
        case .codex: "Brand-openai"
        case .cursor: "Brand-cursor"
        case .opencode: "Brand-opencode"
        case .gemini: "Brand-googlegemini"
        case .copilot: "Brand-githubcopilot"
        case .kilo, .antigravity: nil
        }
    }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.06, green: 0.64, blue: 0.5)
        case .cursor: Color(white: 0.1)
        case .opencode: Color(white: 0.2)
        case .kilo: Color(red: 0.96, green: 0.8, blue: 0.1)
        case .gemini: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .copilot: Color(red: 0.4, green: 0.3, blue: 0.85)
        case .antigravity: Color(red: 0.2, green: 0.45, blue: 0.95)
        }
    }

    /// Dark marks need a light glyph; the yellow one needs a dark glyph.
    var glyphColor: Color { self == .kilo ? .black : .white }
}
