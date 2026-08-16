import SwiftUI

/// "Contact us" modal. Apple TV can't run WhatsApp, so — exactly like the
/// iPhone and Android TV apps — we render a QR code that opens WhatsApp on
/// the user's phone prefilled with the app version and device identity
/// (see `lib/tv/pages/tv_settings.dart` and `quick_actions_service.dart`).
struct ContactSheet: View {
    /// Diagnostics folded into the prefilled WhatsApp message. Defaults to
    /// the plain "no known failure" form used by Settings.
    var diagnostics: ContactLinks.Diagnostics = .init()
    let onDismiss: () -> Void

    @FocusState private var closeFocused: Bool

    private static let phoneDisplay = ContactLinks.whatsAppDisplayNumber
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
                            + "direct pe WhatsApp. Mesajul conține deja "
                            + "detaliile postului și ale dispozitivului.")
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

                TVPillButton(title: "Închide", action: onDismiss)
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
        if let url = ContactLinks.whatsAppURL(diagnostics) {
            QRCodeView(string: url.absoluteString)
        } else {
            Color.gray
        }
    }

}
