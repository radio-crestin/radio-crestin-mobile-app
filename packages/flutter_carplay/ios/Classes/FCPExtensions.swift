//
//  FCPExtensions.swift
//  flutter_carplay
//
//  Created by Oğuzhan Atalay on 21.08.2021.
//

import UIKit

// Image Source (no UIImage creation here)
enum ImageSource {
    case url(URL)
    case file(String)
    case flutterAsset(String)
    // An SF Symbol, written "sf:<name>" on the Dart side.
    case systemSymbol(String)
    // An SF Symbol on a square of a color, written "tile:<name>:<RRGGBB>"
    // on the Dart side.
    case symbolTile(String, UIColor)
}

// String → ImageSource
extension String {
    func toImageSource() -> ImageSource {
        if self.hasPrefix("sf:") {
            return .systemSymbol(String(self.dropFirst(3)))
        } else if self.hasPrefix("tile:") {
            let parts = self.dropFirst(5).split(separator: ":", maxSplits: 1)
            let name = parts.first.map(String.init) ?? ""
            guard parts.count > 1, let color = UIColor(rgbHex: String(parts[1])) else {
                return .systemSymbol(name)
            }
            return .symbolTile(name, color)
        } else if self.starts(with: "http") {
            guard let url = URL(string: self) else {
                return .flutterAsset(self)
            }
            return .url(url)
        } else if self.starts(with: "file://") {
            return .file(self.replacingOccurrences(of: "file://", with: ""))
        } else {
            return .flutterAsset(self)
        }
    }
}

// One immutable transparent placeholder shared by every list item. A fresh
// screen-scale bitmap per item cost ~350 KB each (~25 MB at launch, when
// all station rows are built). Global `let` initialisation is lazy and
// thread-safe, so no main-queue hop is needed.
private let sharedPlaceholderImage: UIImage = {
  let format = UIGraphicsImageRendererFormat()
  format.opaque = false
  format.scale = 1
  return UIGraphicsImageRenderer(
    size: CGSize(width: 100, height: 100),
    format: format
  ).image { _ in }
}()

func makeSafeUIPlaceholder() -> UIImage { sharedPlaceholderImage }

func makeUIPlaceholder() -> UIImage { sharedPlaceholderImage }

// Resolves a Flutter asset to an image, or nil when the name is empty or the
// asset isn't bundled. `UIImage(imageLiteralResourceName:)` traps on a
// missing asset, and an unparseable URL also lands here as an asset name.
private func loadFlutterAssetImage(named name: String) -> UIImage? {
  guard !name.isEmpty,
        let registrar = SwiftFlutterCarplayPlugin.registrar else {
    return nil
  }
  return UIImage(named: registrar.lookupKey(forAsset: name))
}

// UIImage creation (MAIN THREAD ONLY)
@available(iOS 14.0, *)
func makeUIImage(from source: ImageSource) -> UIImage {
    switch source {
    case .url(let url):
        let data = try? Data(contentsOf: url) // Synchronous URL loading (kept for compatibility but avoid using on main thread)
        return data.flatMap { UIImage(data: $0) } ?? UIImage(systemName: "questionmark")!

    case .file(let path):
        return UIImage(contentsOfFile: path) ?? UIImage(systemName: "questionmark")!

    case .flutterAsset(let name):
        return loadFlutterAssetImage(named: name)
            ?? UIImage(systemName: "questionmark")!

    case .systemSymbol(let name):
        return makeSystemSymbolImage(named: name)
            ?? UIImage(systemName: "questionmark")!

    case .symbolTile(let name, let color):
        return makeSymbolTileImage(named: name, color: color)
            ?? UIImage(systemName: "questionmark")!
    }
}

extension UIColor {
    // A color written "RRGGBB"; nil for anything else.
    convenience init?(rgbHex: String) {
        guard rgbHex.count == 6, let value = UInt32(rgbHex, radix: 16) else {
            return nil
        }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

// The SF Symbol `name` in dark grey on a square of `color`, the way a
// category shows in car lists. CarPlay rounds the corners itself. Nil when
// iOS has no symbol with that name.
func makeSymbolTileImage(named name: String, color: UIColor, side: CGFloat = 100) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: side * 0.4, weight: .medium)
    guard let symbol = UIImage(systemName: name, withConfiguration: config) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 3
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    // Wide symbols (e.g. two figures) shrink to keep the same margin.
    let fit = min(1, side * 0.5 / max(symbol.size.width, symbol.size.height))
    let size = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let frame = CGRect(
        x: (side - size.width) / 2,
        y: (side - size.height) / 2,
        width: size.width,
        height: size.height
    )
    let glyph = UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1)
    return UIGraphicsImageRenderer(bounds: canvas, format: format).image { context in
        color.setFill()
        context.fill(canvas)
        symbol.withTintColor(glyph, renderingMode: .alwaysOriginal).draw(in: frame)
    }
}

// An SF Symbol drawn for a car button: centered in a square of `canvas`
// points, in black for light car screens and white for dark ones. CarPlay
// picks the variant from the image asset, so it follows the car's
// appearance. Nil when iOS has no symbol with that name.
func makeSystemSymbolImage(named name: String, canvas: CGFloat = 40) -> UIImage? {
    let config = UIImage.SymbolConfiguration(pointSize: canvas * 0.55, weight: .medium)
    guard let symbol = UIImage(systemName: name, withConfiguration: config) else {
        return nil
    }
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 3
    let side = CGSize(width: canvas, height: canvas)
    // Wide symbols (e.g. two figures) shrink to keep the same margin.
    let fit = min(1, canvas * 0.72 / max(symbol.size.width, symbol.size.height))
    let size = CGSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
    let frame = CGRect(
        x: (canvas - size.width) / 2,
        y: (canvas - size.height) / 2,
        width: size.width,
        height: size.height
    )
    func draw(in color: UIColor) -> UIImage {
        let tinted = symbol.withTintColor(color, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: side, format: format).image { _ in
            tinted.draw(in: frame)
        }
    }
    // The scale is part of each variant's traits; without it the asset
    // hands out a 1x copy three times too large.
    func traits(_ style: UIUserInterfaceStyle) -> UITraitCollection {
        UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: style),
            UITraitCollection(displayScale: format.scale),
        ])
    }
    let asset = UIImageAsset()
    asset.register(draw(in: .black), with: traits(.light))
    asset.register(draw(in: .white), with: traits(.dark))
    return asset.image(with: traits(.dark))
}

// Downloads the image at `url`: nil when the request fails or the answer
// is not an image. `timeout` is how long the request may wait for data.
// Always calls completion on main thread.
func downloadUIImage(
    from url: URL,
    timeout: TimeInterval = 60,
    completion: @escaping (UIImage?) -> Void
) {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    let task = URLSession.shared.dataTask(with: request) { data, _, _ in
        let image = data.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async { completion(image) }
    }
    task.resume()
}

// Pictures a list can show at once, by image string. A row built while its
// picture is here shows it with the list: one set after the list reached
// the car shows up there about half a second later. So a category shows
// the station logos Home's rows loaded at launch as it slides in, and
// "Redate recent" the pictures loaded ahead of it. Main thread only.
enum FCPImageCache {
    // The bytes of each picture rather than the picture: a few KB each
    // instead of a decoded bitmap, so they can stay. Not an NSCache, which
    // iOS empties as the app goes to the background (the car screen on
    // another app, the phone locked): the next list would load its
    // pictures again, and show them late.
    private static var bytes: [String: Data] = [:]
    // Image strings, the least recently used first.
    private static var recent: [String] = []
    private static var total = 0
    // Room for a few hundred station logos and song pictures.
    private static let budget = 4 * 1024 * 1024

    // As for the app's own requests: a stalled download holds the list
    // back for seconds, not for URLSession's minute.
    private static let prefetchTimeout: TimeInterval = 8

    static func image(for image: String) -> UIImage? {
        guard let data = bytes[image] else { return nil }
        use(image)
        return UIImage(data: data)
    }

    // Loads the pictures of `images` not held yet, then calls `completion`
    // once each one loaded or failed.
    static func prefetch(_ images: [String], completion: @escaping () -> Void) {
        let group = DispatchGroup()
        for image in Set(images) where bytes[image] == nil {
            group.enter()
            load(image, timeout: prefetchTimeout) { _ in group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    // Loads the web or cached picture `image` and keeps it; calls
    // `completion` with nil when it fails or is no picture.
    static func load(
        _ image: String,
        timeout: TimeInterval = 60,
        completion: @escaping (UIImage?) -> Void
    ) {
        loadBytes(of: image, timeout: timeout) { data, uiImage in
            if let data = data, uiImage != nil {
                keep(data, for: image)
            }
            completion(uiImage)
        }
    }

    // Reads the bytes of `image` and makes the picture off the main
    // thread, then calls `completion` on it.
    private static func loadBytes(
        of image: String,
        timeout: TimeInterval,
        completion: @escaping (Data?, UIImage?) -> Void
    ) {
        let finish = { (data: Data?) in
            let uiImage = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async { completion(data, uiImage) }
        }
        switch image.toImageSource() {
        case .url(let url):
            var request = URLRequest(url: url)
            request.timeoutInterval = timeout
            URLSession.shared.dataTask(with: request) { data, _, _ in
                finish(data)
            }.resume()
        case .file(let path):
            DispatchQueue.global(qos: .userInitiated).async {
                finish(FileManager.default.contents(atPath: path))
            }
        case .flutterAsset, .systemSymbol, .symbolTile:
            // Bundled pictures, drawn on the spot.
            completion(nil, nil)
        }
    }

    private static func keep(_ data: Data, for image: String) {
        if let replaced = bytes.updateValue(data, forKey: image) {
            total -= replaced.count
        }
        total += data.count
        use(image)
        while total > budget, recent.count > 1 {
            let oldest = recent.removeFirst()
            total -= bytes.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    // Marks `image` as the most recently used.
    private static func use(_ image: String) {
        recent.removeAll { $0 == image }
        recent.append(image)
    }
}

// Image downloads that failed, run again when the app reports the internet
// is back (`retryFailedImages`). Main thread only.
enum FCPImageRetry {
    private static var pending: [() -> Void] = []

    static func add(_ retry: @escaping () -> Void) {
        pending.append(retry)
    }

    static func runAll() {
        let retries = pending
        pending.removeAll()
        retries.forEach { $0() }
    }
}

// Asynchronous image loader. Always calls completion on main thread.
@available(iOS 14.0, *)
func loadUIImageAsync(from source: ImageSource, completion: @escaping (UIImage?) -> Void) {
    switch source {
    case .url(let url):
        downloadUIImage(from: url) { image in
            completion(image ?? UIImage(systemName: "questionmark"))
        }

    case .file(let path):
        DispatchQueue.global(qos: .userInitiated).async {
            let image = UIImage(contentsOfFile: path) ?? UIImage(systemName: "questionmark")
            DispatchQueue.main.async { completion(image) }
        }

    case .flutterAsset(let name):
        // nil keeps the caller's placeholder (callers only set non-nil).
        DispatchQueue.main.async {
            completion(loadFlutterAssetImage(named: name))
        }

    case .systemSymbol(let name):
        DispatchQueue.main.async {
            completion(makeSystemSymbolImage(named: name))
        }

    case .symbolTile(let name, let color):
        DispatchQueue.main.async {
            completion(makeSymbolTileImage(named: name, color: color))
        }
    }
}

// Loads `image` for a row pinned above a list and calls `completion` on the
// main thread: the picture, or nil after a failed download, which runs
// again (calling `completion` again) on `retryFailedImages`. A missing
// asset never calls back, so the caller keeps its placeholder.
@available(iOS 14.0, *)
func loadRowImage(_ image: String, completion: @escaping (UIImage?) -> Void) {
    let source = image.toImageSource()
    guard case .url(let url) = source else {
        loadUIImageAsync(from: source) { uiImage in
            if let uiImage = uiImage { completion(uiImage) }
        }
        return
    }
    downloadUIImage(from: url) { uiImage in
        completion(uiImage)
        if uiImage == nil {
            FCPImageRetry.add { loadRowImage(image, completion: completion) }
        }
    }
}

// `image` cut to a centered square with rounded corners, the way CarPlay
// draws pictures in list rows (a radius of 9% of the side, measured on
// iOS 27). At most `maxSide` pixels a side, so large logos stay small.
func makeRoundedSquareImage(from image: UIImage, maxSide: CGFloat = 300) -> UIImage {
    let shortest = min(image.size.width, image.size.height)
    guard shortest > 0 else { return image }
    let side = min(shortest * image.scale, maxSide)
    let canvas = CGRect(x: 0, y: 0, width: side, height: side)
    let fill = side / shortest
    let drawn = CGSize(width: image.size.width * fill, height: image.size.height * fill)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = 1
    return UIGraphicsImageRenderer(bounds: canvas, format: format).image { _ in
        UIBezierPath(roundedRect: canvas, cornerRadius: side * 0.09).addClip()
        image.draw(in: CGRect(
            x: (side - drawn.width) / 2,
            y: (side - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        ))
    }
}

//  UIImage utilities (safe, UI only)
extension UIImage {
    func resizeImageTo(size: CGSize) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        draw(in: CGRect(origin: .zero, size: size))
        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
}

// Regex helper
extension String {
    func match(_ regex: String) -> [[String]] {
        let nsString = self as NSString
        return (try? NSRegularExpression(pattern: regex))?
            .matches(in: self, range: NSRange(location: 0, length: nsString.length))
            .map { match in
                (0..<match.numberOfRanges).map {
                    match.range(at: $0).location == NSNotFound
                    ? ""
                    : nsString.substring(with: match.range(at: $0))
                }
            } ?? []
    }
}
