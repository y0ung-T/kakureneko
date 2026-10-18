// render — rasterizes an SVG into an sRGB PNG with alpha using AppKit's built-in SVG support (CoreSVG), so no
// third-party tool is needed. Used by scripts/make-icon.sh for the app icons and the menu bar template images.
// Pure drawing: no network, no system changes.
//
// Usage: xcrun swiftc -O -swift-version 6 render.swift -o <tmp>/render
//        <tmp>/render <in.svg> <width-px> <out.png>     (the height follows the SVG's aspect ratio)

import AppKit
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 4, let width = Int(arguments[2]), width > 0 else {
    FileHandle.standardError.write(Data("usage: render <in.svg> <width-px> <out.png>\n".utf8))
    exit(2)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])), image.size.width > 0 else {
    FileHandle.standardError.write(Data("render: cannot read \(arguments[1])\n".utf8))
    exit(1)
}
let height = max(1, Int((CGFloat(width) * image.size.height / image.size.width).rounded()))
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.interpolationQuality = .high
context.setAllowsAntialiasing(true)

NSGraphicsContext.saveGraphicsState()
let graphics = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = graphics
image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

guard let rendered = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[3]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("render: cannot write \(arguments[3])\n".utf8))
    exit(1)
}
