package com.radiocrestin.radio_crestin

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.tvprovider.media.tv.PreviewChannel
import androidx.tvprovider.media.tv.PreviewChannelHelper
import androidx.tvprovider.media.tv.PreviewProgram
import androidx.tvprovider.media.tv.TvContractCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.net.URL

data class StationDto(
    val slug: String,
    val title: String,
    val thumbnailUrl: String?,
    val songTitle: String?
)

class TvChannelManager(private val context: Context) {

    companion object {
        private const val TAG = "TvChannelManager"
        private const val CHANNEL_INTERNAL_ID = "radio_crestin_favorites_v1"
        private const val IMAGE_DIR = "tv_channel_images"
        private const val POSTER_WIDTH = 320
        private const val POSTER_HEIGHT = 180
    }

    private val helper = PreviewChannelHelper(context)
    private val imageDir: File by lazy {
        File(context.filesDir, IMAGE_DIR).apply { mkdirs() }
    }

    /**
     * Synchronize a "Favorite Stations" channel with the given station list.
     * Creates the channel if it doesn't exist, upserts programs, and removes stale ones.
     */
    suspend fun syncChannel(stations: List<StationDto>) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (stations.isEmpty()) {
            deleteChannel()
            return
        }

        try {
            val channelId = getOrCreateChannel() ?: return

            val existingPrograms = queryExistingPrograms(channelId)
            val currentSlugs = stations.map { it.slug }.toSet()

            // Insert only new programs (skip existing ones to avoid redundant I/O)
            for (station in stations) {
                if (station.slug in existingPrograms) continue
                try {
                    val posterUri = downloadAndCacheImage(station.thumbnailUrl, station.slug)
                    val program = buildProgram(channelId, station, posterUri)
                    withContext(Dispatchers.IO) {
                        helper.publishPreviewProgram(program)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to insert program for ${station.slug}", e)
                }
            }

            // Delete programs for stations that no longer exist
            for ((slug, programId) in existingPrograms) {
                if (slug !in currentSlugs) {
                    try {
                        withContext(Dispatchers.IO) {
                            context.contentResolver.delete(
                                TvContractCompat.buildPreviewProgramUri(programId),
                                null, null
                            )
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to delete program $slug", e)
                    }
                }
            }

            Log.d(TAG, "Channel synced: ${stations.size} programs")
        } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException - WRITE_EPG_DATA permission missing?", e)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to sync channel", e)
        }
    }

    /**
     * Delete the channel and all its programs.
     */
    suspend fun deleteChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val channelId = findExistingChannel() ?: return
            withContext(Dispatchers.IO) {
                context.contentResolver.delete(
                    TvContractCompat.buildChannelUri(channelId),
                    null, null
                )
            }
            Log.d(TAG, "Channel deleted")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to delete channel", e)
        }
    }

    private suspend fun getOrCreateChannel(): Long? {
        val existing = findExistingChannel()
        if (existing != null) return existing

        return try {
            val logoFile = File(imageDir, "channel_logo.png")
            val logoBitmap = createChannelLogo()
            withContext(Dispatchers.IO) {
                FileOutputStream(logoFile).use { out ->
                    logoBitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                }
            }

            val channel = PreviewChannel.Builder()
                .setDisplayName("Radio Crestin")
                .setDescription("Stații radio creștine favorite")
                .setInternalProviderId(CHANNEL_INTERNAL_ID)
                .setLogo(Uri.fromFile(logoFile))
                // The TV provider rejects channels without an app-link intent
                // URI ("Need app link intent uri for channel"). Tapping the
                // channel header opens the app at the launcher; individual
                // programs override with their own per-station deeplink.
                .setAppLinkIntentUri(Uri.parse("radiocrestin://"))
                .build()

            val channelId = withContext(Dispatchers.IO) {
                helper.publishChannel(channel)
            }
            TvContractCompat.requestChannelBrowsable(context, channelId)
            Log.d(TAG, "Channel created with id=$channelId")
            channelId
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create channel", e)
            null
        }
    }

    private suspend fun findExistingChannel(): Long? = withContext(Dispatchers.IO) {
        try {
            val channels = helper.allChannels
            channels.firstOrNull { it.internalProviderId == CHANNEL_INTERNAL_ID }?.id
        } catch (e: Exception) {
            Log.e(TAG, "Failed to query channels", e)
            null
        }
    }

    /**
     * Query all existing programs for a channel, returning a map of internalProviderId -> programId.
     */
    private suspend fun queryExistingPrograms(channelId: Long): Map<String, Long> =
        withContext(Dispatchers.IO) {
            val result = mutableMapOf<String, Long>()
            try {
                val cursor = context.contentResolver.query(
                    TvContractCompat.PreviewPrograms.CONTENT_URI,
                    arrayOf(
                        TvContractCompat.PreviewPrograms._ID,
                        TvContractCompat.PreviewPrograms.COLUMN_INTERNAL_PROVIDER_ID,
                        TvContractCompat.PreviewPrograms.COLUMN_CHANNEL_ID
                    ),
                    null, null, null
                )
                cursor?.use {
                    while (it.moveToNext()) {
                        val progChannelId = it.getLong(
                            it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms.COLUMN_CHANNEL_ID)
                        )
                        if (progChannelId == channelId) {
                            val id = it.getLong(
                                it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms._ID)
                            )
                            val internalId = it.getString(
                                it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms.COLUMN_INTERNAL_PROVIDER_ID)
                            )
                            if (internalId != null) {
                                result[internalId] = id
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to query programs", e)
            }
            result
        }

    private fun buildProgram(channelId: Long, station: StationDto, posterUri: Uri?): PreviewProgram {
        val intentUri = Uri.parse("radiocrestin://${station.slug}")

        val builder = PreviewProgram.Builder()
            .setChannelId(channelId)
            .setType(TvContractCompat.PreviewPrograms.TYPE_CLIP)
            .setLive(true)
            .setTitle(station.title)
            .setInternalProviderId(station.slug)
            .setIntentUri(intentUri)

        if (station.songTitle?.isNotEmpty() == true) {
            builder.setDescription(station.songTitle)
        }

        if (posterUri != null) {
            builder.setPosterArtUri(posterUri)
                .setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_16_9)
        }

        return builder.build()
    }

    /**
     * Download station thumbnail and create a 16:9 poster with the logo centered on a dark background.
     * Skips download if the poster is already cached on disk.
     */
    private suspend fun downloadAndCacheImage(url: String?, slug: String): Uri? {
        if (url.isNullOrEmpty()) return null

        val outFile = File(imageDir, "${slug}.jpg")

        // Skip download if already cached
        if (outFile.exists() && outFile.length() > 0) {
            return Uri.fromFile(outFile)
        }

        return withContext(Dispatchers.IO) {
            try {
                val actualUrl = if (url.startsWith("file://")) {
                    val localFile = File(url.removePrefix("file://"))
                    if (localFile.exists()) {
                        return@withContext Uri.fromFile(localFile)
                    }
                    return@withContext null
                } else {
                    url
                }

                val bitmap = BitmapFactory.decodeStream(URL(actualUrl).openStream())
                    ?: return@withContext null

                // Create 16:9 poster with station logo centered on dark background
                val poster = Bitmap.createBitmap(POSTER_WIDTH, POSTER_HEIGHT, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(poster)
                canvas.drawColor(Color.parseColor("#1E1E1E"))

                // Scale logo to fit, maintaining aspect ratio
                val logoSize = (POSTER_HEIGHT * 0.7f).toInt()
                val scaledBitmap = Bitmap.createScaledBitmap(bitmap, logoSize, logoSize, true)
                val left = (POSTER_WIDTH - logoSize) / 2f
                val top = (POSTER_HEIGHT - logoSize) / 2f
                canvas.drawBitmap(scaledBitmap, left, top, null)

                scaledBitmap.recycle()
                bitmap.recycle()

                FileOutputStream(outFile).use { out ->
                    poster.compress(Bitmap.CompressFormat.JPEG, 90, out)
                }
                poster.recycle()

                Uri.fromFile(outFile)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to download image for $slug: $url", e)
                null
            }
        }
    }

    /**
     * Create a simple channel logo bitmap (brand pink with fish icon).
     */
    private fun createChannelLogo(): Bitmap {
        val size = 80
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.color = Color.parseColor("#FD0057")
        canvas.drawRoundRect(RectF(0f, 0f, size.toFloat(), size.toFloat()), 12f, 12f, paint)
        return bitmap
    }
}
