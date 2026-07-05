import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Renders a scannable QR code for an arbitrary string.
///
/// Apple TV has no browser or share sheet, so QR codes are how we hand a
/// URL to the user's phone. Shared by `ShareSheet` and `ContactSheet` so
/// the CoreImage plumbing lives in exactly one place.
struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.generate(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    /// Builds a high-contrast QR `UIImage`, scaled up so it stays sharp at
    /// 10-foot viewing distance. Returns `nil` if CoreImage can't render.
    static func generate(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Scale up so the QR code is sharp at the displayed size.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }
}
