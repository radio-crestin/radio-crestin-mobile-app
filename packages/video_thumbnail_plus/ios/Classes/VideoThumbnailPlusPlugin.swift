import Flutter
import UIKit
import AVFoundation
import CryptoKit

/// Delivers a `FlutterResult` **exactly once** and **always on the platform
/// (main) thread**.
///
/// VENDORED PATCH — see PATCH.md. A `FlutterResult` must be invoked once, on
/// the platform thread; invoking it twice, or off-thread, corrupts the Flutter
/// message plumbing and can smash the Dart heap (the reported
/// `EXC_BAD_ACCESS` on a `DartWorker` thread). Upstream hopped to `main`
/// manually on the happy/error paths, but nothing *enforced* the invariant, so
/// any future edit or edge path (a stray second `result(...)`, a reply while
/// the thumbnail work is still resolving off-queue) could re-introduce the
/// corruption. This wrapper makes single, main-thread delivery guaranteed for
/// every code path.
private final class MainThreadReply {
    private var result: FlutterResult?
    private let lock = NSLock()

    init(_ result: @escaping FlutterResult) { self.result = result }

    /// Sends `value` to Flutter once. Subsequent calls are no-ops.
    func send(_ value: Any?) {
        lock.lock()
        guard let result = self.result else {
            lock.unlock()
            return
        }
        self.result = nil // never deliver twice
        lock.unlock()

        if Thread.isMainThread {
            result(value)
        } else {
            DispatchQueue.main.async { result(value) }
        }
    }
}

public class VideoThumbnailPlusPlugin: NSObject, FlutterPlugin {
    private static let FORMAT_JPEG = 0
    private static let FORMAT_PNG = 1
    private static let FORMAT_WEBP = 2

    private let queue = DispatchQueue(label: "world.nailao.video_thumbnail_plus", qos: .userInitiated)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "world.nailao.flutter.plugin/video_thumbnail_plus",
            binaryMessenger: registrar.messenger()
        )
        let instance = VideoThumbnailPlusPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result rawResult: @escaping FlutterResult) {
        // Every reply for this call flows through `reply`, which guarantees a
        // single, main-thread delivery (see `MainThreadReply` / PATCH.md).
        let reply = MainThreadReply(rawResult)
        let result: FlutterResult = { reply.send($0) }

        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "INVALID_ARGS", message: "Invalid arguments", details: nil))
            return
        }

        switch call.method {
        case "file":
            handleThumbnailFile(args: args, result: result)
        case "data":
            handleThumbnailData(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func handleThumbnailFile(args: [String: Any], result: @escaping FlutterResult) {
        guard let video = args["video"] as? String, !video.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Video path or URL is required", details: nil))
            return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        let path = args["path"] as? String ?? ""
        let format = args["format"] as? Int ?? VideoThumbnailPlusPlugin.FORMAT_PNG
        let maxHeight = args["maxh"] as? Int ?? 0
        let maxWidth = args["maxw"] as? Int ?? 0
        let timeMs = max(0, args["timeMs"] as? Int ?? 0)
        let quality = min(100, max(0, args["quality"] as? Int ?? 100))

        queue.async {
            do {
                let filePath = try self.generateThumbnailFile(
                    video: video,
                    headers: headers,
                    path: path,
                    format: format,
                    maxHeight: maxHeight,
                    maxWidth: maxWidth,
                    timeMs: timeMs,
                    quality: quality
                )
                // `result` is a `MainThreadReply` — it hops to main itself.
                result(filePath)
            } catch {
                result(FlutterError(code: "THUMBNAIL_ERROR", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func handleThumbnailData(args: [String: Any], result: @escaping FlutterResult) {
        guard let video = args["video"] as? String, !video.isEmpty else {
            result(FlutterError(code: "INVALID_ARGUMENT", message: "Video path or URL is required", details: nil))
            return
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        let format = args["format"] as? Int ?? VideoThumbnailPlusPlugin.FORMAT_PNG
        let maxHeight = args["maxh"] as? Int ?? 0
        let maxWidth = args["maxw"] as? Int ?? 0
        let timeMs = max(0, args["timeMs"] as? Int ?? 0)
        let quality = min(100, max(0, args["quality"] as? Int ?? 100))

        queue.async {
            do {
                let data = try self.generateThumbnailData(
                    video: video,
                    headers: headers,
                    format: format,
                    maxHeight: maxHeight,
                    maxWidth: maxWidth,
                    timeMs: timeMs,
                    quality: quality
                )
                // `result` is a `MainThreadReply` — it hops to main itself.
                result(FlutterStandardTypedData(bytes: data))
            } catch {
                result(FlutterError(code: "THUMBNAIL_ERROR", message: error.localizedDescription, details: nil))
            }
        }
    }

    private func generateThumbnailFile(
        video: String,
        headers: [String: String],
        path: String,
        format: Int,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int
    ) throws -> String {
        guard let image = try createThumbnail(
            video: video,
            headers: headers,
            maxHeight: maxHeight,
            maxWidth: maxWidth,
            timeMs: timeMs
        ) else {
            throw NSError(domain: "VideoThumbnailPlus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail"])
        }

        let fileExtension: String
        let imageData: Data?

        switch format {
        case VideoThumbnailPlusPlugin.FORMAT_JPEG:
            fileExtension = "jpg"
            imageData = image.jpegData(compressionQuality: CGFloat(quality) / 100.0)
        case VideoThumbnailPlusPlugin.FORMAT_PNG:
            fileExtension = "png"
            imageData = image.pngData()
        case VideoThumbnailPlusPlugin.FORMAT_WEBP:
            // iOS doesn't have native WebP encoding support, fallback to PNG with correct extension
            fileExtension = "png"
            imageData = image.pngData()
        default:
            fileExtension = "png"
            imageData = image.pngData()
        }

        guard let data = imageData else {
            throw NSError(domain: "VideoThumbnailPlus", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }

        let outputDir: URL
        if !path.isEmpty {
            outputDir = URL(fileURLWithPath: path)
        } else {
            guard let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
                throw NSError(domain: "VideoThumbnailPlus", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to get cache directory"])
            }
            outputDir = cacheDir.appendingPathComponent("video_thumbnails")
        }

        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true, attributes: nil)

        let fileName = "\(md5(video))_\(timeMs).\(fileExtension)"
        let outputFile = outputDir.appendingPathComponent(fileName)

        try data.write(to: outputFile)

        return outputFile.path
    }

    private func generateThumbnailData(
        video: String,
        headers: [String: String],
        format: Int,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int
    ) throws -> Data {
        guard let image = try createThumbnail(
            video: video,
            headers: headers,
            maxHeight: maxHeight,
            maxWidth: maxWidth,
            timeMs: timeMs
        ) else {
            throw NSError(domain: "VideoThumbnailPlus", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to generate thumbnail"])
        }

        let imageData: Data?

        switch format {
        case VideoThumbnailPlusPlugin.FORMAT_JPEG:
            imageData = image.jpegData(compressionQuality: CGFloat(quality) / 100.0)
        case VideoThumbnailPlusPlugin.FORMAT_PNG:
            imageData = image.pngData()
        case VideoThumbnailPlusPlugin.FORMAT_WEBP:
            // iOS doesn't have native WebP support, fallback to PNG
            imageData = image.pngData()
        default:
            imageData = image.pngData()
        }

        guard let data = imageData else {
            throw NSError(domain: "VideoThumbnailPlus", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }

        return data
    }

    private func createThumbnail(
        video: String,
        headers: [String: String],
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int
    ) throws -> UIImage? {
        let videoURL: URL

        if video.hasPrefix("http://") || video.hasPrefix("https://") {
            guard let url = URL(string: video) else {
                throw NSError(domain: "VideoThumbnailPlus", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
            }
            videoURL = url
        } else if video.hasPrefix("file://") {
            videoURL = URL(fileURLWithPath: String(video.dropFirst(7)))
        } else {
            videoURL = URL(fileURLWithPath: video)
        }

        let asset: AVAsset
        if !headers.isEmpty {
            asset = AVURLAsset(url: videoURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        } else {
            asset = AVAsset(url: videoURL)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Use default tolerance for better performance; .zero would require exact frame decoding
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)

        if maxWidth > 0 || maxHeight > 0 {
            let width = maxWidth > 0 ? maxWidth : maxHeight
            let height = maxHeight > 0 ? maxHeight : maxWidth
            generator.maximumSize = CGSize(width: width, height: height)
        }

        let time = CMTime(value: CMTimeValue(timeMs), timescale: 1000)

        do {
            let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
            return UIImage(cgImage: cgImage)
        } catch {
            throw error
        }
    }

    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
