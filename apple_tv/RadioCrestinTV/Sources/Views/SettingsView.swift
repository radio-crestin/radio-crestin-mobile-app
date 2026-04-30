import SwiftUI

/// Settings tab — version, platform, links. Mirrors the Android TV
/// Setări page in scope; we add a single action (Reload stations) since
/// tvOS users can't pull-to-refresh.
struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text("Setări")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, Theme.Spacing.md)

                section(title: "Despre", items: [
                    Item(icon: "info.circle",
                         title: "Versiune",
                         subtitle: appVersionString),
                    Item(icon: "tv",
                         title: "Platformă",
                         subtitle: "Apple TV"),
                    Item(icon: "radio",
                         title: "Radio Crestin",
                         subtitle: "Ascultă radiouri creștine din România")
                ])

                actionButton

                section(title: "Legal", items: [
                    Item(icon: "doc.text",
                         title: "Termeni și Condiții",
                         subtitle: "radiocrestin.ro/terms"),
                    Item(icon: "lock.shield",
                         title: "Politica de Confidențialitate",
                         subtitle: "radiocrestin.ro/privacy")
                ])
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionButton: some View {
        Button {
            Task { await appState.loadStations() }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "arrow.clockwise")
                Text("Reîncarcă posturile")
            }
            .font(.system(size: 24, weight: .semibold))
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
        .buttonStyle(.card)
        .padding(.vertical, Theme.Spacing.md)
    }

    private struct Item {
        let icon: String
        let title: String
        let subtitle: String
    }

    @ViewBuilder
    private func section(title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, Theme.Spacing.lg)
            ForEach(items, id: \.title) { row in
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: row.icon)
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.title)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text(row.subtitle)
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .padding(Theme.Spacing.md)
                .background(Theme.surfaceVariant,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
    }

    private var appVersionString: String {
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
