import SwiftUI

/// Top-level app surface. Apple TV apps consistently use top-tab `TabView`
/// (Apple Music / TV+ / Disney+) — using it here means the focus engine
/// handles D-pad traversal between tabs for free, and users get the same
/// muscle memory they have with first-party apps.
///
/// Opening a station presents Now Playing as a full-screen cover over the
/// tabs. The TabView stays alive underneath, so Menu returns to the same
/// grid, scrolled where it was, with focus on the card that was opened.
/// Swapping the whole root lost both; an overlay left the TabView in the
/// focus hierarchy, so Menu at the tab bar exited the app before Now
/// Playing's `onExitCommand` could fire. A modal takes the tabs out of
/// the focus hierarchy while it is up.
///
/// It does not observe the audio engine (`playback.player`, which only
/// Now Playing observes): the tabs stay mounted under the cover, and every
/// change of the engine would otherwise rebuild all three station grids.
struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var playback = PlaybackCoordinator()

    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Tab = .stations
    @State private var isNowPlayingPresented = false

    /// The card Now Playing was opened from, to give focus back to it.
    @State private var openedCard: OpenedCard?
    @State private var focusRequest: TabFocusRequest?

    /// Set when the scene goes to the background, so a return to the
    /// foreground is told apart from closing Control Center (`.inactive`).
    @State private var wasInBackground = false

    enum Tab: Hashable {
        case stations, favorites, recents, settings
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(
            isPresented: $isNowPlayingPresented,
            onDismiss: restoreGridFocus
        ) {
            NowPlayingScreen(
                appState: appState,
                player: playback.player,
                playback: playback,
                onBack: { isNowPlayingPresented = false }
            )
        }
        .task {
            playback.start(appState: appState)
            await appState.loadStations()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .onChange(of: selectedTab) { _, tab in
            // A natural boundary: the tab coming into view is ranked
            // again before it shows.
            if let list = tab.stationList {
                appState.refreshOrder(of: list)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if appState.stations.isEmpty && appState.isLoading {
            LoadingState()
        } else if let error = appState.loadError, appState.stations.isEmpty {
            ErrorState(message: error) {
                Task { await appState.loadStations() }
            }
        } else {
            tabbedShell
        }
    }

    // MARK: - Tabs

    private var tabbedShell: some View {
        TabView(selection: $selectedTab) {
            stationTab(.stations, list: .all, title: appState.sortOption.label)
            stationTab(.favorites, list: .favorites, title: "Favorite")
            stationTab(.recents, list: .recents, title: "Recente")
            SettingsView(appState: appState)
                .tabItem { Label("Setări", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.primary)
        // Siri Remote Play/Pause anywhere on the tabs toggles the current
        // station. Now Playing is modal, so it never fires together with
        // the handler there.
        .onPlayPauseCommand { playback.togglePlayback() }
    }

    private func stationTab(
        _ tab: Tab,
        list: StationList,
        title: String
    ) -> some View {
        let stations = appState.displayedStations(in: list)
        return StationGrid(
            title: title,
            subtitle: Self.stationCount(stations.count),
            stations: stations,
            appState: appState,
            onSelect: { open($0, from: stations, in: tab) },
            emptyTitle: tab.emptyTitle,
            emptySystemImage: tab.systemImage,
            emptyMessage: tab.emptyMessage,
            focusRequest: focusRequest?.tab == tab ? focusRequest?.request : nil
        )
        .tabItem { Label(tab.label, systemImage: tab.systemImage) }
        .tag(tab)
    }

    // MARK: - Navigation

    /// Plays `station` and opens Now Playing. `stations` is the grid as it
    /// was shown: previous / next walk that order.
    private func open(_ station: Station, from stations: [Station], in tab: Tab) {
        openedCard = OpenedCard(
            tab: tab,
            stationId: station.id,
            index: stations.firstIndex { $0.id == station.id } ?? 0
        )
        appState.selectStation(station, browsingOrder: stations.map(\.id))
        isNowPlayingPresented = true
    }

    private func restoreGridFocus() {
        guard let opened = openedCard,
              let list = opened.tab.stationList
        else { return }
        let ids = appState.displayedStations(in: list).map(\.id)
        guard let target = StationOrder.focusTarget(
            openedId: opened.stationId,
            openedIndex: opened.index,
            in: ids
        ) else { return }
        focusRequest = TabFocusRequest(
            tab: opened.tab,
            request: GridFocusRequest(stationId: target)
        )
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            wasInBackground = true
        case .active where wasInBackground:
            wasInBackground = false
            Task { await appState.onAppResumed() }
        default:
            break
        }
    }

    /// "1 post", "12 posturi", "64 de posturi": Romanian puts "de" after
    /// numbers from 20 up whose last two digits are not 01–19.
    static func stationCount(_ count: Int) -> String {
        if count == 1 { return "1 post" }
        let lastTwo = count % 100
        let takesDe = count >= 20 && (lastTwo == 0 || lastTwo >= 20)
        return takesDe ? "\(count) de posturi" : "\(count) posturi"
    }
}

// MARK: - Tab copy

private extension RootView.Tab {
    var stationList: StationList? {
        switch self {
        case .stations: return .all
        case .favorites: return .favorites
        case .recents: return .recents
        case .settings: return nil
        }
    }

    var label: String {
        switch self {
        case .stations: return "Posturi"
        case .favorites: return "Favorite"
        case .recents: return "Recente"
        case .settings: return "Setări"
        }
    }

    var systemImage: String {
        switch self {
        case .stations: return "radio"
        case .favorites: return "heart"
        case .recents: return "clock"
        case .settings: return "gearshape"
        }
    }

    var emptyTitle: String {
        switch self {
        case .stations: return "Nu sunt posturi"
        case .favorites: return "Nu ai posturi favorite"
        case .recents: return "Nicio redare recentă"
        case .settings: return ""
        }
    }

    var emptyMessage: String {
        switch self {
        case .stations: return ""
        case .favorites: return "Adaugă posturi la favorite din Acum Redă"
        case .recents: return "Posturile redate apar aici"
        case .settings: return ""
        }
    }
}

// MARK: - Focus bookkeeping

private struct OpenedCard {
    let tab: RootView.Tab
    let stationId: Int
    /// Position in the grid when opened: the card now in that place takes
    /// focus if the opened one left the list.
    let index: Int
}

private struct TabFocusRequest: Equatable {
    let tab: RootView.Tab
    let request: GridFocusRequest
}

// MARK: - Now Playing cover

/// Now Playing for the current station, inside the full-screen cover. It
/// follows `AppState.currentStation`, so previous / next — on screen or
/// from the remote — move it to the new station without presenting again.
private struct NowPlayingScreen: View {
    @ObservedObject var appState: AppState
    @ObservedObject var player: AudioPlayer
    let playback: PlaybackCoordinator
    let onBack: () -> Void

    var body: some View {
        Group {
            if let station = appState.currentStation {
                NowPlayingView(
                    station: station,
                    isFavorite: appState.isFavorite(station),
                    player: player,
                    songHistory: appState.songHistory,
                    onBack: onBack,
                    onToggleFavorite: { appState.toggleFavorite(station) },
                    onPrev: { playback.skip(by: -1) },
                    onNext: { playback.skip(by: 1) }
                )
                // The video layout handles Play/Pause itself (it also
                // brings its controls back); a handler here as well would
                // toggle twice.
                .onPlayPauseCommand(
                    perform: player.isVideoContent
                        ? nil
                        : { playback.togglePlayback() }
                )
            } else {
                Theme.background
                    .ignoresSafeArea()
                    .onExitCommand(perform: onBack)
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Loading and error

private struct LoadingState: View {
    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.primary)
            Text("Se încarcă posturile…")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct ErrorState: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.yellow)
            Text("Nu am putut încărca posturile")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(.system(size: 22))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxl)
            Button("Reîncearcă", action: onRetry)
                .buttonStyle(.card)
        }
    }
}

/// Brand mark — the official logo asset (pink rounded square with the
/// white fish from `logo_radio_crestin_com.svg`) plus the wordmark.
/// Sized to read clearly at 10ft viewing distance without competing
/// with the centered tab bar.
struct BrandMark: View {
    var body: some View {
        HStack(spacing: 14) {
            Image("BrandMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 48, height: 48)
            Text("Radio Crestin")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
