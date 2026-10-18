// Emits the Kakureneko wordmark as SVG path data, using CoreText outlines of a font file (Manrope, OFL).
// Usage: swift wordmark.swift <font.ttf> <text> <weight 100-900> <out.svg> [tracking]
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 5 else { FileHandle.standardError.write(Data("usage: wordmark <font> <text> <weight> <out.svg> [tracking]\n".utf8)); exit(2) }
let fontURL = URL(fileURLWithPath: args[1]), text = args[2], weight = Double(args[3]) ?? 700, outURL = URL(fileURLWithPath: args[4])
let tracking = args.count > 5 ? Double(args[5]) ?? 0 : 0

guard let data = try? Data(contentsOf: fontURL), let descriptor = CTFontManagerCreateFontDescriptorFromData(data as CFData) else {
    FileHandle.standardError.write(Data("cannot load font\n".utf8)); exit(1)
}
// Variable font: set the weight axis (and the width axis to its default 100).
var variation: [CFNumber: CFNumber] = [:]
let base = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
if let axes = CTFontCopyVariationAxes(base) as? [[String: Any]] {
    for axis in axes {
        guard let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
              let name = axis[kCTFontVariationAxisNameKey as String] as? String else { continue }
        if name.lowercased().contains("weight") { variation[id] = weight as CFNumber }
        if name.lowercased().contains("width") { variation[id] = 100 as CFNumber }
    }
}
let varied = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: variation] as CFDictionary)
let font = CTFontCreateWithFontDescriptor(varied, 100, nil) // 100 units per em-ish size for tidy numbers

// Lay out the string: glyphs + advances (kerning on).
let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
let line = CTLineCreateWithAttributedString(attributed)
let runs = CTLineGetGlyphRuns(line) as! [CTRun]
var svgPaths: [String] = []
var penX: CGFloat = 0
var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude

func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

for run in runs {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRangeMake(0, 0), &glyphs)
    CTRunGetPositions(run, CFRangeMake(0, 0), &positions)
    for i in 0..<count {
        let x = positions[i].x + CGFloat(i) * tracking + penX
        guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
        var d = ""
        path.applyWithBlock { element in
            let p = element.pointee.points
            // Flip y (SVG y-down) and offset by the pen position.
            func P(_ pt: CGPoint) -> String { "\(fmt(pt.x + x)) \(fmt(-pt.y))" }
            func track(_ pt: CGPoint) {
                minX = min(minX, pt.x + x); maxX = max(maxX, pt.x + x); minY = min(minY, -pt.y); maxY = max(maxY, -pt.y)
            }
            switch element.pointee.type {
            case .moveToPoint: d += "M\(P(p[0])) "; track(p[0])
            case .addLineToPoint: d += "L\(P(p[0])) "; track(p[0])
            case .addQuadCurveToPoint: d += "Q\(P(p[0])) \(P(p[1])) "; track(p[0]); track(p[1])
            case .addCurveToPoint: d += "C\(P(p[0])) \(P(p[1])) \(P(p[2])) "; track(p[0]); track(p[1]); track(p[2])
            case .closeSubpath: d += "Z "
            @unknown default: break
            }
        }
        svgPaths.append(d)
    }
    penX += CTRunGetTypographicBounds(run, CFRangeMake(0, 0), nil, nil, nil) + CGFloat(count) * tracking
}
let pad: CGFloat = 4
let w = maxX - minX + 2 * pad, h = maxY - minY + 2 * pad
let d = svgPaths.joined()
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="\(fmt(minX - pad)) \(fmt(minY - pad)) \(fmt(w)) \(fmt(h))" width="\(fmt(w))" height="\(fmt(h))">
  <path d="\(d)" fill="#121212"/>
</svg>

"""
try! svg.write(to: outURL, atomically: true, encoding: .utf8)
print("wrote \(outURL.path) (\(fmt(w)) x \(fmt(h)))")
