package com.radiocrestin.radio_crestin

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
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

        // Posters older versions composed into IMAGE_DIR; swept once per
        // process (a new manager is created for every sync call).
        @Volatile
        private var legacyPostersDeleted = false
    }

    /** The launcher-visible fields of a stored program, diffed before updating. */
    private data class ExistingProgram(
        val id: Long,
        val title: String?,
        val description: String?,
        val posterArtUri: String?
    ) {
        fun differsFrom(program: PreviewProgram): Boolean =
            title != program.title ||
                description != program.description ||
                posterArtUri != program.posterArtUri?.toString()
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

            // Insert new programs; update existing ones only when something the
            // launcher shows changed (skips redundant provider writes). The
            // update also migrates posters older versions stored as
            // app-private file:// URIs, which the launcher can't read.
            for (station in stations) {
                try {
                    val program = buildProgram(channelId, station)
                    val existing = existingPrograms[station.slug]
                    if (existing == null) {
                        withContext(Dispatchers.IO) {
                            helper.publishPreviewProgram(program)
                        }
                    } else if (existing.differsFrom(program)) {
                        withContext(Dispatchers.IO) {
                            helper.updatePreviewProgram(existing.id, program)
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to upsert program for ${station.slug}", e)
                }
            }

            // Delete programs for stations that no longer exist
            for ((slug, existing) in existingPrograms) {
                if (slug !in currentSlugs) {
                    try {
                        withContext(Dispatchers.IO) {
                            context.contentResolver.delete(
                                TvContractCompat.buildPreviewProgramUri(existing.id),
                                null, null
                            )
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to delete program $slug", e)
                    }
                }
            }

            deleteLegacyPosters()
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
     * Query all existing programs for a channel, keyed by internalProviderId (the station slug).
     */
    private suspend fun queryExistingPrograms(channelId: Long): Map<String, ExistingProgram> =
        withContext(Dispatchers.IO) {
            val result = mutableMapOf<String, ExistingProgram>()
            try {
                val cursor = context.contentResolver.query(
                    TvContractCompat.PreviewPrograms.CONTENT_URI,
                    arrayOf(
                        TvContractCompat.PreviewPrograms._ID,
                        TvContractCompat.PreviewPrograms.COLUMN_INTERNAL_PROVIDER_ID,
                        TvContractCompat.PreviewPrograms.COLUMN_CHANNEL_ID,
                        TvContractCompat.PreviewPrograms.COLUMN_TITLE,
                        TvContractCompat.PreviewPrograms.COLUMN_SHORT_DESCRIPTION,
                        TvContractCompat.PreviewPrograms.COLUMN_POSTER_ART_URI
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
                                result[internalId] = ExistingProgram(
                                    id = id,
                                    title = it.getString(
                                        it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms.COLUMN_TITLE)
                                    ),
                                    description = it.getString(
                                        it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms.COLUMN_SHORT_DESCRIPTION)
                                    ),
                                    posterArtUri = it.getString(
                                        it.getColumnIndexOrThrow(TvContractCompat.PreviewPrograms.COLUMN_POSTER_ART_URI)
                                    )
                                )
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to query programs", e)
            }
            result
        }

    private fun buildProgram(channelId: Long, station: StationDto): PreviewProgram {
        val intentUri = Uri.parse("radiocrestin://${station.slug}")
        // The launcher (another app) fetches the poster itself, so it must be
        // a URL it can load, never a file in this app's private storage.
        val posterUri = station.thumbnailUrl
            ?.takeIf { it.startsWith("http") }
            ?.let { Uri.parse(it) }

        return PreviewProgram.Builder()
            .setChannelId(channelId)
            .setType(TvContractCompat.PreviewPrograms.TYPE_CLIP)
            .setLive(true)
            .setTitle(station.title)
            // No song line: syncs follow catalog changes only, so it would go
            // stale. Explicit null clears the one older versions stored.
            .setDescription(null)
            .setPosterArtUri(posterUri)
            .setPosterArtAspectRatio(TvContractCompat.PreviewPrograms.ASPECT_RATIO_1_1)
            .setInternalProviderId(station.slug)
            .setIntentUri(intentUri)
            .build()
    }

    /**
     * Delete the composed 16:9 posters older versions cached; nothing reads
     * them anymore. The channel logo (PNG) in the same directory is kept.
     */
    private suspend fun deleteLegacyPosters() {
        if (legacyPostersDeleted) return
        legacyPostersDeleted = true
        withContext(Dispatchers.IO) {
            try {
                imageDir.listFiles()
                    ?.filter { it.name.endsWith(".jpg") }
                    ?.forEach { it.delete() }
            } catch (e: Exception) {
                Log.w(TAG, "Failed to delete legacy posters", e)
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
