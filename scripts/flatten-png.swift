// flatten-png — rewrites a PNG without an alpha channel (any transparent pixel becomes the bone paper colour).
// App Store Connect rejects iOS app icons that carry alpha, so scripts/make-icon.sh runs the rendered iOS icon
// through this. With a size, the image is centred on a square paper tile of that many pixels (12 % margin): the
// pose thumbnails of the iPhone alerts. Pure drawing: no network, no system changes.
//
// Usage: xcrun swiftc -O -swift-version 6 scripts/flatten-png.swift -o <tmp>/flatten
//        <tmp>/flatten <in.png> <out.png> [square-px]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 || (arguments.count == 4 && Int(arguments[3]).map { $0 > 0 } == true) else {
    FileHandle.standardError.write(Data("usage: flatten-png <in.png> <out.png> [square-px]\n".utf8))
    exit(2)
}
let square = arguments.count == 4 ? Int(arguments[3]) : nil
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("flatten-png: cannot read \(arguments[1])\n".utf8))
    exit(1)
}
// An RGB context WITHOUT alpha: the output is opaque by construction.
let width = square ?? image.width
let height = square ?? image.height
guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let bounds = CGRect(x: 0, y: 0, width: width, height: height)
context.setFillColor(CGColor(srgbRed: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEC / 255, alpha: 1)) // bone
context.fill(bounds)
context.interpolationQuality = .high
var target = bounds
if let square {
    let side = CGFloat(square) * 0.76
    let scale = min(side / CGFloat(image.width), side / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    target = CGRect(x: (CGFloat(square) - size.width) / 2, y: (CGFloat(square) - size.height) / 2,
                    width: size.width, height: size.height)
}
context.draw(image, in: target)
guard let flattened = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[2]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, flattened, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
