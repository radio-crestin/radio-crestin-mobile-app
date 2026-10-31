import SwiftUI

/// Single station tile used in the Stations / Favorite / Recente grids.
///
/// SwiftUI on tvOS already renders a focus halo around `.cardButtonStyle()`
/// so we lean on the platform — adding a custom border on top fights the
/// system focus engine and looks bolted-on. We do add a brand-pink dot for
/// the "currently playing" indicator so users can spot the active station.
struct StationCard: View {
    let station: Station
    let isPlaying: Bool
    let isFavorite: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    artwork
                    // Kind badge in the top-left corner so TV and playlist
                    // stations are distinguishable at a glance in the grid.
                    // Radio (the default) renders nothing.
                    kindBadge
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .topLeading)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.primary)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(8)
                    }
                    if isPlaying {
                        playingBadge
                            .padding(8)
                    }
                }
                StationCardCaption(
                    title: station.title,
                    subtitle: station.cardSubtitle
                )
                // Uniform 16pt inset on every side so the labels feel
                // framed inside the card rather than crowding the edge
                // or the artwork above.
                .padding(Theme.Spacing.md)
            }
            // Card width is owned by the parent grid so cells stretch
            // equally to fill the screen at any TV resolution.
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.card)
    }

    private var artwork: some View {
        // Square artwork that follows the cell width. `StationArtwork`
        // crops the picture to this square, so a landscape song cover
        // can't widen the card or spill into its neighbour.
        StationArtwork(
            station: station,
            cornerRadius: Theme.Radius.lg
        )
        .aspectRatio(1, contentMode: .fit)
    }

    /// Small corner badge marking TV / playlist stations. Radio stations
    /// (the default) get none, keeping the common case visually clean.
    @ViewBuilder
    private var kindBadge: some View {
        switch station.kind {
        case .tv:
            HStack(spacing: 5) {
                Image(systemName: "tv")
                    .font(.system(size: 13, weight: .bold))
                Text("TV")
                    .font(.system(size: 13, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.primary, in: Capsule())
        case .playlist:
            Image(systemName: "list.and.film")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(.black.opacity(0.6), in: Circle())
        case .radio:
            EmptyView()
        }
    }

    /// "Currently playing" marker. Only TV stations — which really are a
    /// live broadcast — carry the word "LIVE". Radio and playlist stations
    /// get a wordless waveform badge (radio isn't labelled LIVE; playlists
    /// are on-demand), so the badge still marks the active tile without
    /// mislabeling it.
    @ViewBuilder
    private var playingBadge: some View {
        if station.kind == .tv {
            HStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .bold))
                Text("LIVE")
                    .font(.system(size: 14, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.primary, in: Capsule())
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(7)
                .background(Theme.primary, in: Circle())
        }
    }
}

/// Station name and subtitle under the card's artwork.
///
/// A view of its own so it can read the card's focus: inside a `Button`'s
/// label, `\.isFocused` describes that button, while `StationCard` itself
/// sits outside it and would always read `false`. The focused `.card`
/// platter is lighter than the unfocused one, so the subtitle brightens
/// with it to keep its contrast (see `Theme.cardSubtitleFocused`).
private struct StationCardCaption: View {
    let title: String
    /// Radio: the current song (blank when none). TV / playlist carry no
    /// now-playing song, so they pass a typed label instead.
    let subtitle: String

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 18))
                    .foregroundStyle(
                        isFocused
                            ? Theme.cardSubtitleFocused
                            : Theme.cardSubtitle
                    )
                    .lineLimit(1)
            }
        }
    }
}
