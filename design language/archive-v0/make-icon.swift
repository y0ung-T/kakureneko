// Draws the first placeholder app icon for Kakureneko (a closed laptop under a crescent moon, its status light still on) with
// CoreGraphics and writes a macOS .iconset. Run through scripts/make-icon.sh, which turns it into
// Resources/AppIcon.icns with `iconutil`. Pure drawing: no network, no system changes.
//
// Usage: swiftc -O scripts/make-icon.swift -o <tmp>/make-icon && <tmp>/make-icon <output.iconset>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Draws the icon into a square context of `side` pixels (design grid: 1024).
func drawIcon(_ ctx: CGContext, side: CGFloat) {
    let s = side / 1024
    ctx.scaleBy(x: s, y: s)

    // Rounded-square tile (macOS grid: 824 pt body, 100 pt margins).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x111827))
    ctx.fillPath()
    ctx.restoreGState()

    // Night-sky gradient.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([color(0x312E81), color(0x1E1B4B), color(0x0B1026)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Glow behind the moon.
    ctx.drawRadialGradient(linearGradient([color(0x818CF8, 0.45), color(0x818CF8, 0)], [0, 1]),
                           startCenter: CGPoint(x: 660, y: 700), startRadius: 0,
                           endCenter: CGPoint(x: 660, y: 700), endRadius: 330, options: [])
    // Stars.
    let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (230, 780, 7, 0.9), (330, 690, 4, 0.7), (420, 830, 5, 0.8), (800, 520, 4, 0.6), (250, 600, 3, 0.5),
        (530, 760, 3, 0.6), (850, 820, 5, 0.75), (180, 470, 3, 0.4),
    ]
    for (x, y, r, a) in stars {
        ctx.setFillColor(color(0xFFFFFF, a))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }

    // Crescent moon: a disc with an offset disc erased, composited in a transparency layer so the glow (shadow)
    // follows the crescent's outline instead of leaving a visible hole where the cut-out disc was.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0xFDE68A, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.setFillColor(color(0xFDE68A))
    ctx.fillEllipse(in: CGRect(x: 545, y: 585, width: 230, height: 230))
    ctx.setBlendMode(.destinationOut)
    ctx.setFillColor(color(0x000000))
    ctx.fillEllipse(in: CGRect(x: 612, y: 640, width: 200, height: 200))
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Closed laptop seen slightly from above: lid (trapezoid) + base edge + front notch + status light.
    let lid = CGMutablePath()
    lid.move(to: CGPoint(x: 268, y: 470))
    lid.addLine(to: CGPoint(x: 756, y: 470))
    lid.addLine(to: CGPoint(x: 822, y: 270))
    lid.addLine(to: CGPoint(x: 202, y: 270))
    lid.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.45))
    ctx.addPath(lid)
    ctx.setFillColor(color(0xCBD5E1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(lid)
    ctx.clip()
    ctx.drawLinearGradient(linearGradient([color(0xF1F5F9), color(0xCBD5E1), color(0x94A3B8)], [0, 0.6, 1]),
                           start: CGPoint(x: 512, y: 470), end: CGPoint(x: 512, y: 270), options: [])
    // Subtle highlight along the back edge.
    ctx.setStrokeColor(color(0xFFFFFF, 0.7))
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: 272, y: 466))
    ctx.addLine(to: CGPoint(x: 752, y: 466))
    ctx.strokePath()
    ctx.restoreGState()

    // Base edge.
    let base = CGPath(roundedRect: CGRect(x: 192, y: 238, width: 640, height: 34), cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.addPath(base)
    ctx.setFillColor(color(0x64748B))
    ctx.fillPath()
    let notch = CGPath(roundedRect: CGRect(x: 452, y: 258, width: 120, height: 14), cornerWidth: 7, cornerHeight: 7, transform: nil)
    ctx.addPath(notch)
    ctx.setFillColor(color(0x475569))
    ctx.fillPath()

    // The status light: still on (agents keep working).
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: color(0x34D399, 0.95))
    ctx.setFillColor(color(0x34D399))
    ctx.fillEllipse(in: CGRect(x: 744, y: 245, width: 20, height: 20))
    ctx.restoreGState()

    ctx.restoreGState()
}

func writePNG(side: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawIcon(ctx, side: CGFloat(side))
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "make-icon", code: 3) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasSuffix(".iconset") else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset>\n".utf8))
    exit(2)
}
let iconset = URL(filePath: arguments[1], directoryHint: .isDirectory)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(side: base, to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try writePNG(side: base * 2, to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
print("wrote \(iconset.path(percentEncoded: false))")
