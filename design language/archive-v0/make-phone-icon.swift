// Draws the iPhone app icon: the same artwork as the Mac icon (scripts/make-icon.swift — a closed laptop under a
// crescent moon, its status light still on), but full-bleed and fully opaque, because iOS applies its own mask and
// App Store Connect rejects icons with transparency. Writes one 1024×1024 PNG (iOS single-size app icon).
// Pure drawing: no network, no system changes. Kept separate from make-icon.swift so the Mac icon stays untouched;
// change the artwork in both files together.
//
// Usage: xcrun swiftc -O -swift-version 6 scripts/make-phone-icon.swift -o <tmp>/make-phone-icon \
//          && <tmp>/make-phone-icon iPhone/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png

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

/// Draws the icon into a square, opaque context of `side` pixels (design grid: 1024, same coordinates as the Mac
/// icon's 824-pt tile, scaled up around the centre so the scene fills the canvas).
func drawIcon(_ ctx: CGContext, side: CGFloat) {
    ctx.scaleBy(x: side / 1024, y: side / 1024)

    // Night sky across the whole canvas (no tile, no shadow: iOS masks the corners itself).
    ctx.drawLinearGradient(linearGradient([color(0x312E81), color(0x1E1B4B), color(0x0B1026)], [0, 0.55, 1]),
                           start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])

    // The Mac artwork, enlarged so it keeps the same proportions inside iOS's rounded mask.
    let zoom: CGFloat = 1.18
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: zoom, y: zoom)
    ctx.translateBy(x: -512, y: -512)

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

    // Crescent moon: a disc with an offset disc erased, composited in a transparency layer so the glow follows the
    // crescent's outline.
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
    ctx.setStrokeColor(color(0xFFFFFF, 0.7))
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: 272, y: 466))
    ctx.addLine(to: CGPoint(x: 752, y: 466))
    ctx.strokePath()
    ctx.restoreGState()

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
}

/// Renders into an RGB context WITHOUT an alpha channel, so the PNG is opaque by construction.
func writePNG(side: Int, to url: URL) throws {
    guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw NSError(domain: "make-phone-icon", code: 1)
    }
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    drawIcon(ctx, side: CGFloat(side))
    guard let image = ctx.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-phone-icon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "make-phone-icon", code: 3) }
}

let arguments = CommandLine.arguments
guard arguments.count == 2, arguments[1].hasSuffix(".png") else {
    FileHandle.standardError.write(Data("usage: make-phone-icon <output.png>\n".utf8))
    exit(2)
}
let output = URL(filePath: arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try writePNG(side: 1024, to: output)
print("wrote \(output.path(percentEncoded: false))")
