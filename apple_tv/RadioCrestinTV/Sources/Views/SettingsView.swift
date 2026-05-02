import SwiftUI

/// Settings tab — version info and a couple of legal documents shown via
/// QR codes so users can read them on their phone (Apple TV has no
/// browser to open URLs into).
struct SettingsView: View {
    @ObservedObject var appState: AppState

    @State private var openLink: LegalLink?

    private struct LegalLink: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Setări")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, Theme.Spacing.md)

                aboutSection
                legalSection
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if let link = openLink {
                ShareSheet(
                    stationTitle: link.title,
                    url: link.url,
                    onDismiss: { openLink = nil }
                )
                .transition(.opacity)
            }
        }
    }

    // MARK: - Sections

    private var aboutSection: some View {
        section(title: "Despre aplicație", rows: [
            Row(icon: "radio", title: "Radio Crestin",
                subtitle: "Ascultă radiouri creștine din România",
                action: nil),
            Row(icon: "tv", title: "Platformă",
                subtitle: "Apple TV — tvOS",
                action: nil),
            Row(icon: "info.circle", title: "Versiune",
                subtitle: appVersionString,
                action: nil)
        ])
    }

    private var legalSection: some View {
        section(title: "Legal", rows: [
            Row(icon: "doc.text",
                title: "Termeni și condiții",
                subtitle: "Apasă pentru a deschide pe telefon",
                action: { openTerms() }),
            Row(icon: "lock.shield",
                title: "Politica de confidențialitate",
                subtitle: "Apasă pentru a deschide pe telefon",
                action: { openPrivacy() }),
            Row(icon: "globe",
                title: "Site web",
                subtitle: "www.radiocrestin.ro",
                action: { openWebsite() })
        ])
    }

    // MARK: - Row plumbing

    private struct Row: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
        let action: (() -> Void)?
    }

    @ViewBuilder
    private func section(title: String, rows: [Row]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, Theme.Spacing.xs)
            ForEach(rows) { row in
                // Every row is a focusable Button so the D-pad can move
                // through the whole page. Informational rows (no
                // `action`) still take focus — they just no-op on
                // select. Without this, focus could only land on the
                // Legal rows and the user couldn't traverse the page.
                Button(action: row.action ?? {}) {
                    rowContent(row)
                }
                .buttonStyle(.card)
            }
        }
    }

    private func rowContent(_ row: Row) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: row.icon)
                .font(.system(size: 30))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(row.subtitle)
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if row.action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceVariant,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    // MARK: - Actions

    private func openTerms() {
        guard let url = URL(string: "https://www.radiocrestin.ro/terms") else { return }
        openLink = LegalLink(id: "terms",
                             title: "Termeni și condiții",
                             url: url)
    }

    private func openPrivacy() {
        guard let url = URL(string: "https://www.radiocrestin.ro/privacy") else { return }
        openLink = LegalLink(id: "privacy",
                             title: "Politica de confidențialitate",
                             url: url)
    }

    private func openWebsite() {
        guard let url = URL(string: "https://www.radiocrestin.ro") else { return }
        openLink = LegalLink(id: "site",
                             title: "Radio Crestin",
                             url: url)
    }

    private var appVersionString: String {
        let bundle = Bundle.main
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
