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

    /// Moves focus to one card, e.g. the card Now Playing was opened from
    /// once it closes.
    let focusRequest: GridFocusRequest?

    /// The card the click-and-hold menu took out of the grid (a station
    /// removed from Favorite), kept in its place until the menu has
    /// closed. Removed at once, it left the menu nothing to give focus
    /// back to, and no card showed focus.
    @State private var leavingCard: LeavingCard?

    /// The latest request to move focus: `focusRequest`, or the one that
    /// hands focus from `leavingCard` to the card taking its place.
    @State private var cardFocus: GridFocusRequest?

    init(
        title: String,
        subtitle: String?,
        stations: [Station],
        appState: AppState,
        onSelect: @escaping (Station) -> Void,
        emptyTitle: String,
        emptySystemImage: String,
        emptyMessage: String,
        focusRequest: GridFocusRequest? = nil,
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
        self.focusRequest = focusRequest
        self.trailingHeader = trailingHeader
    }

    var body: some View {
        let shown = shownStations
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

                if shown.isEmpty {
                    emptyState
                } else {
                    grid(of: shown)
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: focusRequest) { _, request in
            cardFocus = request
        }
    }

    private func grid(of shown: [Station]) -> some View {
        // Adaptive columns: SwiftUI fits as many cells as the available
        // width allows, each at least 240pt wide and stretched to equal
        // width — so the grid uses the entire screen width on any TV
        // resolution rather than parking blank space on the right.
        let columns = [
            GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.lg)
        ]
        return LazyVGrid(columns: columns, alignment: .leading,
                         spacing: Theme.Spacing.xl) {
            ForEach(shown) { station in
                let isFavorite = appState.isFavorite(station)
                StationCard(
                    station: station,
                    playback: .init(
                        isCurrent: appState.currentStation?.id == station.id,
                        isPaused: appState.isPlaybackPaused
                    ),
                    isFavorite: isFavorite,
                    onSelect: { onSelect(station) }
                )
                .modifier(FocusOnRequest(
                    stationId: station.id,
                    request: cardFocus,
                    onFocus: {
                        cardDidTakeFocus(station)
                        appState.stationCardFocused(station)
                    }
                ))
                // Click and hold, as in Apple's apps: the station joins or
                // leaves the favorites without tuning to it, so what plays
                // goes on.
                .contextMenu {
                    Button {
                        toggleFavorite(station)
                    } label: {
                        Label(
                            isFavorite
                                ? "Elimină din favorite"
                                : "Adaugă la favorite",
                            systemImage: isFavorite ? "heart.slash" : "heart"
                        )
                    }
                }
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

    // MARK: - A card leaving the grid

    /// `stations`, with the card leaving the grid still in its place.
    private var shownStations: [Station] {
        guard let leavingCard,
              !stations.contains(where: { $0.id == leavingCard.station.id })
        else { return stations }
        var shown = stations
        shown.insert(
            leavingCard.station,
            at: min(leavingCard.index, shown.count)
        )
        return shown
    }

    private func toggleFavorite(_ station: Station) {
        leavingCard = stations.firstIndex { $0.id == station.id }
            .map { LeavingCard(station: station, index: $0) }
        appState.toggleFavorite(station)
    }

    /// A card took focus: the menu has closed and given it back to the
    /// card it opened from, or the listener moved on. A card leaving the
    /// grid goes now; when it is the one holding focus, the card taking
    /// its place gets focus, as when Now Playing closes.
    private func cardDidTakeFocus(_ station: Station) {
        guard let leaving = leavingCard else { return }
        leavingCard = nil
        guard leaving.station.id == station.id,
              !stations.contains(where: { $0.id == station.id }),
              let target = StationOrder.focusTarget(
                  openedId: station.id,
                  openedIndex: leaving.index,
                  in: stations.map(\.id)
              )
        else { return }
        cardFocus = GridFocusRequest(stationId: target)
    }
}

/// A card on its way out of a `StationGrid`, and its place there.
private struct LeavingCard {
    let station: Station
    let index: Int
}

/// A request to move focus to one card of a `StationGrid`. Every request
/// is distinct, even for the same card, so asking again moves focus again.
struct GridFocusRequest: Equatable {
    let stationId: Int
    private let token = UUID()

    init(stationId: Int) {
        self.stationId = stationId
    }
}

/// Gives a card focus when a request names it, and reports when it takes
/// focus.
///
/// tvOS normally gives focus back to the card that was focused when a
/// full-screen cover closes; this makes sure of it (and covers the card
/// that took the place of one that left the list). Each card tracks only
/// its own focus, so moving focus redraws two cards, not the whole grid.
private struct FocusOnRequest: ViewModifier {
    let stationId: Int
    let request: GridFocusRequest?
    let onFocus: () -> Void

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: request) { _, request in
                if request?.stationId == stationId {
                    isFocused = true
                }
            }
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus() }
            }
    }
}
