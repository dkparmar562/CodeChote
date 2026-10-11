import SwiftUI

/// Liquid Glass (iOS 26+) with a blur fallback for earlier systems.
extension View {

    /// Glass in the given shape; `active` tints it, `interactive` makes it respond to touch.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(Self.glassStyle(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay { if let tint { shape.fill(tint.opacity(0.18)) } }
        }
    }

    @available(iOS 26.0, *)
    private static func glassStyle(tint: Color?, interactive: Bool) -> Glass {
        var style = Glass.regular
        if let tint { style = style.tint(tint) }
        if interactive { style = style.interactive() }
        return style
    }

    /// Lets nearby glass shapes blend and morph together on iOS 26+; a plain container before.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Morphs between items sharing an id when the selection moves (iOS 26+).
    @ViewBuilder
    func glassID(_ id: some Hashable & Sendable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }
}

extension Color {
    /// Parses `#rgb`, `#rrggbb`, `#rrggbbaa` and `rgb()/rgba()` as reported by the page.
    init?(css: String) {
        let text = css.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            var hex = String(text.dropFirst())
            if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
            let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
            let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
            let a = hasAlpha ? Double(value & 0xff) / 255 : 1
            self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
        } else if text.hasPrefix("rgb") {
            let numbers = text.split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
            guard numbers.count >= 3 else { return nil }
            self.init(.sRGB, red: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255, opacity: numbers.count > 3 ? numbers[3] : 1)
        } else {
            return nil
        }
    }
}
