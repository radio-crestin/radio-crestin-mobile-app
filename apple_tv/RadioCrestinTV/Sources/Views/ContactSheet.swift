import SwiftUI

/// "Contact us" modal. Apple TV can't run WhatsApp, so — exactly like the
/// iPhone and Android TV apps — we render a QR code that opens WhatsApp on
/// the user's phone prefilled with the app version and device identity
/// (see `lib/tv/pages/tv_settings.dart` and `quick_actions_service.dart`).
struct ContactSheet: View {
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    private static let whatsappNumber = "40766338046"
    private static let phoneDisplay = "+40 766 338 046"
    /// WhatsApp brand green (#25D366) — same accent the Flutter apps use.
    private static let whatsappGreen = Color(red: 0.145, green: 0.827, blue: 0.4)

    var body: some View {
        ZStack {
            Color.black.opacity(0.85).ignoresSafeArea()
            VStack(spacing: Theme.Spacing.lg) {
                Text("Contactează-ne")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)

                HStack(alignment: .center, spacing: Theme.Spacing.xl) {
                    // QR must sit on white for reliable scanning.
                    qrCode
                        .frame(width: 320, height: 320)
                        .padding(Theme.Spacing.lg)
                        .background(.white, in: RoundedRectangle(cornerRadius: 24))

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "message.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Self.whatsappGreen)
                            Text("Contactează-ne pe WhatsApp")
                                .font(.system(size: 30, weight: .bold))
                                .foregroundStyle(Theme.textPrimary)
                        }

                        Text("Scanează codul QR cu telefonul pentru a ne scrie "
                            + "direct pe WhatsApp. Mesajul include automat "
                            + "versiunea aplicației.")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(Self.phoneDisplay)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.top, Theme.Spacing.sm)
                    }
                    .frame(maxWidth: 540, alignment: .leading)
                }

                Button(action: onDismiss) {
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
        // The QR is the entire payload, so autofocus the only control —
        // the dismiss button — mirroring `ShareSheet`. The explicit `.task`
        // is needed because the sheet is inserted via the parent's
        // `.overlay`; `.defaultFocus` alone doesn't reliably move focus, and
        // without focus inside this scope `onExitCommand` won't fire.
        .focusSection()
        .task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            closeFocused = true
        }
        .onExitCommand(perform: onDismiss)
    }

    @ViewBuilder
    private var qrCode: some View {
        if let url = Self.whatsappURL {
            QRCodeView(string: url.absoluteString)
        } else {
            Color.gray
        }
    }

    /// The same `wa.me` URL the mobile and Android TV apps build, with the
    /// platform set to "Apple TV". The prefilled message embeds the app
    /// version and the PostHog device identity so support can correlate a
    /// message with the device's analytics.
    private static var whatsappURL: URL? {
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let info = "[RadioCrestin/Apple TV/v\(version)/\(Analytics.distinctId)]"
        let message = "\(info)\n\nBuna ziua,\n"
        // Mirror Dart's `Uri.encodeComponent` / JS `encodeURIComponent`:
        // encode everything except the RFC 3986 unreserved + sub-delims set
        // it leaves alone, so spaces become %20 and newlines %0A.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let encoded = message.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        return URL(string: "https://wa.me/\(whatsappNumber)?text=\(encoded)")
    }
}
