import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Apple TV doesn't expose UIActivityViewController / ShareLink. Instead
/// we render a QR code the user can scan with their phone — same idea
/// as how Plex / Apple Music handle "share what's on screen".
struct ShareSheet: View {
    let stationTitle: String
    let url: URL
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Text("Distribuie postul")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                Text(stationTitle)
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.textSecondary)

                qrCode
                    .frame(width: 360, height: 360)
                    .padding(Theme.Spacing.lg)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))

                Text(url.absoluteString)
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                Text("Scanează codul cu telefonul pentru a deschide linkul")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)

                Button(action: onDismiss) {
                    // The default `.card` button label has very little
                    // internal padding around a short string, so the
                    // focused capsule looked cramped. A larger label
                    // also reads better at 10ft viewing distance.
                    Text("Închide")
                        .font(.system(size: 26, weight: .semibold))
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.sm)
                }
                .buttonStyle(.card)
                .focused($closeFocused)
                .padding(.top, Theme.Spacing.md)
            }
            .padding(Theme.Spacing.xxl)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 28))
            .shadow(radius: 40)
        }
        // Autofocus the dismiss control — the QR is the entire payload,
        // so the only thing the user needs to do is close the sheet.
        .defaultFocus($closeFocused, true)
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private var qrCode: some View {
        if let image = generateQR(from: url.absoluteString) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Color.gray
        }
    }

    private func generateQR(from string: String) -> UIImage? {
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
