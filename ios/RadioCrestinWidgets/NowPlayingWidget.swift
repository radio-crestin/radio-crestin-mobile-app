import SwiftUI
import WidgetKit

/// "Acum ascult": the station playing and the song heard, or the last
/// station listened to, with play and pause; the medium size adds the
/// previous and next stations.
struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: WidgetKind.nowPlaying,
            provider: SnapshotProvider(showsListeners: true)
        ) { entry in
            NowPlayingWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Acum ascult")
        .description("Melodia care se aude, cu pornire și pauză.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NowPlayingWidgetView: View {
    let snapshot: WidgetSnapshot?

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium:
            NowPlayingMediumView(content: NowPlayingContent(snapshot))
        default:
            NowPlayingSmallView(content: NowPlayingContent(snapshot))
        }
    }
}

/// What both sizes say, depending on whether a station plays.
struct NowPlayingContent {
    enum State {
        /// The app hasn't saved a station yet.
        case empty
        case playing
        /// Paused or stopped: the last station listened to.
        case stopped
    }

    let snapshot: WidgetSnapshot?

    init(_ snapshot: WidgetSnapshot?) {
        self.snapshot = snapshot
    }

    var state: State {
        guard snapshot?.station != nil else { return .empty }
        return snapshot?.isPlaying == true ? .playing : .stopped
    }

    var stationTitle: String { snapshot?.station?.title ?? "Radio Crestin" }

    /// The big line: the song while playing, else the station.
    var title: String {
        switch state {
        case .empty: return "Radio Crestin"
        case .playing: return snapshot?.song?.title ?? "În direct"
        case .stopped: return stationTitle
        }
    }

    /// The song's artist while playing.
    var artist: String? {
        state == .playing ? snapshot?.song?.artist : nil
    }

    var listeners: Int? {
        guard state == .stopped, let count = snapshot?.listeners, count > 0
        else { return nil }
        return count
    }

    var logo: UIImage? { WidgetStorage.image(named: snapshot?.station?.logo) }

    /// The song's cover while playing, if there's one to show.
    var cover: UIImage? {
        state == .playing ? WidgetStorage.image(named: snapshot?.cover) : nil
    }

    var playURL: URL? {
        WidgetAction.play(slug: snapshot?.station?.slug ?? "", fromFavorites: false)
            .appURL
    }
}

// MARK: - Small

struct NowPlayingSmallView: View {
    let content: NowPlayingContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.of(colorScheme)
        let cover = content.cover
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Artwork(
                    image: cover ?? content.logo,
                    cornerRadius: 12,
                    outlined: cover == nil
                )
                .frame(width: 58, height: 58)
                Spacer(minLength: 4)
                PlayPauseButton(snapshot: content.snapshot, diameter: 40, iconSize: 16)
            }
            Spacer(minLength: 6)
            caption(palette)
            Text(content.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(palette.text)
                .lineLimit(1)
                .padding(.top, 4)
            subtitle(palette)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetCard(palette.card)
        .legacyWidgetURL(content.playURL)
    }

    @ViewBuilder
    private func caption(_ palette: WidgetPalette) -> some View {
        switch content.state {
        case .playing:
            HStack(spacing: 5) {
                EqualizerBars().frame(width: 11, height: 11)
                Text(content.stationTitle.romanianUppercased)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.33)
                    .lineLimit(1)
            }
            .foregroundColor(palette.accent)
            .accentable()
        case .stopped:
            Text("ULTIMA ASCULTATĂ")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.33)
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func subtitle(_ palette: WidgetPalette) -> some View {
        if let artist = content.artist {
            Text(artist)
                .font(.system(size: 13))
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        } else if let listeners = content.listeners {
            ListenersLine(count: listeners, color: palette.secondaryText, fontSize: 13)
        } else if content.state == .empty {
            Text("Apasă pentru a asculta")
                .font(.system(size: 13))
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        }
    }
}

// MARK: - Medium

struct NowPlayingMediumView: View {
    let content: NowPlayingContent

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.of(colorScheme)
        GeometryReader { proxy in
            HStack(alignment: .top, spacing: 14) {
                artwork(palette)
                    .frame(width: proxy.size.height, height: proxy.size.height)
                VStack(alignment: .leading, spacing: 0) {
                    header(palette)
                    MediumTitle(text: content.title, color: palette.text)
                        .padding(.top, 4)
                        // Sized first, from the room the other rows leave,
                        // so it drops its second line instead of pushing
                        // the buttons out of the widget.
                        .layoutPriority(1)
                    subtitle(palette)
                        .padding(.top, 2)
                    Spacer(minLength: 6)
                    controls(palette)
                }
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            }
        }
        .widgetCard(palette.card)
    }

    /// The cover with the station's logo in its corner, or the logo alone.
    private func artwork(_ palette: WidgetPalette) -> some View {
        let cover = content.cover
        return Artwork(image: cover ?? content.logo, cornerRadius: 14, outlined: cover == nil)
            .overlay(alignment: .bottomLeading) {
                if cover != nil {
                    Artwork(image: content.logo, cornerRadius: 9, outlined: false)
                        .frame(width: 26, height: 26)
                        .padding(2)
                        .background(LogoBadgeFrame(color: palette.card))
                        .padding(6)
                }
            }
    }

    @ViewBuilder
    private func header(_ palette: WidgetPalette) -> some View {
        switch content.state {
        case .playing:
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    EqualizerBars().frame(width: 10, height: 10)
                    Text("LIVE")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(0.6)
                }
                .foregroundColor(palette.accent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.accentBackground)
                )
                .accentable()
                Text(content.stationTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(palette.secondaryText)
                    .lineLimit(1)
            }
        case .stopped:
            Text("ULTIMA ASCULTATĂ")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.33)
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        case .empty:
            EmptyView()
        }
    }

    @ViewBuilder
    private func subtitle(_ palette: WidgetPalette) -> some View {
        if let artist = content.artist {
            Text(artist)
                .font(.system(size: 13))
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        } else if let listeners = content.listeners {
            ListenersLine(count: listeners, color: palette.secondaryText, fontSize: 13)
        } else if content.state == .empty {
            Text("Apasă pentru a asculta")
                .font(.system(size: 13))
                .foregroundColor(palette.secondaryText)
                .lineLimit(1)
        }
    }

    private func controls(_ palette: WidgetPalette) -> some View {
        let snapshot = content.snapshot
        let hasStation = content.state != .empty
        return HStack(spacing: 6) {
            if hasStation {
                skipButton(forward: false, slug: snapshot?.previousSlug, palette)
            }
            PlayPauseButton(snapshot: snapshot, diameter: 44, iconSize: 18)
            if hasStation {
                skipButton(forward: true, slug: snapshot?.nextSlug, palette)
            }
        }
    }

    private func skipButton(
        forward: Bool,
        slug: String?,
        _ palette: WidgetPalette
    ) -> some View {
        ActionButton(action: .skip(forward: forward, fallbackSlug: slug)) {
            RoundIcon(
                symbol: forward ? "forward.fill" : "backward.fill",
                diameter: 38,
                iconSize: 14,
                foreground: palette.text,
                background: palette.chip
            )
        }
        .accessibilityLabel(forward ? "Stația următoare" : "Stația anterioară")
    }
}

/// The card-colored frame of the station's logo on the cover.
///
/// On a tinted Home Screen iOS paints shapes over the images, so a filled
/// frame covered the logo with a white block; there it is only the border.
private struct LogoBadgeFrame: View {
    let color: Color

    fileprivate static let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        if #available(iOS 16.0, *) {
            TintAwareLogoBadgeFrame(color: color)
        } else {
            Self.shape.fill(color)
        }
    }
}

@available(iOS 16.0, *)
private struct TintAwareLogoBadgeFrame: View {
    let color: Color

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .accented {
            LogoBadgeFrame.shape.strokeBorder(color, lineWidth: 2)
        } else {
            LogoBadgeFrame.shape.fill(color)
        }
    }
}

/// The medium size's big line: 17 pt when it fits on one line, else 14 pt
/// on up to two, so a song change never moves the cover or the buttons.
///
/// Where two lines don't fit either (iPhone mini and SE), it stays at
/// 17 pt and ends in "…".
private struct MediumTitle: View {
    let text: String
    let color: Color

    var body: some View {
        if #available(iOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                line(size: 17, lines: 1)
                ViewThatFits(in: .vertical) {
                    line(size: 14, lines: 2)
                    line(size: 17, lines: 1)
                }
            }
        } else {
            line(size: 17, lines: 1)
        }
    }

    private func line(size: CGFloat, lines: Int) -> some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .foregroundColor(color)
            .lineLimit(lines)
    }
}
