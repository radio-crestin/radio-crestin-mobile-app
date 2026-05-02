import SwiftUI

/// Reusable grid of station cards — used by the Stations, Favorite, and
/// Recente tabs. Each tab passes a different filtered list and a title.
struct StationGrid<TrailingHeader: View>: View {
    let title: String
    let subtitle: String?
    let stations: [Station]
    let appState: AppState
    let onSelect: (Station) -> Void

    /// Empty-state copy when the filtered list has no entries.
    let emptyTitle: String
    let emptySystemImage: String
    let emptyMessage: String

    /// Optional view shown to the right of the title (e.g. a sort picker).
    let trailingHeader: () -> TrailingHeader

    init(
        title: String,
        subtitle: String?,
        stations: [Station],
        appState: AppState,
        onSelect: @escaping (Station) -> Void,
        emptyTitle: String,
        emptySystemImage: String,
        emptyMessage: String,
        @ViewBuilder trailingHeader: @escaping () -> TrailingHeader = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.stations = stations
        self.appState = appState
        self.onSelect = onSelect
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyMessage = emptyMessage
        self.trailingHeader = trailingHeader
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .lastTextBaseline) {
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
                    Spacer()
                    trailingHeader()
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
        // Adaptive columns: SwiftUI fits as many cells as the available
        // width allows, each at least 240pt wide and stretched to equal
        // width — so the grid uses the entire screen width on any TV
        // resolution rather than parking blank space on the right.
        let columns = [
            GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.lg)
        ]
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
