package com.oguzhnatly.flutter_android_auto

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.car.app.model.CarIcon
import androidx.core.graphics.drawable.IconCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val TAG = "FAAHelpers"

object FAAHelpers {
    fun makeFCPChannelId(event: String): String {
        return "com.oguzhnatly.flutter_android_auto" + event
    }
}

/**
 * Max number of HTTP redirects to follow when loading images.
 */
private const val MAX_REDIRECTS = 5

/**
 * Target size for Android Auto thumbnails (pixels).
 * Keeps bitmaps small to avoid OOM on older devices.
 */
private const val TARGET_SIZE = 128

/**
 * Loads a station thumbnail as a [CarIcon] from either a local file or network URL.
 *
 * Handles:
 * - `file://` and absolute paths → [BitmapFactory.decodeFile]
 * - `http://` / `https://` → [HttpURLConnection] with redirect following and User-Agent
 *
 * All bitmaps are down-scaled to [TARGET_SIZE]x[TARGET_SIZE] to reduce memory on older devices.
 * Returns `null` on any failure (logged at WARN level).
 */
suspend fun loadCarImageAsync(imageUrl: String): CarIcon? {
    return withContext(Dispatchers.IO) {
        try {
            val bitmap = if (imageUrl.startsWith("file://") || imageUrl.startsWith("/")) {
                loadFromFile(imageUrl)
            } else {
                loadFromNetwork(imageUrl)
            }
            if (bitmap != null) {
                val scaled = scaleBitmap(bitmap, TARGET_SIZE)
                val iconCompat = IconCompat.createWithBitmap(scaled)
                CarIcon.Builder(iconCompat).build()
            } else {
                Log.w(TAG, "loadCarImageAsync: decoded bitmap is null for $imageUrl")
                null
            }
        } catch (e: Exception) {
            Log.w(TAG, "loadCarImageAsync failed for $imageUrl", e)
            null
        }
    }
}

/**
 * Loads a bitmap from a local file path.
 * Accepts both `file:///path` and raw `/path` formats.
 */
private fun loadFromFile(imageUrl: String): Bitmap? {
    val filePath = if (imageUrl.startsWith("file://")) {
        imageUrl.removePrefix("file://")
    } else {
        imageUrl
    }
    val file = File(filePath)
    if (!file.exists()) {
        Log.w(TAG, "loadFromFile: file does not exist: $filePath")
        return null
    }
    return BitmapFactory.decodeFile(filePath)
}

/**
 * Loads a bitmap from a network URL, following up to [MAX_REDIRECTS] redirects.
 * Sets a User-Agent header (many CDNs reject requests without one).
 */
private fun loadFromNetwork(imageUrl: String): Bitmap? {
    var currentUrl = imageUrl
    var redirectCount = 0

    while (redirectCount < MAX_REDIRECTS) {
        val url = URL(currentUrl)
        val connection = url.openConnection() as HttpURLConnection
        connection.connectTimeout = 5000
        connection.readTimeout = 5000
        connection.doInput = true
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("User-Agent", "RadioCrestin-AndroidAuto/1.0")

        try {
            connection.connect()
            val responseCode = connection.responseCode

            if (responseCode in 300..399) {
                // Manual redirect follow (some older HttpURLConnection versions
                // don't follow cross-protocol redirects like http→https)
                val location = connection.getHeaderField("Location")
                connection.disconnect()
                if (location == null) {
                    Log.w(TAG, "loadFromNetwork: redirect $responseCode but no Location header for $currentUrl")
                    return null
                }
                currentUrl = location
                redirectCount++
                continue
            }

            if (responseCode != 200) {
                Log.w(TAG, "loadFromNetwork: HTTP $responseCode for $currentUrl")
                connection.disconnect()
                return null
            }

            val inputStream = connection.inputStream
            val result = BitmapFactory.decodeStream(inputStream)
            connection.disconnect()
            return result
        } catch (e: Exception) {
            connection.disconnect()
            throw e
        }
    }

    Log.w(TAG, "loadFromNetwork: too many redirects for $imageUrl")
    return null
}

/**
 * Scales a bitmap to fit within [maxSize]x[maxSize], preserving aspect ratio.
 * Returns the original bitmap if already small enough.
 */
private fun scaleBitmap(bitmap: Bitmap, maxSize: Int): Bitmap {
    val width = bitmap.width
    val height = bitmap.height
    if (width <= maxSize && height <= maxSize) return bitmap

    val ratio = minOf(maxSize.toFloat() / width, maxSize.toFloat() / height)
    val newWidth = (width * ratio).toInt().coerceAtLeast(1)
    val newHeight = (height * ratio).toInt().coerceAtLeast(1)
    return Bitmap.createScaledBitmap(bitmap, newWidth, newHeight, true)
}

