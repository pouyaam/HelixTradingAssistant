#!/usr/bin/env swift
//
// HelixIconGen — generates the Helix Trading app icon at every size
// macOS demands and drops the PNGs into AppIcon.appiconset.
//
// Usage:
//   cd GoldMonitorMac
//   swift Tools/HelixIconGen.swift
//
// The icon design:
//   • Deep-navy squircle background, Big-Sur-style rounded corners.
//   • A central double-helix motif: two intertwined sinusoidal strands
//     wrapping around a vertical axis ~2.5 turns top-to-bottom. Front
//     and back segments alternate per turn so the helix reads as 3D.
//   • Amber/gold accent for the front strand (matches Theme.accent),
//     muted gold for the back strand.
//   • Six tiny candlestick silhouettes drifting behind the helix at
//     reduced opacity — a subtle "trading" hint without making the
//     icon read as a chart at thumbnail size.
//
// All drawing happens in Core Graphics via NSGraphicsContext — no
// external assets, no SVG parser, fully reproducible from source.
//
// Output paths (relative to script working dir):
//   GoldMonitorMac/Resources/Assets.xcassets/AppIcon.appiconset/icon_<size>.png
//   GoldMonitorMac/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json
//

import Foundation
import AppKit
import CoreGraphics

// MARK: - Required sizes

/// Each entry: (file basename, pixel dimension). Apple's macOS app icon
/// catalog wants 10 PNG files; some sizes appear twice with different
/// names (e.g. 32×32 lives at both `icon_16x16@2x.png` and
/// `icon_32x32.png`). Generating both keeps the catalog tidy and
/// matches Xcode's default layout.
let outputs: [(name: String, size: Int)] = [
    ("icon_16x16",     16),
    ("icon_16x16@2x",  32),
    ("icon_32x32",     32),
    ("icon_32x32@2x",  64),
    ("icon_128x128",   128),
    ("icon_128x128@2x",256),
    ("icon_256x256",   256),
    ("icon_256x256@2x",512),
    ("icon_512x512",   512),
    ("icon_512x512@2x",1024),
]

// MARK: - Colors

/// Background gradient — deep navy with a warm-tinted dark centre so
/// the helix glows out of it rather than sitting flat on black.
let bgInner = NSColor(srgbRed: 0.055, green: 0.090, blue: 0.188, alpha: 1.0)
let bgOuter = NSColor(srgbRed: 0.016, green: 0.027, blue: 0.075, alpha: 1.0)

/// Front strand (gold gradient, top→bottom).
let strandFrontTop    = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.32, alpha: 1.0)
let strandFrontBottom = NSColor(srgbRed: 1.00, green: 0.52, blue: 0.08, alpha: 1.0)

/// Back strand (muted gold) — slightly desaturated and dimmer so the
/// front strand reads as in front.
let strandBack = NSColor(srgbRed: 0.55, green: 0.42, blue: 0.18, alpha: 0.85)

/// Background candlestick tint — same hue as the foreground gold but
/// far more transparent so the candles register subliminally.
let candleBullish = NSColor(srgbRed: 0.20, green: 0.78, blue: 0.46, alpha: 0.18)
let candleBearish = NSColor(srgbRed: 0.94, green: 0.30, blue: 0.30, alpha: 0.18)

// MARK: - Drawing

/// Render the icon at `size`×`size` pixels and return PNG bytes.
func renderIcon(size: Int) -> Data? {
    let pixels = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    )
    guard let rep = rep,
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    drawBackground(into: cg, size: pixels)
    drawCandles(into: cg, size: pixels)
    drawHelix(into: cg, size: pixels)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

/// Big Sur–style rounded-square background. Macro-control points:
///   • cornerRadius ≈ 22% of canvas matches Apple's macOS icon mask.
///   • radial gradient lifts the centre by ~5% so the helix has
///     somewhere to "glow" out of.
func drawBackground(into cg: CGContext, size: CGFloat) {
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.22
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    cg.saveGState()
    cg.addPath(path)
    cg.clip()

    let colors = [bgInner.cgColor, bgOuter.cgColor] as CFArray
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0.0, 1.0])!
    let center = CGPoint(x: size / 2, y: size * 0.55)
    cg.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: size * 0.75,
        options: [.drawsAfterEndLocation]
    )
    cg.restoreGState()
}

/// Six candle silhouettes drifting across the background — three
/// green, three red, alternating, kept very transparent so they
/// don't compete with the helix at any size.
func drawCandles(into cg: CGContext, size: CGFloat) {
    let candleWidth = size * 0.035
    let wickWidth = size * 0.008
    let positions: [(x: CGFloat, bullish: Bool, bodyTop: CGFloat, bodyBottom: CGFloat, wickTop: CGFloat, wickBottom: CGFloat)] = [
        (0.13, false, 0.42, 0.62, 0.36, 0.66),
        (0.22, true,  0.50, 0.74, 0.45, 0.80),
        (0.32, true,  0.32, 0.58, 0.28, 0.62),
        (0.68, false, 0.46, 0.70, 0.40, 0.74),
        (0.78, true,  0.36, 0.60, 0.32, 0.66),
        (0.87, false, 0.50, 0.72, 0.46, 0.78),
    ]
    cg.saveGState()
    for c in positions {
        let color = c.bullish ? candleBullish : candleBearish
        cg.setFillColor(color.cgColor)

        let bodyRect = CGRect(
            x: size * c.x - candleWidth / 2,
            y: size * c.bodyTop,
            width: candleWidth,
            height: size * (c.bodyBottom - c.bodyTop)
        )
        let wickRect = CGRect(
            x: size * c.x - wickWidth / 2,
            y: size * c.wickTop,
            width: wickWidth,
            height: size * (c.wickBottom - c.wickTop)
        )
        cg.fill(wickRect)
        cg.fill(bodyRect)
    }
    cg.restoreGState()
}

/// Double-helix motif. Each strand is a sinusoidal path traced from
/// top to bottom, split into "front" and "back" segments based on the
/// phase so the two strands appear to weave in 3D. Stroke width tapers
/// slightly at the segment seams to soften the colour transitions.
func drawHelix(into cg: CGContext, size: CGFloat) {
    // Content area: ~10% inset on each side so the helix sits inside
    // the visual safe area Apple's icon mask carves out.
    let inset = size * 0.18
    let topY = inset
    let bottomY = size - inset
    let centerX = size / 2
    let amplitude = (size - inset * 2) * 0.30   // horizontal half-spread
    let strokeWidth = size * 0.055
    let turns: CGFloat = 2.3

    // Sample many points along the vertical so the curves are smooth
    // at 1024 and still legible at 16. ~120 samples is overkill for
    // 16px but cheap to render.
    let samples = 240
    struct StrandPoint { var x: CGFloat; var y: CGFloat; var depth: CGFloat }

    // Build both strands; phase offset by π so they spiral against each
    // other.
    func buildStrand(phase: CGFloat) -> [StrandPoint] {
        var out: [StrandPoint] = []
        for i in 0...samples {
            let t = CGFloat(i) / CGFloat(samples)
            let y = topY + (bottomY - topY) * t
            let angle = t * turns * 2 * .pi + phase
            let x = centerX + amplitude * cos(angle)
            let depth = sin(angle)   // +1 = nearest viewer, -1 = farthest
            out.append(StrandPoint(x: x, y: y, depth: depth))
        }
        return out
    }

    let strand1 = buildStrand(phase: 0)
    let strand2 = buildStrand(phase: .pi)

    // Vertical gradient stamp used to colour the front strand. Drawn
    // as a clip-then-fill so each strand segment picks up the same
    // top→bottom amber transition rather than being a flat colour.
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let frontGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [strandFrontTop.cgColor, strandFrontBottom.cgColor] as CFArray,
        locations: [0.0, 1.0]
    )!

    /// Trace a sub-path of a strand for the segment that lies within
    /// the predicate's depth range. We render in two passes per
    /// strand so the visible "front" arcs sit on top of the "back"
    /// arcs of the OTHER strand.
    func tracePath(_ pts: [StrandPoint], predicate: (CGFloat) -> Bool) -> [CGPath] {
        var paths: [CGPath] = []
        var current = CGMutablePath()
        var inSegment = false
        for p in pts {
            if predicate(p.depth) {
                if !inSegment {
                    current = CGMutablePath()
                    current.move(to: CGPoint(x: p.x, y: p.y))
                    inSegment = true
                } else {
                    current.addLine(to: CGPoint(x: p.x, y: p.y))
                }
            } else if inSegment {
                paths.append(current)
                inSegment = false
            }
        }
        if inSegment { paths.append(current) }
        return paths
    }

    // ── Pass 1: BACK segments (depth < 0), drawn in muted gold so
    //          they recede behind the front segments.
    cg.saveGState()
    cg.setStrokeColor(strandBack.cgColor)
    cg.setLineWidth(strokeWidth * 0.85)
    cg.setLineCap(.round)
    for path in tracePath(strand1, predicate: { $0 < 0 }) {
        cg.addPath(path); cg.strokePath()
    }
    for path in tracePath(strand2, predicate: { $0 < 0 }) {
        cg.addPath(path); cg.strokePath()
    }
    cg.restoreGState()

    // ── Pass 2: FRONT segments (depth >= 0), drawn last so they sit
    //          on top of whatever's behind. Filled by clipping a wide
    //          gradient rectangle to the stroked path.
    func strokeWithGradient(_ paths: [CGPath]) {
        for path in paths {
            cg.saveGState()
            cg.addPath(path)
            cg.setLineCap(.round)
            cg.setLineWidth(strokeWidth)
            cg.replacePathWithStrokedPath()
            cg.clip()
            cg.drawLinearGradient(
                frontGradient,
                start: CGPoint(x: 0, y: topY),
                end:   CGPoint(x: 0, y: bottomY),
                options: []
            )
            cg.restoreGState()
        }
    }

    strokeWithGradient(tracePath(strand1, predicate: { $0 >= 0 }))
    strokeWithGradient(tracePath(strand2, predicate: { $0 >= 0 }))

    // ── Crossbar rungs (subtle): faint dashed segments connecting the
    //    two strands every half-turn, at points where both strands are
    //    near depth zero. Gives the helix a "DNA ladder" hint without
    //    cluttering the silhouette.
    cg.saveGState()
    cg.setStrokeColor(NSColor(srgbRed: 1.00, green: 0.86, blue: 0.55, alpha: 0.28).cgColor)
    cg.setLineWidth(strokeWidth * 0.18)
    cg.setLineCap(.round)
    let rungCount = 5
    for i in 0..<rungCount {
        let t = CGFloat(i + 1) / CGFloat(rungCount + 1)
        let y = topY + (bottomY - topY) * t
        let angle = t * turns * 2 * .pi
        let x1 = centerX + amplitude * cos(angle)
        let x2 = centerX + amplitude * cos(angle + .pi)
        cg.move(to: CGPoint(x: x1, y: y))
        cg.addLine(to: CGPoint(x: x2, y: y))
        cg.strokePath()
    }
    cg.restoreGState()
}

// MARK: - File output

let scriptDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appiconset = scriptDir.appendingPathComponent(
    "GoldMonitorMac/Resources/Assets.xcassets/AppIcon.appiconset"
)

guard FileManager.default.fileExists(atPath: appiconset.path) else {
    fputs("error: \(appiconset.path) does not exist — run from GoldMonitorMac/ directory\n", stderr)
    exit(1)
}

print("Writing icons to \(appiconset.path)")
for entry in outputs {
    guard let png = renderIcon(size: entry.size) else {
        fputs("error: failed to render \(entry.name) at \(entry.size)px\n", stderr)
        exit(1)
    }
    let url = appiconset.appendingPathComponent("\(entry.name).png")
    try png.write(to: url)
    print("  ✓ \(entry.name).png (\(entry.size)×\(entry.size), \(png.count) bytes)")
}

// MARK: - Contents.json

let contentsJSON = """
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
let contentsURL = appiconset.appendingPathComponent("Contents.json")
try contentsJSON.write(to: contentsURL, atomically: true, encoding: .utf8)
print("  ✓ Contents.json updated")
print("Done.")
