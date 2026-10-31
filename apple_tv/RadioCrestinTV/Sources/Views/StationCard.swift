import SwiftUI
import UIKit

/// Single station tile used in the Stations / Favorite / Recente grids.
///
/// SwiftUI on tvOS already renders a focus halo around `.cardButtonStyle()`
/// so we lean on the platform — adding a custom border on top fights the
/// system focus engine and looks bolted-on. We do add corner badges: one
/// on the current station's card, brand pink while it plays, and a heart
/// on the listener's favourites.
struct StationCard: View {
    let station: Station
    let playback: Playback
    let isFavorite: Bool
    let onSelect: () -> Void

    /// Whether the card is the current station's, and whether that plays
    /// or is paused.
    enum Playback: Equatable {
        /// Any other station's card: no badge.
        case notCurrent
        case playing
        case paused

        /// `isPaused` describes the current station, so it marks only
        /// that station's card.
        init(isCurrent: Bool, isPaused: Bool) {
            if !isCurrent {
                self = .notCurrent
            } else {
                self = isPaused ? .paused : .playing
            }
        }
    }

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
                    // The badges stay in the label and are only hidden:
                    // one taken out of a focused card (unfavourited from
                    // its menu, or another station playing) left the card
                    // without accessibility focus. The button's value
                    // tells VoiceOver what they show.
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.primary)
                        .frame(width: Self.badgeSide, height: Self.badgeSide)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(8)
                        .opacity(isFavorite ? 1 : 0)
                        .accessibilityHidden(true)
                    // Left of the heart when both show: in the same corner
                    // it covered the heart, leaving a dark crescent of its
                    // circle.
                    playingBadge
                        .padding(8)
                        .offset(x: isFavorite ? -(Self.badgeSide + 6) : 0)
                        .opacity(playback == .notCurrent ? 0 : 1)
                        .accessibilityHidden(true)
                        .animation(Self.badgeChange, value: playback)
                }
                StationCardCaption(
                    title: station.title,
                    subtitle: station.cardSubtitle,
                    focusScale: Self.focusLift
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
        .accessibilityValue(Self.accessibilityState(
            playback: playback, isFavorite: isFavorite
        ))
    }

    /// What the corner badges show, for VoiceOver: "se redă acum" or "în
    /// pauză", "favorit", both (in the badges' order, left to right) or
    /// nothing.
    static func accessibilityState(
        playback: Playback,
        isFavorite: Bool
    ) -> String {
        let current: String? = switch playback {
        case .notCurrent: nil
        case .playing: "se redă acum"
        case .paused: "în pauză"
        }
        return [current, isFavorite ? "favorit" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var artwork: some View {
        // Square artwork that follows the cell width. `StationArtwork`
        // crops the picture to this square, so a landscape song cover
        // can't widen the card or spill into its neighbour. Square
        // corners: the `.card` platter rounds the top ones, and rounded
        // bottom ones left notches where the caption continues the card.
        StationArtwork(
            station: station,
            cornerRadius: 0,
            focusScale: Self.focusLift
        )
        .aspectRatio(1, contentMode: .fit)
    }

    /// The side of the heart's circle and of the playing badge's.
    private static let badgeSide: CGFloat = 36

    /// How much the `.card` style enlarges the focused card (257.5 pt →
    /// 287.7 pt at six columns).
    private static let focusLift: CGFloat = 1.12

    /// The current station's badge appearing, going, or turning paused.
    private static let badgeChange: Animation = .easeInOut(duration: 0.2)

    /// The paused badge's fill: the heart's dark circle.
    private static let pausedFill = Color.black.opacity(0.55)

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

    /// The current station's marker. Only TV stations — which really are
    /// a live broadcast — carry the word "LIVE". Radio and playlist
    /// stations get a wordless badge (radio isn't labelled LIVE; playlists
    /// are on-demand), so it still marks the current tile without
    /// mislabeling it.
    ///
    /// Paused, the badge stays in its place, as Apple Music keeps marking
    /// the current song while it is paused: a pause sign on the heart's
    /// dark circle instead of the pink waveform, so the sign tells the
    /// two apart, not the colour alone.
    @ViewBuilder
    private var playingBadge: some View {
        let isPaused = playback == .paused
        let symbol = isPaused ? "pause.fill" : "waveform"
        let fill = isPaused ? Self.pausedFill : Theme.primary
        if station.kind == .tv {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    // As wide as the waveform, so pausing keeps the
                    // capsule's size.
                    .frame(width: 18)
                Text("LIVE")
                    .font(.system(size: 14, weight: .heavy))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(fill, in: Capsule())
            // As tall as the heart's circle, so the capsule centres on it.
            .frame(height: Self.badgeSide)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: Self.badgeSide, height: Self.badgeSide)
                .background(fill, in: Circle())
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
///
/// tvOS text sizes: the name in Caption 1 (25 pt), the song in Caption 2
/// (23 pt, tvOS's smallest text style). Both lines are cut at the end
/// and scroll on the focused card when they do not fit, so sister
/// stations cut alike ("Radio Philadelphia M…" for Melbourne and Mansuè)
/// read in full there.
private struct StationCardCaption: View {
    let title: String
    /// Radio: the current song (blank when none). TV / playlist carry no
    /// now-playing song, so they pass a typed label instead.
    let subtitle: String
    /// The focused card's lift, which enlarges the caption too.
    let focusScale: CGFloat

    @Environment(\.isFocused) private var isFocused
    /// Declared so the captions are drawn again when Bold Text (Settings ›
    /// Accessibility) is turned on or off: the UIKit system fonts below
    /// turn bolder by themselves under it, as a SwiftUI font does.
    @Environment(\.legibilityWeight) private var legibilityWeight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarqueeText(
                text: title,
                font: titleFont,
                color: Theme.textPrimary,
                isActive: isFocused,
                focusScale: focusScale
            )
            // Laid out even without a song (blank), so every card in a
            // row is as tall as its neighbours and their tops line up; a
            // card also keeps its height when its song comes and goes.
            MarqueeText(
                text: subtitle.isEmpty ? " " : subtitle,
                font: subtitleFont,
                color: isFocused
                    ? Theme.cardSubtitleFocused
                    : Theme.cardSubtitle,
                isActive: isFocused,
                focusScale: focusScale
            )
            .accessibilityHidden(subtitle.isEmpty)
        }
    }

    /// UIKit fonts, which the marquee measures and draws with. Asked for
    /// the next weight under Bold Text, they came two weights up (tvOS 27:
    /// Black titles, Heavy songs) and cut more captions.
    private var titleFont: UIFont {
        UIFont.systemFont(ofSize: 25, weight: .semibold)
    }

    private var subtitleFont: UIFont {
        UIFont.systemFont(ofSize: 23, weight: .regular)
    }
}
