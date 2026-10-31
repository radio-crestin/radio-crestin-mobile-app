import SwiftUI
import UIKit

/// Loads station and song pictures, decodes them off the main thread and
/// keeps them in memory, so a card scrolled back into view, or Now
/// Playing opened again, shows its picture on the first frame.
///
/// `AsyncImage` kept nothing between appearances and relied on `URLCache`
/// alone, and the CDN answers with `Vary: Accept`, which the default cache
/// policy never reuses: every card that came back into view downloaded and
/// decoded its picture again (about 0.5 MB per pass over the grid) and
/// faded it in over the placeholder.
@MainActor
final class ArtworkLoader {
    static let shared: ArtworkLoader = {
        let loader = ArtworkLoader(session: makeSession())
        // The decoded pictures go first when memory runs short: a picture
        // shown again comes back from the disk cache, without the network.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { loader.removeAllImages() }
        }
        return loader
    }()

    /// Decoded pictures by URL, the sized one (see `ArtworkURL`). At 4K a
    /// grid picture is at most 600 px, 1.4 MB decoded (a 512 px logo, the
    /// most common, 1 MB): 64 MB keeps the visible grid and a screen or two
    /// around it, with Now Playing's larger pictures. Past that the cache
    /// lets some go, and all of them on a memory warning.
    private let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// URLs the server refused or that held no picture: not asked for again
    /// on every appearance. Network errors and server faults (5xx) are not
    /// remembered, so the next appearance tries again.
    private var refused: Set<URL> = []

    /// One download per URL, however many views ask for it meanwhile.
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    /// The first of `urls` that can show now, in order of preference: a
    /// picture in memory, skipping URLs known to be refused. Nil while a
    /// preferred URL is still unknown, so a station logo in memory never
    /// shows for a moment before the song cover meant to cover it.
    func cachedImage(for urls: [URL]) -> UIImage? {
        for url in urls {
            if let image = images.object(forKey: url as NSURL) {
                return image
            }
            if !refused.contains(url) { return nil }
        }
        return nil
    }

    /// The first of `urls` in memory, whatever is known of those before
    /// it: for the system's Now Playing, which shows the station logo
    /// rather than nothing while the song cover loads.
    func anyCachedImage(for urls: [URL]) -> UIImage? {
        urls.lazy.compactMap { self.images.object(forKey: $0 as NSURL) }.first
    }

    /// The first of `urls` that loads, tried in order; nil when none does.
    func image(for urls: [URL]) async -> UIImage? {
        for url in urls {
            if let image = await image(for: url) { return image }
        }
        return nil
    }

    func image(for url: URL) async -> UIImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if refused.contains(url) { return nil }
        let task = inFlight[url] ?? startLoading(url)
        return await task.value
    }

    func removeAllImages() {
        images.removeAllObjects()
    }

    private func startLoading(_ url: URL) -> Task<UIImage?, Never> {
        // Not tied to the view that asked: a card scrolled past still fills
        // the cache for its way back.
        let task = Task { [session] in
            let result = await ArtworkDownload.run(url, with: session)
            finish(url, with: result)
            return result.image
        }
        inFlight[url] = task
        return task
    }

    private func finish(_ url: URL, with result: ArtworkDownload.Result) {
        inFlight[url] = nil
        switch result {
        case .image(let image):
            images.setObject(image, forKey: url as NSURL, cost: image.byteCount)
        case .refused:
            refused.insert(url)
        case .failed:
            break
        }
    }

    /// A session that serves a stored answer without asking the network,
    /// from a disk cache of its own that also lasts across launches.
    ///
    /// The CDN signs every URL for one picture at one size and serves it
    /// `immutable`, so a stored answer is always the right one. The
    /// default policy went back to the network every time: the answers
    /// carry `Vary: Accept`, which `URLCache` does not match on its own.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = URLCache(
            memoryCapacity: 4 << 20,
            diskCapacity: 64 << 20,
            directory: FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "Artwork", directoryHint: .isDirectory)
        )
        return URLSession(configuration: configuration)
    }
}

/// Downloading and decoding one picture, always off the main thread.
private enum ArtworkDownload {
    enum Result {
        case image(UIImage)
        /// A refusal (HTTP 4xx) or bytes that are no picture.
        case refused
        /// No answer, or a server fault (5xx): worth asking again later.
        case failed

        var image: UIImage? {
            if case .image(let image) = self { return image }
            return nil
        }
    }

    /// `@concurrent` so the decoding never runs on the caller's actor (the
    /// main one), whatever the module's concurrency settings make of a
    /// plain `nonisolated async` function.
    @concurrent
    nonisolated static func run(
        _ url: URL,
        with session: URLSession
    ) async -> Result {
        guard let (data, response) = try? await session.data(from: url) else {
            return .failed
        }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            forget(url, in: session)
            return http.statusCode >= 500 ? .failed : .refused
        }
        // Decoded here once, rather than lazily wherever it is first drawn.
        guard let image = UIImage(data: data)?.preparingForDisplay() else {
            forget(url, in: session)
            return .refused
        }
        return .image(image)
    }

    /// Drops a stored error answer: the cache-first policy would otherwise
    /// serve it again on every later launch.
    private nonisolated static func forget(_ url: URL, in session: URLSession) {
        session.configuration.urlCache?.removeCachedResponse(
            for: URLRequest(url: url)
        )
    }
}

private extension UIImage {
    /// Decoded size in bytes, the memory cache's cost.
    var byteCount: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Tells pictures apart by object, as `===` does.
    var identity: ObjectIdentifier { ObjectIdentifier(self) }
}

/// Artwork URLs sized for the slot that shows them.
///
/// The API hands out cdn.radiocrestin.ro URLs with `w=250`: 250 px for a
/// grid card 515 px wide at 4K and for Now Playing's 920 px artwork, so
/// logos looked soft. The CDN resizes on request (the signature covers
/// only the source URL) and never enlarges past the original, so asking
/// for the slot's pixel width costs nothing for small originals.
enum ArtworkURL {
    private static let cdnHost = "cdn.radiocrestin.ro"

    /// Widths round up to a multiple of this, so slots of nearly the same
    /// size share one download and one cached picture.
    private static let widthStep = 100

    /// `url` asking the CDN for a picture `pixels` wide. Other hosts, and
    /// URLs without a width, are left as they are.
    static func sized(_ url: URL, pixels: CGFloat) -> URL {
        guard pixels > 0,
              url.host() == cdnHost,
              var components = URLComponents(
                url: url, resolvingAgainstBaseURL: false
              ),
              let items = components.percentEncodedQueryItems,
              items.contains(where: { $0.name == "w" })
        else { return url }
        let steps = (pixels / CGFloat(widthStep)).rounded(.up)
        let width = String(Int(steps) * widthStep)
        // Percent-encoded items, so the signed `url=` value goes back
        // exactly as it came.
        components.percentEncodedQueryItems = items.map {
            $0.name == "w" ? URLQueryItem(name: "w", value: width) : $0
        }
        return components.url ?? url
    }

    /// `urls` sized for a slot `points` wide on a screen of `scale`.
    static func sized(
        _ urls: [URL],
        points: CGFloat,
        scale: CGFloat
    ) -> [URL] {
        urls.map { sized($0, pixels: points * scale) }
    }
}

/// A remote picture through `ArtworkLoader`, cropped to cover its slot.
///
/// A picture in memory shows on the first frame, without a fade, so a card
/// scrolled back into view looks as it did. Otherwise the picture fades in
/// over what is behind it once loaded. `urls` are tried in order and the
/// first that loads wins. When `urls` change (a new song, another
/// station), the picture on screen stays until the new one is ready, so
/// the placeholder never flashes in between. The new one then fades in
/// over it while it stays fully opaque: a crossfade of two part
/// transparent pictures let the dark backdrop through, and the artwork
/// dimmed for a moment.
struct ArtworkImage: View {
    let urls: [URL]

    /// The pictures on screen, the newest on top: one, or two while the
    /// newest fades in.
    @State private var layers: [UIImage]

    init(urls: [URL]) {
        self.urls = urls
        // Only for a new view: one already on screen keeps its pictures
        // while the next `urls` load.
        _layers = State(
            initialValue: ArtworkLoader.shared.cachedImage(for: urls)
                .map { [$0] } ?? []
        )
    }

    /// The app's content-change fade.
    private static let fade = Animation.easeInOut(duration: 0.25)

    var body: some View {
        Color.clear
            .overlay {
                ZStack {
                    ForEach(layers, id: \.identity) { image in
                        AspectFillImage(image: Image(uiImage: image))
                            .transition(.opacity)
                    }
                }
            }
            // Decorative: a title next to it names what it shows.
            .accessibilityHidden(true)
            .task(id: urls) {
                let image = await ArtworkLoader.shared.image(for: urls)
                guard !Task.isCancelled else { return }
                show(image)
            }
    }

    private func show(_ image: UIImage?) {
        guard let image else {
            // Nothing loads for these URLs: what is behind shows again.
            withAnimation(Self.fade) { layers = [] }
            return
        }
        guard image !== layers.last else { return }
        withAnimation(Self.fade) {
            // A picture back before the one over it finished fading in
            // (next, then previous at once) moves to the top: twice in
            // the list, its id would name two layers.
            layers.removeAll { $0 === image }
            layers.append(image)
        } completion: {
            // The pictures under it no longer show. A first picture has
            // none, and its card is not updated again.
            if let index = layers.firstIndex(where: { $0 === image }),
               index > 0 {
                layers.removeFirst(index)
            }
        }
    }
}
