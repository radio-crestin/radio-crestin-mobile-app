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
}

// String → ImageSource
extension String {
    func toImageSource() -> ImageSource {
        if self.hasPrefix("sf:") {
            return .systemSymbol(String(self.dropFirst(3)))
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
// is not an image. Always calls completion on main thread.
func downloadUIImage(from url: URL, completion: @escaping (UIImage?) -> Void) {
    let task = URLSession.shared.dataTask(with: url) { data, _, _ in
        let image = data.flatMap { UIImage(data: $0) }
        DispatchQueue.main.async { completion(image) }
    }
    task.resume()
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
