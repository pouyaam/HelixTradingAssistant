import SwiftUI

/// Brand identity for the two AI engines. We deliberately render small
/// vector marks — not the literal trademarked logos and not text — so
/// the engine picker + analysis tabs read at a glance ("which model
/// produced this?") the way the rest of the app uses iconography.
///
/// `AIEngineKind` itself lives in `AI/AIEngine.swift` (Foundation-only);
/// the Color-returning brand bits live here so we can stay in SwiftUI.
extension AIEngineKind {
    /// Approximate brand colour. Claude = Anthropic terracotta, Codex =
    /// OpenAI green. Used to tint the glyph + the selected-engine ring.
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0.84, green: 0.46, blue: 0.33)   // #D6764F-ish
        case .codex:  return Color(red: 0.06, green: 0.64, blue: 0.50)   // #10A37F-ish
        }
    }
}

/// A small, recognisable mark for an AI engine. Claude renders as a
/// terracotta sunburst (its asterisk-like brand shape); Codex as an
/// OpenAI-style six-petal knot. Both are drawn from simple geometry so
/// no image assets are needed and they stay crisp at any size.
struct EngineGlyph: View {
    let kind: AIEngineKind
    var size: CGFloat = 14

    var body: some View {
        Group {
            switch kind {
            case .claude:
                ClaudeBurst()
                    .stroke(
                        kind.brandColor,
                        style: StrokeStyle(lineWidth: size * 0.13, lineCap: .round)
                    )
            case .codex:
                OpenAIKnot()
                    .stroke(
                        kind.brandColor,
                        style: StrokeStyle(lineWidth: size * 0.10, lineJoin: .round)
                    )
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.label)
    }
}

/// Anthropic-style sunburst — evenly-spaced rays radiating from a small
/// inner gap. Stroked with round caps so each ray reads as a soft spoke.
private struct ClaudeBurst: Shape {
    var rays: Int = 12
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2 * 0.92
        let inner = outer * 0.34
        for i in 0..<rays {
            let a = (Double(i) / Double(rays)) * 2 * .pi - .pi / 2
            let p1 = CGPoint(x: c.x + CGFloat(cos(a)) * inner,
                             y: c.y + CGFloat(sin(a)) * inner)
            let p2 = CGPoint(x: c.x + CGFloat(cos(a)) * outer,
                             y: c.y + CGFloat(sin(a)) * outer)
            p.move(to: p1)
            p.addLine(to: p2)
        }
        return p
    }
}

/// OpenAI-style knot, approximated by three tall ellipses rotated 60°
/// apart. Their overlap forms the six-petal blossom the brand is built
/// around — distinct from the Claude burst at a glance.
private struct OpenAIKnot: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2 * 0.94
        let petalW = r * 1.05
        let petalH = r * 2.0
        for k in 0..<3 {
            let angle = Double(k) * .pi / 3   // 0°, 60°, 120°
            let ellipse = Path(ellipseIn: CGRect(
                x: c.x - petalW / 2,
                y: c.y - petalH / 2,
                width: petalW,
                height: petalH
            ))
            let t = CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
            p.addPath(ellipse.applying(t))
        }
        return p
    }
}
