package world.nailao.video_thumbnail_plus

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/** VideoThumbnailPlusPlugin */
class VideoThumbnailPlusPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val executor: ExecutorService = ThreadPoolExecutor(
        0, 4, 60L, TimeUnit.SECONDS, LinkedBlockingQueue()
    )
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Set once the engine detaches; guards against delivering a stale reply. */
    @Volatile
    private var detached = false

    companion object {
        private const val FORMAT_JPEG = 0
        private const val FORMAT_PNG = 1
        private const val FORMAT_WEBP = 2
    }

    /**
     * Delivers a [Result] **exactly once**, **always on the platform (main)
     * thread**, and **never after the engine detaches**.
     *
     * VENDORED PATCH — see PATCH.md. A method-channel [Result] must be invoked
     * once, on the platform thread; a double invocation, an off-thread
     * invocation, or a reply after the engine tore down corrupts the Flutter
     * message plumbing and can smash the Dart heap (the reported
     * `EXC_BAD_ACCESS` on a `DartWorker` thread). This app runs several Flutter
     * engines (CarPlay / Android Auto) that attach and detach independently, so
     * an in-flight decode finishing after its engine detached is a real path.
     * The [AtomicReference] makes single delivery atomic across the decode
     * threads, and [detached] drops any reply whose engine is already gone.
     */
    private inner class MainThreadReply(result: Result) {
        private val ref = AtomicReference<Result?>(result)

        fun success(value: Any?) = deliver { it.success(value) }

        fun error(code: String, message: String?, details: Any?) =
            deliver { it.error(code, message, details) }

        fun notImplemented() = deliver { it.notImplemented() }

        private fun deliver(block: (Result) -> Unit) {
            val r = ref.getAndSet(null) ?: return // already delivered
            mainHandler.post {
                if (!detached) block(r)
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            "world.nailao.flutter.plugin/video_thumbnail_plus"
        )
        channel.setMethodCallHandler(this)
        context = flutterPluginBinding.applicationContext
        detached = false
    }

    override fun onMethodCall(call: MethodCall, rawResult: Result) {
        val result = MainThreadReply(rawResult)
        when (call.method) {
            "file" -> {
                val video = call.argument<String>("video")
                if (video.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Video path or URL is required", null)
                    return
                }
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val path = call.argument<String>("path") ?: ""
                val format = call.argument<Int>("format") ?: FORMAT_PNG
                val maxHeight = call.argument<Int>("maxh") ?: 0
                val maxWidth = call.argument<Int>("maxw") ?: 0
                val timeMs = (call.argument<Int>("timeMs") ?: 0).coerceAtLeast(0)
                val quality = (call.argument<Int>("quality") ?: 100).coerceIn(0, 100)

                executor.execute {
                    try {
                        val filePath = generateThumbnailFile(
                            video, headers, path, format, maxHeight, maxWidth, timeMs, quality
                        )
                        // `result` (MainThreadReply) posts to main itself.
                        result.success(filePath)
                    } catch (e: Exception) {
                        result.error("THUMBNAIL_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            }
            "data" -> {
                val video = call.argument<String>("video")
                if (video.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "Video path or URL is required", null)
                    return
                }
                val headers = call.argument<Map<String, String>>("headers") ?: emptyMap()
                val format = call.argument<Int>("format") ?: FORMAT_PNG
                val maxHeight = call.argument<Int>("maxh") ?: 0
                val maxWidth = call.argument<Int>("maxw") ?: 0
                val timeMs = (call.argument<Int>("timeMs") ?: 0).coerceAtLeast(0)
                val quality = (call.argument<Int>("quality") ?: 100).coerceIn(0, 100)

                executor.execute {
                    try {
                        val data = generateThumbnailData(
                            video, headers, format, maxHeight, maxWidth, timeMs, quality
                        )
                        // `result` (MainThreadReply) posts to main itself.
                        result.success(data)
                    } catch (e: Exception) {
                        result.error("THUMBNAIL_ERROR", e.message ?: "Unknown error", null)
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun generateThumbnailFile(
        video: String,
        headers: Map<String, String>,
        path: String,
        format: Int,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int
    ): String {
        val bitmap = createThumbnail(video, headers, maxHeight, maxWidth, timeMs)
            ?: throw IllegalStateException("Failed to extract frame from video")

        val extension = when (format) {
            FORMAT_JPEG -> "jpg"
            FORMAT_PNG -> "png"
            FORMAT_WEBP -> "webp"
            else -> "png"
        }

        val outputDir = if (path.isNotEmpty()) {
            File(path)
        } else {
            File(context.cacheDir, "video_thumbnails")
        }

        if (!outputDir.exists() && !outputDir.mkdirs()) {
            bitmap.recycle()
            throw IllegalStateException("Failed to create output directory: ${outputDir.absolutePath}")
        }

        val fileName = "${md5(video)}_${timeMs}.$extension"
        val outputFile = File(outputDir, fileName)

        try {
            FileOutputStream(outputFile).use { fos ->
                val compressFormat = when (format) {
                    FORMAT_JPEG -> Bitmap.CompressFormat.JPEG
                    FORMAT_PNG -> Bitmap.CompressFormat.PNG
                    FORMAT_WEBP -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Bitmap.CompressFormat.WEBP_LOSSY
                    } else {
                        @Suppress("DEPRECATION")
                        Bitmap.CompressFormat.WEBP
                    }
                    else -> Bitmap.CompressFormat.PNG
                }
                if (!bitmap.compress(compressFormat, quality, fos)) {
                    throw IllegalStateException("Failed to compress bitmap")
                }
            }
        } finally {
            bitmap.recycle()
        }

        return outputFile.absolutePath
    }

    private fun generateThumbnailData(
        video: String,
        headers: Map<String, String>,
        format: Int,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int,
        quality: Int
    ): ByteArray {
        val bitmap = createThumbnail(video, headers, maxHeight, maxWidth, timeMs)
            ?: throw IllegalStateException("Failed to extract frame from video")

        try {
            val outputStream = ByteArrayOutputStream()
            val compressFormat = when (format) {
                FORMAT_JPEG -> Bitmap.CompressFormat.JPEG
                FORMAT_PNG -> Bitmap.CompressFormat.PNG
                FORMAT_WEBP -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Bitmap.CompressFormat.WEBP_LOSSY
                } else {
                    @Suppress("DEPRECATION")
                    Bitmap.CompressFormat.WEBP
                }
                else -> Bitmap.CompressFormat.PNG
            }

            if (!bitmap.compress(compressFormat, quality, outputStream)) {
                throw IllegalStateException("Failed to compress bitmap")
            }

            return outputStream.toByteArray()
        } finally {
            bitmap.recycle()
        }
    }

    private fun createThumbnail(
        video: String,
        headers: Map<String, String>,
        maxHeight: Int,
        maxWidth: Int,
        timeMs: Int
    ): Bitmap? {
        val retriever = MediaMetadataRetriever()

        try {
            when {
                video.startsWith("http://") || video.startsWith("https://") -> {
                    retriever.setDataSource(video, headers)
                }
                video.startsWith("content://") -> {
                    retriever.setDataSource(context, Uri.parse(video))
                }
                video.startsWith("file://") -> {
                    retriever.setDataSource(video.substring(7))
                }
                else -> {
                    retriever.setDataSource(video)
                }
            }

            val timeUs = timeMs.toLong() * 1000L

            var bitmap: Bitmap? = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)

            if (bitmap != null && (maxWidth > 0 || maxHeight > 0)) {
                bitmap = scaleBitmap(bitmap, maxWidth, maxHeight)
            }

            return bitmap
        } finally {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                try {
                    retriever.close()
                } catch (e: Exception) {
                    // Ignore close errors
                }
            } else {
                try {
                    @Suppress("DEPRECATION")
                    retriever.release()
                } catch (e: Exception) {
                    // Ignore release errors
                }
            }
        }
    }

    private fun scaleBitmap(bitmap: Bitmap, maxWidth: Int, maxHeight: Int): Bitmap {
        val width = bitmap.width
        val height = bitmap.height

        if (maxWidth <= 0 && maxHeight <= 0) {
            return bitmap
        }

        val targetWidth: Int
        val targetHeight: Int

        if (maxWidth > 0 && maxHeight > 0) {
            val widthRatio = maxWidth.toFloat() / width
            val heightRatio = maxHeight.toFloat() / height
            val ratio = minOf(widthRatio, heightRatio)
            targetWidth = maxOf(1, (width * ratio).toInt())
            targetHeight = maxOf(1, (height * ratio).toInt())
        } else if (maxWidth > 0) {
            val ratio = maxWidth.toFloat() / width
            targetWidth = maxWidth
            targetHeight = maxOf(1, (height * ratio).toInt())
        } else {
            val ratio = maxHeight.toFloat() / height
            targetWidth = maxOf(1, (width * ratio).toInt())
            targetHeight = maxHeight
        }

        val scaledBitmap = Bitmap.createScaledBitmap(bitmap, targetWidth, targetHeight, true)
        if (scaledBitmap != bitmap) {
            bitmap.recycle()
        }
        return scaledBitmap
    }

    private fun md5(input: String): String {
        val md = MessageDigest.getInstance("MD5")
        val digest = md.digest(input.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached = true // in-flight decodes must not deliver to a dead messenger
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
