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

            // Swap the entire root view rather than overlaying. With an
            // overlay, the underlying TabView remained in the focus
            // hierarchy and captured Menu/Back at the tab bar, exiting the
            // app before NowPlayingView's onExitCommand could fire.
            if let station = nowPlayingStation {
                let live = appState.stations
                    .first(where: { $0.id == station.id }) ?? station
                NowPlayingView(
                    station: live,
                    isFavorite: appState.isFavorite(station),
                    player: player,
                    songHistory: appState.songHistory,
                    onBack: { close() },
                    onToggleFavorite: { appState.toggleFavorite(station) },
                    onPrev: { go(to: appState.previousStation(before: live)) },
                    onNext: { go(to: appState.nextStation(after: live)) }
                )
                .transition(.opacity)
            } else if appState.stations.isEmpty && appState.isLoading {
                loadingState
                    .transition(.opacity)
            } else if let error = appState.loadError, appState.stations.isEmpty {
                errorState(error)
                    .transition(.opacity)
            } else {
                tabbedShell
                    .transition(.opacity)

                // Brand mark — top-left, vertically aligned with the
                // centered tab bar so the wordmark sits on the same
                // baseline as "Posturi · Favorite · Recente · Setări".
                // Non-focusable overlay; the focus engine ignores it
                // and the underlying TabView keeps its standard D-pad
                // navigation.
                VStack {
                    HStack {
                        BrandMark()
                            .padding(.leading, Theme.Spacing.xxl)
                            .padding(.top, Theme.Spacing.lg)
                        Spacer()
                    }
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: nowPlayingStation?.id)
        .preferredColorScheme(.dark)
        .task {
            // Wire metadata-sync hooks before the first fetch so an
            // in-progress HLS stream (rare on cold launch, common on
            // tab-switch) gets the right `?timestamp=` immediately.
            appState.hlsPlaybackTimestampProvider = { [weak player] in
                player?.hlsPlaybackTimestamp
            }
            appState.isPlayingHlsProvider = { [weak player] in
                player?.isPlayingHls ?? false
            }
            await appState.loadStations()
        }
        .onChange(of: appState.currentStation?.id) { _, newId in
            // Restart playback only when the *station* changed — not
            // when its metadata did. Watching the whole `Station` value
            // here meant every metadata poll re-set the AVPlayer item,
            // which audibly cut the audio every ~10s.
            guard let newId,
                  let station = appState.stations.first(where: { $0.id == newId })
            else { return }
            player.play(station)
        }
    }

    private func close() {
        nowPlayingStation = nil
    }

    /// Navigate to the given station from the prev/next controls in
    /// Now Playing. Selecting it triggers AudioPlayer via the
    /// `onChange(of: currentStation?.id)` hook below.
    private func go(to station: Station?) {
        guard let station else { return }
        appState.selectStation(station)
        nowPlayingStation = station
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
                title: "Pentru tine",
                subtitle: "\(appState.stations.count) posturi",
                stations: appState.sortedStations,
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
