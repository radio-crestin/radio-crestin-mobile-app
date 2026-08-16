import SwiftUI

/// Resolves which card a station grid should hand focus to.
///
/// Kept as a free function (rather than inline in the view) so the rule
/// is unit-testable: the focus engine's own memory wins, and we only
/// fall back to the first card of the frozen display order when there
/// is nothing to restore.
enum StationGridFocus {

    /// Card the grid marks as its preferred default focus target.
    ///
    /// - Parameters:
    ///   - lastFocusedId: station the user focused in this grid earlier
    ///     in the session, or `nil` if they never did.
    ///   - stations: the grid's stations, in display order.
    /// - Returns: `lastFocusedId` when that station is still in the list,
    ///   otherwise the first station — `nil` only for an empty grid.
    static func defaultTargetId(
        lastFocusedId: Int?,
        stations: [Station]
    ) -> Int? {
        if let lastFocusedId,
           stations.contains(where: { $0.id == lastFocusedId }) {
            return lastFocusedId
        }
        return stations.first?.id
    }
}

/// Reusable grid of station cards — used by the Stations, Favorite, and
/// Recente tabs. Each tab passes a different filtered list and a title.
struct StationGrid<TrailingHeader: View>: View {
    let title: String
    let subtitle: String?
    let stations: [Station]
    let appState: AppState
    let onSelect: (Station) -> Void

    /// Id of the station currently tuning in, if any. Drives the inline
    /// spinner on that one card.
    var connectingStationId: Int?

    /// Empty-state copy when the filtered list has no entries.
    let emptyTitle: String
    let emptySystemImage: String
    let emptyMessage: String

    /// Station the user last focused in *this* grid during the session.
    ///
    /// Owned by the parent because `TabView` tears a tab's content down
    /// when the user moves away, which would reset any `@State` kept
    /// here and make every return look like a first entry.
    @Binding var lastFocusedStationId: Int?

    /// Whether this grid seats focus on its first card when it appears,
    /// pulling focus off the tab bar. Only the launch tab does this — on
    /// the other tabs the user is still traversing the tab bar, so
    /// stealing focus would trap them; there, `prefersDefaultFocus`
    /// handles the hand-off when focus moves down into the grid.
    var seatsFocusOnAppear: Bool = false

    /// Optional view shown to the right of the title (e.g. a sort picker).
    let trailingHeader: () -> TrailingHeader

    /// Scope the cards live in, so the first one can declare itself the
    /// preferred landing spot when focus enters from the tab bar.
    @Namespace private var gridScope

    /// Programmatic focus binding. Mirrors the pattern `NowPlayingView`
    /// already uses: `prefersDefaultFocus(_:in:)` describes intent, an
    /// explicit `FocusState` write deterministically seats focus.
    @FocusState private var focusedStationId: Int?

    init(
        title: String,
        subtitle: String?,
        stations: [Station],
        appState: AppState,
        onSelect: @escaping (Station) -> Void,
        connectingStationId: Int? = nil,
        emptyTitle: String,
        emptySystemImage: String,
        emptyMessage: String,
        lastFocusedStationId: Binding<Int?> = .constant(nil),
        seatsFocusOnAppear: Bool = false,
        @ViewBuilder trailingHeader: @escaping () -> TrailingHeader = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.stations = stations
        self.appState = appState
        self.onSelect = onSelect
        self.connectingStationId = connectingStationId
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyMessage = emptyMessage
        self._lastFocusedStationId = lastFocusedStationId
        self.seatsFocusOnAppear = seatsFocusOnAppear
        self.trailingHeader = trailingHeader
    }

    /// Card the focus engine should prefer when focus enters the grid.
    private var defaultFocusTargetId: Int? {
        StationGridFocus.defaultTargetId(
            lastFocusedId: lastFocusedStationId,
            stations: stations
        )
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
        // Remember every card the user lands on, so coming back to this
        // tab restores it instead of snapping to the top-left again.
        // `focusedStationId` goes nil when focus leaves the grid; only
        // real landings are recorded.
        .onChange(of: focusedStationId) { _, newValue in
            if let newValue { lastFocusedStationId = newValue }
        }
        // Launch tab only: seat focus on the first card once the stations
        // have arrived, so the app opens on content rather than leaving
        // the focus engine to pick a card on the first scroll. Re-runs if
        // the first station changes (list loaded after this view
        // appeared), and never fires once the user has focused a card.
        .task(id: stations.first?.id) {
            guard seatsFocusOnAppear,
                  lastFocusedStationId == nil,
                  let firstId = stations.first?.id
            else { return }
            // Yield once so the focus engine has registered the cards
            // before we ask one of them to take focus.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled, lastFocusedStationId == nil else { return }
            focusedStationId = firstId
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
        let defaultTargetId = defaultFocusTargetId
        return LazyVGrid(columns: columns, alignment: .leading,
                         spacing: Theme.Spacing.xl) {
            ForEach(stations) { station in
                StationCard(
                    station: station,
                    isPlaying: appState.currentStation?.id == station.id,
                    isFavorite: appState.isFavorite(station),
                    isConnecting: connectingStationId == station.id,
                    onSelect: { onSelect(station) }
                )
                .focused($focusedStationId, equals: station.id)
                // Where focus lands when it moves down from the tab bar:
                // the remembered card, else the first of the frozen
                // display order (top-left) — never wherever the focus
                // engine's geometry search happens to prefer.
                .prefersDefaultFocus(
                    station.id == defaultTargetId, in: gridScope
                )
            }
        }
        .focusScope(gridScope)
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
