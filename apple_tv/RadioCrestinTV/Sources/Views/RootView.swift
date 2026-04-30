import SwiftUI

/// Top-level app surface. Apple TV apps consistently use top-tab `TabView`
/// (Apple Music / TV+ / Disney+) — using it here means the focus engine
/// handles D-pad traversal between tabs for free, and users get the same
/// muscle memory they have with first-party apps.
///
/// Selecting a station from any tab pushes Now Playing onto a stack so
/// the menu / back button on the Siri Remote returns to the originating
/// tab.
struct RootView: View {
    @StateObject private var appState = AppState()
    @StateObject private var player = AudioPlayer()

    @State private var selectedTab: Tab = .stations
    @State private var nowPlayingStation: Station?

    enum Tab: Hashable {
        case stations, favorites, recents, settings
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if appState.stations.isEmpty && appState.isLoading {
                loadingState
            } else if let error = appState.loadError, appState.stations.isEmpty {
                errorState(error)
            } else {
                tabbedShell
            }

            // Now Playing as a full-bleed overlay — fullScreenCover behaves
            // inconsistently on tvOS (often won't present from inside a
            // TabView). An overlay with onExitCommand on the inner view
            // gives us the same UX with predictable focus ownership.
            if let station = nowPlayingStation {
                NowPlayingView(
                    station: appState.stations
                        .first(where: { $0.id == station.id }) ?? station,
                    isFavorite: appState.isFavorite(station),
                    player: player,
                    onBack: { nowPlayingStation = nil },
                    onToggleFavorite: { appState.toggleFavorite(station) }
                )
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await appState.loadStations()
        }
        .onChange(of: appState.currentStation) { _, newValue in
            // Keep AVPlayer in sync with the user's selection.
            if let station = newValue {
                player.play(station)
            }
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.primary)
            Text("Se încarcă posturile…")
                .font(.system(size: 24))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func errorState(_ message: String) -> some View {
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
            Button("Reîncearcă") {
                Task { await appState.loadStations() }
            }
            .buttonStyle(.card)
        }
    }

    // MARK: - Tabs

    private var tabbedShell: some View {
        TabView(selection: $selectedTab) {
            StationGrid(
                title: "Posturi",
                subtitle: "\(appState.stations.count) posturi disponibile",
                stations: appState.stations,
                appState: appState,
                onSelect: open,
                emptyTitle: "Nu sunt posturi",
                emptySystemImage: "radio",
                emptyMessage: ""
            )
            .tabItem { Label("Posturi", systemImage: "radio") }
            .tag(Tab.stations)

            StationGrid(
                title: "Favorite",
                subtitle: "\(appState.favoriteStations.count) posturi",
                stations: appState.favoriteStations,
                appState: appState,
                onSelect: open,
                emptyTitle: "Nu ai posturi favorite",
                emptySystemImage: "heart",
                emptyMessage: "Adaugă posturi la favorite din Acum Redă"
            )
            .tabItem { Label("Favorite", systemImage: "heart") }
            .tag(Tab.favorites)

            StationGrid(
                title: "Recente",
                subtitle: "\(appState.recentStations.count) posturi",
                stations: appState.recentStations,
                appState: appState,
                onSelect: open,
                emptyTitle: "Nicio redare recentă",
                emptySystemImage: "clock",
                emptyMessage: "Posturile redate apar aici"
            )
            .tabItem { Label("Recente", systemImage: "clock") }
            .tag(Tab.recents)

            SettingsView(appState: appState)
                .tabItem { Label("Setări", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.primary)
    }

    private func open(_ station: Station) {
        appState.selectStation(station)
        nowPlayingStation = station
    }
}
