import SwiftUI

/// Reusable grid of station cards — used by the Stations, Favorite, and
/// Recente tabs. Each tab passes a different filtered list and a title.
struct StationGrid: View {
    let title: String
    let subtitle: String?
    let stations: [Station]
    let appState: AppState
    let onSelect: (Station) -> Void

    /// Empty-state copy when the filtered list has no entries.
    let emptyTitle: String
    let emptySystemImage: String
    let emptyMessage: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(Theme.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.bottom, Theme.Spacing.md)

                if stations.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var grid: some View {
        // 4 columns on a 16:9 TV @ 280px card + 280px artwork is tight
        // but legible. LazyVGrid handles offscreen cards efficiently.
        let columns = [GridItem](
            repeating: GridItem(.fixed(280), spacing: Theme.Spacing.lg),
            count: 4
        )
        return LazyVGrid(columns: columns, alignment: .leading,
                         spacing: Theme.Spacing.xl) {
            ForEach(stations) { station in
                StationCard(
                    station: station,
                    isPlaying: appState.currentStation?.id == station.id,
                    isFavorite: appState.isFavorite(station),
                    onSelect: { onSelect(station) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: emptySystemImage)
                .font(.system(size: 96))
                .foregroundStyle(Theme.textTertiary)
            Text(emptyTitle)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(emptyMessage)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}
