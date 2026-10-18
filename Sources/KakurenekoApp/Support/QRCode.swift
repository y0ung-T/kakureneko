// QR codes (onboarding: the Kakureneko iPhone app's App Store link, scanned with the iPhone camera; links in
// AppLinks.swift). QR codes are rendered locally with CoreImage's `CIQRCodeGenerator`; nothing leaves the Mac.

import CoreImage
import CoreImage.CIFilterBuiltins
import KakurenekoKit
import Foundation

nonisolated enum QRCode {
    /// A crisp black-on-white QR code whose modules are whole pixels, at least `minimumPixels` wide
    /// (correction level M, quiet zone included). nil for empty text or if CoreImage fails.
    static func image(for text: String, minimumPixels: Int = 256) -> CGImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let side = max(1, output.extent.width)
        let scale = max(1, (CGFloat(minimumPixels) / side).rounded(.up))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        return context.createCGImage(scaled, from: scaled.extent.integral)
    }
}
