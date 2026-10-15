import SwiftUI
import WidgetKit

/// "Favorite": four favorite stations, each played with a tap; the one
/// playing is ringed, and the song heard is named above them.
struct FavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKind.favorites,
            provider: SnapshotProvider()
        ) { entry in
            FavoritesWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Favorite")
        .description("Pornește o stație favorită dintr-o atingere.")
        .supportedFamilies([.systemMedium])
    }
}

struct FavoritesWidgetView: View {
    let snapshot: WidgetSnapshot?

    @Environment(\.colorScheme) private var colorScheme

    private static let slots = 4
    private static let spacing: CGFloat = 10
    /// Room under a logo for its gap and two lines of name.
    private static let nameHeight: CGFloat = 6 + 26

    private var stations: [WidgetSnapshot.Station] {
        Array((snapshot?.favorites ?? []).prefix(Self.slots))
    }

    var body: some View {
        let palette = WidgetPalette.of(colorScheme)
        VStack(alignment: .leading, spacing: 10) {
            header(palette)
                .frame(height: 18)
            if stations.isEmpty {
                emptyMessage(palette)
            } else {
                tiles(palette)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetCard(palette.card)
    }

    private func header(_ palette: WidgetPalette) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ArtworkImage(image: Image("AppLogo").resizable())
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                Text((snapshot?.favoriteCount ?? 0) > 0 ? "Favorite" : "Radio Crestin")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(palette.text)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            if let heard = heardNow {
                HStack(spacing: 5) {
                    EqualizerBars().frame(width: 10, height: 10)
                    Text(heard)
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                }
                .foregroundColor(palette.accent)
                .accentable()
            }
        }
    }

    /// The song heard, or the station when it names none, while playing.
    private var heardNow: String? {
        guard let snapshot, snapshot.isPlaying else { return nil }
        return snapshot.song?.title ?? snapshot.station?.title
    }

    private func tiles(_ palette: WidgetPalette) -> some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - Self.spacing * CGFloat(Self.slots - 1))
                / CGFloat(Self.slots)
            let side = max(0, min(64, width - 6, proxy.size.height - Self.nameHeight))
            HStack(alignment: .top, spacing: Self.spacing) {
                ForEach(Array(stations.enumerated()), id: \.element.slug) { index, station in
                    tile(station, index: index, side: side, palette)
                        .frame(width: width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func tile(
        _ station: WidgetSnapshot.Station,
        index: Int,
        side: CGFloat,
        _ palette: WidgetPalette
    ) -> some View {
        let playing = snapshot?.isPlaying == true && snapshot?.station?.slug == station.slug
        let fromFavorites = index < (snapshot?.favoriteCount ?? 0)
        let action: WidgetAction = playing
            ? .pause
            : .play(slug: station.slug, fromFavorites: fromFavorites)
        let radius = side * 15 / 64
        return ActionButton(action: action) {
            VStack(spacing: 6) {
                Artwork(image: WidgetStorage.image(named: station.logo), cornerRadius: radius)
                    .frame(width: side, height: side)
                    .overlay(playing ? PlayingRing(radius: radius) : nil)
                    .overlay(alignment: .bottomTrailing) {
                        if playing {
                            PlayingBadge(border: palette.card)
                                .offset(x: 6, y: 6)
                        }
                    }
                Text(station.title)
                    .font(.system(size: 11, weight: playing ? .bold : .semibold))
                    .foregroundColor(playing ? palette.accent : palette.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(playing ? "\(station.title), se aude acum" : "Pornește \(station.title)")
        .accessibilityHint(playing ? "Pune pauză" : "")
    }

    private func emptyMessage(_ palette: WidgetPalette) -> some View {
        Text("Adaugă stații la Favorite din aplicație.")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(palette.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The pink ring around the station playing.
private struct PlayingRing: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius + 3.75, style: .continuous)
            .stroke(WidgetPalette.brand, lineWidth: 2.5)
            .padding(-3.75)
            .accentable()
    }
}

/// The equalizer badge on the corner of the station playing.
private struct PlayingBadge: View {
    let border: Color

    var body: some View {
        BrandDisc(mark: .equalizer(size: 9), diameter: 22)
            .overlay(Circle().strokeBorder(border, lineWidth: 2))
    }
}
