import SwiftUI

/// Apple TV doesn't expose UIActivityViewController / ShareLink. Instead
/// we render a QR code the user can scan with their phone — same idea
/// as how Plex / Apple Music handle "share what's on screen".
struct ShareSheet: View {
    /// The sheet's title. Settings also opens web pages with it, which
    /// are not a station to share, under the name of their row.
    var heading = "Distribuie postul"
    /// The line under the title: the station's name. None for a page.
    var stationTitle: String?
    let url: URL
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Text(heading)
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                if let stationTitle {
                    Text(stationTitle)
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textSecondary)
                }

                QRCodeView(string: url.absoluteString)
                    .frame(width: 360, height: 360)
                    .padding(Theme.Spacing.lg)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityLabel("Cod QR pentru \(stationTitle ?? heading)")

                Text(url.absoluteString)
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    // A URL is no label: the accessibility audit flags it
                    // as not human-readable. It is the line's value, read
                    // without its scheme.
                    .accessibilityLabel("Adresa paginii")
                    .accessibilityValue(Self.spokenAddress(of: url))

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
            // One shadow for the whole sheet. Applied to each child, it
            // shaded the QR code's white plate grey around the code, the
            // part scanning needs white.
            .compositingGroup()
            .shadow(radius: 40)
        }
        // Autofocus the dismiss control — the QR is the entire payload,
        // so the only thing the user needs to do is close the sheet.
        // `.defaultFocus` alone wasn't reliable here because Now Playing
        // inserts the sheet conditionally via an overlay; focus stayed
        // on whatever control opened it. An explicit `.task` set on
        // `closeFocused` reliably transfers focus and makes
        // `onExitCommand` (which is scope-relative) actually fire when
        // the user presses Menu / ESC. Settings presents it in a
        // full-screen cover, where the button is the only focusable view.
        .focusSection()
        .task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            closeFocused = true
        }
        .onExitCommand(perform: onDismiss)
    }

    /// `url` as VoiceOver reads it: without "https://", which it would
    /// spell out letter by letter.
    static func spokenAddress(of url: URL) -> String {
        let address = url.absoluteString
        guard let scheme = url.scheme, address.hasPrefix(scheme + "://")
        else { return address }
        return String(address.dropFirst(scheme.count + 3))
    }
}
