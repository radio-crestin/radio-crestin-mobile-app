import AppIntents
import SwiftUI
import WidgetKit

/// The widgets' colors, light and dark, as in the app's widget designs.
struct WidgetPalette {
    let card: Color
    let text: Color
    let secondaryText: Color
    let hairline: Color
    let accent: Color
    let accentBackground: Color
    /// The previous and next buttons: see-through, since iOS draws the
    /// dark card lighter than `card` (iOS 27), and an opaque grey vanished.
    let chip: Color

    /// The brand pink of the play button.
    static let brand = Color(red: 0.914, green: 0.118, blue: 0.388)

    static func of(_ scheme: ColorScheme) -> WidgetPalette {
        scheme == .dark ? dark : light
    }

    private static let light = WidgetPalette(
        card: .white,
        text: Color(white: 0.067),
        secondaryText: Color(red: 0.42, green: 0.42, blue: 0.45),
        hairline: Color(red: 0.9, green: 0.9, blue: 0.918),
        accent: Color(red: 0.761, green: 0.094, blue: 0.357),
        accentBackground: brand.opacity(0.10),
        chip: Color.black.opacity(0.055)
    )

    private static let dark = WidgetPalette(
        card: Color(red: 0.11, green: 0.11, blue: 0.118),
        text: .white,
        secondaryText: Color(red: 0.631, green: 0.631, blue: 0.659),
        hairline: Color.white.opacity(0.10),
        accent: Color(red: 1, green: 0.31, blue: 0.545),
        accentBackground: Color(red: 1, green: 0.31, blue: 0.545).opacity(0.16),
        chip: Color.white.opacity(0.12)
    )
}

/// The three bars that mark the station playing, as in the app.
struct EqualizerBars: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 12
        let corner = CGSize(width: 1.3 * unit, height: 1.3 * unit)
        var path = Path()
        for (x, y) in [(0.5, 4.0), (4.7, 0.0), (8.9, 6.0)] {
            path.addRoundedRect(
                in: CGRect(
                    x: rect.minX + x * unit,
                    y: rect.minY + y * unit,
                    width: 2.6 * unit,
                    height: (12 - y) * unit
                ),
                cornerSize: corner
            )
        }
        return path
    }
}

/// A station logo or song cover, or the app logo while there's none, as
/// the app shows a missing image.
struct Artwork: View {
    let image: UIImage?
    let cornerRadius: CGFloat
    var outlined = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(
                    outlined ? WidgetPalette.of(colorScheme).hairline : .clear,
                    lineWidth: 1
                )
            )
    }

    @ViewBuilder private var content: some View {
        if let image {
            ArtworkImage(image: Image(uiImage: image).resizable())
                .scaledToFill()
        } else {
            GeometryReader { proxy in
                ArtworkImage(image: Image("AppLogo").resizable())
                    .scaledToFit()
                    .padding(proxy.size.width * 0.2)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Color(white: 0.949))
            }
        }
    }
}

/// What a widget button does.
enum WidgetAction {
    case play(slug: String, fromFavorites: Bool)
    case pause
    /// [fallbackSlug]: the station it plays, for the link before iOS 17.
    case skip(forward: Bool, fallbackSlug: String?)

    @available(iOS 17.0, *)
    var intent: any AppIntent {
        switch self {
        case let .play(slug, fromFavorites):
            return PlayStationIntent(stationSlug: slug, fromFavorites: fromFavorites)
        case .pause:
            return PausePlaybackIntent()
        case let .skip(forward, _):
            return SkipStationIntent(forward: forward)
        }
    }

    /// Before iOS 17 a widget can only open the app: with the station's
    /// link it plays that station there, as a shared link does.
    var appURL: URL? {
        switch self {
        case let .play(slug, _):
            return Self.link(to: slug)
        case .pause:
            return Self.link(to: nil)
        case let .skip(_, slug):
            return Self.link(to: slug)
        }
    }

    private static func link(to slug: String?) -> URL? {
        guard let slug, !slug.isEmpty else { return URL(string: "radiocrestin://") }
        return URL(string: "radiocrestin://\(slug)")
    }
}

/// A button that plays, pauses or changes the station without opening the
/// app; before iOS 17 it opens the app at that station instead.
struct ActionButton<Label: View>: View {
    let action: WidgetAction
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(iOS 17.0, *) {
            Button(intent: action.intent, label: label)
                .buttonStyle(.plain)
        } else if let url = action.appURL {
            Link(destination: url, label: label)
        } else {
            label()
        }
    }
}

/// A round button with an SF Symbol: previous and next.
struct RoundIcon: View {
    let symbol: String
    let diameter: CGFloat
    let iconSize: CGFloat
    let foreground: Color
    let background: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: iconSize, weight: .bold))
            .foregroundColor(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(background))
            .contentShape(Circle())
    }
}

/// A brand-pink disc with a white mark: the play or pause icon, or the
/// equalizer of the station playing.
///
/// On a tinted Home Screen iOS draws the disc and a white mark in the same
/// tint, which hid the mark, so there the mark is cut out of the disc.
struct BrandDisc: View {
    enum Mark {
        case symbol(String, size: CGFloat)
        case equalizer(size: CGFloat)
    }

    let mark: Mark
    let diameter: CGFloat

    var body: some View {
        if #available(iOS 16.0, *) {
            TintAwareBrandDisc(disc: self)
        } else {
            solid
        }
    }

    fileprivate var solid: some View {
        markView
            .foregroundColor(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(WidgetPalette.brand))
    }

    fileprivate var cutOut: some View {
        Circle()
            .fill(WidgetPalette.brand)
            .frame(width: diameter, height: diameter)
            .overlay(markView.blendMode(.destinationOut))
            .compositingGroup()
    }

    @ViewBuilder private var markView: some View {
        switch mark {
        case let .symbol(name, size):
            Image(systemName: name).font(.system(size: size, weight: .bold))
        case let .equalizer(size):
            EqualizerBars().frame(width: size, height: size)
        }
    }
}

@available(iOS 16.0, *)
private struct TintAwareBrandDisc: View {
    let disc: BrandDisc

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .accented {
            disc.cutOut.widgetAccentable()
        } else {
            disc.solid
        }
    }
}

/// The pink play or pause button of the station shown.
struct PlayPauseButton: View {
    let snapshot: WidgetSnapshot?
    let diameter: CGFloat
    let iconSize: CGFloat

    var body: some View {
        let playing = snapshot?.isPlaying == true
        let action: WidgetAction = playing
            ? .pause
            : .play(slug: snapshot?.station?.slug ?? "", fromFavorites: false)
        ActionButton(action: action) {
            BrandDisc(
                mark: .symbol(playing ? "pause.fill" : "play.fill", size: iconSize),
                diameter: diameter
            )
            .contentShape(Circle())
        }
        .accessibilityLabel(playing ? "Pauză" : playLabel)
    }

    private var playLabel: String {
        guard let title = snapshot?.station?.title else { return "Pornește radioul" }
        return "Pornește \(title)"
    }
}

/// "406 ascultă acum", with headphones.
struct ListenersLine: View {
    let count: Int
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "headphones")
                .font(.system(size: fontSize - 1, weight: .semibold))
            Text("\(Self.format(count)) ascultă acum")
                .font(.system(size: fontSize))
                .lineLimit(1)
        }
        .foregroundColor(color)
    }

    /// 1360 as Romanian writes it: "1.360".
    static func format(_ count: Int) -> String {
        count.formatted(.number.locale(Locale(identifier: "ro_RO")))
    }
}

extension String {
    /// Upper case as Romanian writes it ("ultima ascultată" → "ULTIMA
    /// ASCULTATĂ").
    var romanianUppercased: String {
        uppercased(with: Locale(identifier: "ro_RO"))
    }
}

extension View {
    /// The widget's card color, filling it on every iOS version.
    @ViewBuilder
    func widgetCard(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            containerBackground(color, for: .widget)
        } else {
            padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(color)
        }
    }

    /// Marks the brand's pink parts, which a tinted Home Screen colors
    /// with its tint.
    @ViewBuilder
    func accentable() -> some View {
        if #available(iOS 16.0, *) {
            widgetAccentable()
        } else {
            self
        }
    }

    /// Before iOS 17 a small widget is a single link: [url] plays its
    /// station in the app. From iOS 17 its buttons act on their own.
    @ViewBuilder
    func legacyWidgetURL(_ url: URL?) -> some View {
        if #available(iOS 17.0, *) {
            self
        } else {
            widgetURL(url)
        }
    }
}

/// An image that stays a photo, greyed, on a tinted Home Screen instead
/// of a flat silhouette.
///
/// The tint modifier is left off in full color: it takes the image out of
/// its button's tap area (seen on iOS 27), so a tap on a favorite's logo
/// opened the app instead of playing it. A tinted Home Screen needs it,
/// since iOS draws an image without it as a white block, and there the
/// logos open the app; the names below them still play.
struct ArtworkImage: View {
    let image: Image

    var body: some View {
        if #available(iOS 18.0, *) {
            TintableArtworkImage(image: image)
        } else {
            image
        }
    }
}

@available(iOS 18.0, *)
private struct TintableArtworkImage: View {
    let image: Image

    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        if renderingMode == .accented {
            image.widgetAccentedRenderingMode(.desaturated)
        } else {
            image
        }
    }
}
