#!/usr/bin/env swift
// make-icon.swift: renders the MacSize app icon and logo from source.
//
// Usage:
//   swift scripts/make-icon.swift [outdir]      (default outdir: Resources/AppIcon)
//
// Writes into <outdir>:
//   AppIcon.icns       every size iconutil expects (16-512 pt at @1x and @2x)
//   AppIcon-1024.png   1024 x 1024 master, for the README and website
//   logo.svg           monochrome treemap mark (currentColor), no background
//
// The design is original and drawn entirely with CoreGraphics: a squarified
// treemap of five tiles on a macOS Big Sur-style rounded-square body. The
// mark is inspired by the "treemap / layout grid" glyph idea found in the
// Tabler Icons (`chart-treemap`, MIT) and Lucide (`layout-dashboard`, ISC)
// open-source sets, but no path data is copied from either. See
// Resources/AppIcon/LICENSE-ATTRIBUTION.md.
//
// Requires macOS with the Xcode command-line tools (swift, iconutil).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants (all in the 1024 x 1024 canvas space)

let canvas: CGFloat = 1024
/// Apple's macOS icon grid: an 824 pt body centred on the 1024 canvas.
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyCornerRadius: CGFloat = 185

/// The treemap occupies this square inside the body.
let markInset: CGFloat = 96           // from body edge at large sizes
let markInsetSmall: CGFloat = 64      // tighter at 16/32 px so the tiles stay legible
let tileGap: CGFloat = 24
let tileCornerRadius: CGFloat = 30

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat
    init(_ hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func mixed(with o: RGB, _ t: CGFloat) -> RGB {
        RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    init(r: CGFloat, g: CGFloat, b: CGFloat) { self.r = r; self.g = g; self.b = b }
}
let white = RGB(0xFFFFFF)

/// A tile in unit coordinates of the mark square (origin top-left, y down).
struct Tile {
    let x0: CGFloat, y0: CGFloat, x1: CGFloat, y1: CGFloat
    let color: RGB
}

// Squarified layout of the weights 40, 24, 16, 12, 8 in a unit square:
// column 1 = [40, 24] (width 0.64), column 2 = [16, 12, 8] (width 0.36).
// The 40% tile is the warm "biggest thing"; the rest share a cool palette.
let tiles: [Tile] = [
    Tile(x0: 0.00, y0: 0.000, x1: 0.64, y1: 0.625, color: RGB(0xFF7A45)), // 40  coral (emphasis)
    Tile(x0: 0.00, y0: 0.625, x1: 0.64, y1: 1.000, color: RGB(0x14B8A6)), // 24  teal
    Tile(x0: 0.64, y0: 0.000, x1: 1.00, y1: 0.444, color: RGB(0x3B82F6)), // 16  blue
    Tile(x0: 0.64, y0: 0.444, x1: 1.00, y1: 0.778, color: RGB(0x6366F1)), // 12  indigo
    Tile(x0: 0.64, y0: 0.778, x1: 1.00, y1: 1.000, color: RGB(0x38BDF8)), //  8  sky
]

/// At 16 px the 8% tile would be a single pixel tall, so the smallest render
/// uses a simplified four-tile layout (the indigo tile absorbs it).
let tiles16: [Tile] = [tiles[0], tiles[1], tiles[2],
                       Tile(x0: 0.64, y0: 0.444, x1: 1.00, y1: 1.000, color: tiles[3].color)]

func layout(px: Int) -> [Tile] { px <= 16 ? tiles16 : tiles }

let bgTop = RGB(0x2A3550)
let bgBottom = RGB(0x111827)

// MARK: - Geometry helpers

/// Converts the canvas-space rect (y down) into the pixel rect for a given
/// output size, optionally snapping to whole pixels.
func scaled(_ r: CGRect, _ s: CGFloat, snap: Bool) -> CGRect {
    var out = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    if snap {
        let x0 = out.minX.rounded(), y0 = out.minY.rounded()
        let x1 = out.maxX.rounded(), y1 = out.maxY.rounded()
        out = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    return out
}

/// Pixel rects of the treemap tiles for an output of `px` pixels.
func tileRects(px: Int) -> [CGRect] {
    let s = CGFloat(px) / canvas
    let small = px <= 64
    let inset = px <= 32 ? markInsetSmall : markInset
    var mark = scaled(bodyRect.insetBy(dx: inset, dy: inset), s, snap: small)
    if small { mark = mark.integral }
    // Gap in pixels: at least one full pixel so tiles stay separate at 16 px.
    let gap: CGFloat = small ? max(1, (tileGap * s).rounded()) : tileGap * s
    return layout(px: px).map { t in
        var x0 = mark.minX + t.x0 * mark.width
        var x1 = mark.minX + t.x1 * mark.width
        var y0 = mark.minY + t.y0 * mark.height
        var y1 = mark.minY + t.y1 * mark.height
        if small { x0.round(); x1.round(); y0.round(); y1.round() }
        // Shared edges get half a gap each; outer edges stay flush with the mark.
        let h = gap / 2
        if t.x0 > 0 { x0 += small ? (gap - (gap / 2).rounded(.down)) : h }
        if t.x1 < 1 { x1 -= small ? (gap / 2).rounded(.down) : h }
        if t.y0 > 0 { y0 += small ? (gap - (gap / 2).rounded(.down)) : h }
        if t.y1 < 1 { y1 -= small ? (gap / 2).rounded(.down) : h }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

// MARK: - Rendering

func render(px: Int) -> CGImage {
    let s = CGFloat(px) / canvas
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a y-down coordinate system so the layout above reads naturally.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)

    let small = px <= 64
    let body = scaled(bodyRect, s, snap: small)
    let radius = bodyCornerRadius * s
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Drop shadow under the body (Apple's template: ~28 pt blur, 12 pt down).
    if px >= 32 {
        ctx.saveGState()
        // CG shadow offsets are in base space (y up), so negative y is "down".
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 28 * s,
                      color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(bodyPath)
        ctx.setFillColor(bgBottom.cg())
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Body: vertical gradient.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [bgTop.cg(), bgBottom.cg()] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.minY), end: CGPoint(x: 0, y: body.maxY),
                           options: [])
    // Soft top sheen.
    if !small {
        let sheen = CGGradient(colorsSpace: cs,
                               colors: [white.cg(0.10), white.cg(0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: body.midX, y: body.minY),
                               startRadius: 0,
                               endCenter: CGPoint(x: body.midX, y: body.minY),
                               endRadius: body.width * 0.9, options: [])
    }
    ctx.restoreGState()

    // Tiles.
    let rects = tileRects(px: px)
    let tr = small ? max(0.0, min(tileCornerRadius * s, 1.0)) : tileCornerRadius * s
    for (tile, rect) in zip(layout(px: px), rects) {
        let path = CGPath(roundedRect: rect, cornerWidth: tr, cornerHeight: tr, transform: nil)
        // Shadow beneath each tile for a little depth.
        if !small {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path)
            ctx.setFillColor(tile.color.cg())
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let top = tile.color.mixed(with: white, small ? 0.08 : 0.22)
        let grad = CGGradient(colorsSpace: cs, colors: [top.cg(), tile.color.cg()] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: rect.minY),
                               end: CGPoint(x: 0, y: rect.maxY), options: [])
        ctx.restoreGState()
        // Hairline highlight on the top edge.
        if !small {
            ctx.saveGState()
            ctx.addPath(path)
            ctx.clip()
            ctx.setStrokeColor(white.cg(0.28))
            ctx.setLineWidth(3 * s)
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + 1.5 * s))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 1.5 * s))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // Thin inner border so the dark body keeps its edge on a dark Dock.
    // (Skipped at 16 px, where it would sit directly against the tiles.)
    guard px > 16 else { return ctx.makeImage()! }
    ctx.saveGState()
    let bw = max(1, 2 * s)
    let inner = body.insetBy(dx: bw / 2, dy: bw / 2)
    ctx.addPath(CGPath(roundedRect: inner, cornerWidth: radius - bw / 2, cornerHeight: radius - bw / 2,
                       transform: nil))
    ctx.setStrokeColor(white.cg(small ? 0.14 : 0.10))
    ctx.setLineWidth(bw)
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"]) }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot finalize \(url.path)"])
    }
}

// MARK: - SVG logo (monochrome mark only)

func logoSVG() -> String {
    // 100 x 100 viewBox; same layout, gaps and corner radii as the icon mark.
    let size: CGFloat = 100
    let gap: CGFloat = 4
    let r: CGFloat = 4
    func f(_ v: CGFloat) -> String {
        let rounded = (v * 100).rounded() / 100
        return String(format: "%g", rounded)
    }
    var rects: [String] = []
    for t in tiles {
        var x0 = t.x0 * size, x1 = t.x1 * size, y0 = t.y0 * size, y1 = t.y1 * size
        if t.x0 > 0 { x0 += gap / 2 }
        if t.x1 < 1 { x1 -= gap / 2 }
        if t.y0 > 0 { y0 += gap / 2 }
        if t.y1 < 1 { y1 -= gap / 2 }
        rects.append("  <rect x=\"\(f(x0))\" y=\"\(f(y0))\" width=\"\(f(x1 - x0))\" height=\"\(f(y1 - y0))\" rx=\"\(f(r))\"/>")
    }
    return """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" fill="currentColor" role="img" aria-label="MacSize">
      <!-- MacSize treemap mark. Original design, MIT licensed; generated by scripts/make-icon.swift. -->
    \(rects.joined(separator: "\n"))
    </svg>

    """
}

// MARK: - Main

func run() throws {
    let fm = FileManager.default
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let outDir: URL
    if CommandLine.arguments.count > 1 {
        outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
    } else {
        outDir = repoRoot.appendingPathComponent("Resources/AppIcon", isDirectory: true)
    }
    try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Build the iconset in a temporary directory.
    let tmp = fm.temporaryDirectory.appendingPathComponent("macsize-icon-\(UUID().uuidString)", isDirectory: true)
    let iconset = tmp.appendingPathComponent("AppIcon.iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }

    var cache: [Int: CGImage] = [:]
    func image(_ px: Int) -> CGImage {
        if let img = cache[px] { return img }
        let img = render(px: px)
        cache[px] = img
        return img
    }
    for pt in [16, 32, 128, 256, 512] {
        try writePNG(image(pt), to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
        try writePNG(image(pt * 2), to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
    }

    let icns = outDir.appendingPathComponent("AppIcon.icns")
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw NSError(domain: "make-icon", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "iconutil failed with status \(proc.terminationStatus)"])
    }

    try writePNG(image(1024), to: outDir.appendingPathComponent("AppIcon-1024.png"))
    try logoSVG().write(to: outDir.appendingPathComponent("logo.svg"), atomically: true, encoding: .utf8)

    // Optional: keep the individual renders for inspection.
    if ProcessInfo.processInfo.environment["KEEP_ICONSET"] != nil {
        let kept = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try? fm.removeItem(at: kept)
        try fm.copyItem(at: iconset, to: kept)
        print("Kept \(kept.path)")
    }

    print("Wrote \(icns.path)")
    print("Wrote \(outDir.appendingPathComponent("AppIcon-1024.png").path)")
    print("Wrote \(outDir.appendingPathComponent("logo.svg").path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("make-icon: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
