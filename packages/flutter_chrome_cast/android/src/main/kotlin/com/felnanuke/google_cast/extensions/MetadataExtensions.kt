package com.felnanuke.google_cast.extensions


import android.net.Uri
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.common.images.WebImage
import java.util.*

class GoogleCastMetadataBuilder {
    companion object {

        /**
         * Maps Dart key names to the standard Cast SDK MediaMetadata key constants.
         * Without this mapping, putString("title", v) stores under a custom key
         * instead of MediaMetadata.KEY_TITLE, and the receiver never sees it as
         * a standard metadata field.
         */
        private val keyMapping = mapOf(
            "title" to MediaMetadata.KEY_TITLE,
            "subtitle" to MediaMetadata.KEY_SUBTITLE,
            "artist" to MediaMetadata.KEY_ARTIST,
            "albumArtist" to MediaMetadata.KEY_ALBUM_ARTIST,
            "albumName" to MediaMetadata.KEY_ALBUM_TITLE,
            "composer" to MediaMetadata.KEY_COMPOSER,
            "trackNumber" to MediaMetadata.KEY_TRACK_NUMBER,
            "discNumber" to MediaMetadata.KEY_DISC_NUMBER,
            "seasonNumber" to MediaMetadata.KEY_SEASON_NUMBER,
            "episodeNumber" to MediaMetadata.KEY_EPISODE_NUMBER,
            "seriesTitle" to MediaMetadata.KEY_SERIES_TITLE,
            "studio" to MediaMetadata.KEY_STUDIO,
            "width" to MediaMetadata.KEY_WIDTH,
            "height" to MediaMetadata.KEY_HEIGHT,
            "locationName" to MediaMetadata.KEY_LOCATION_NAME,
            "locationLatitude" to MediaMetadata.KEY_LOCATION_LATITUDE,
            "locationLongitude" to MediaMetadata.KEY_LOCATION_LONGITUDE,
        )

        private val dateKeys = setOf(
            "releaseDate",
            "broadcastDate",
            "creationDateTime",
            "creationDate"
        )

        private val skipKeys = setOf("metadataType", "images")

        fun fromMap(args: Map<String, Any?>): MediaMetadata? {

            val map = args.toMutableMap()
            if (map.isEmpty()) return null
            val type = (args["metadataType"] as? Number)?.toInt() ?: return null
            val metadata = MediaMetadata(type)

            for (item in map) {
                if (item.key in skipKeys) continue
                if (item.value == null) continue

                if (item.key in dateKeys) {
                    val millis = (item.value as? Number)?.toLong() ?: continue
                    val calendar = Calendar.getInstance()
                    calendar.timeInMillis = millis
                    when (item.key) {
                        "releaseDate" -> metadata.putDate(MediaMetadata.KEY_RELEASE_DATE, calendar)
                        "broadcastDate" -> metadata.putDate(MediaMetadata.KEY_BROADCAST_DATE, calendar)
                        "creationDateTime", "creationDate" -> metadata.putDate(MediaMetadata.KEY_CREATION_DATE, calendar)
                    }
                } else {
                    // Map Dart key to standard Cast SDK constant, fallback to raw key
                    val sdkKey = keyMapping[item.key] ?: item.key
                    val value = item.value
                    when (value) {
                        is String -> metadata.putString(sdkKey, value)
                        is Int -> metadata.putInt(sdkKey, value)
                        is Long -> metadata.putInt(sdkKey, value.toInt())
                        is Float -> metadata.putDouble(sdkKey, value.toDouble())
                        is Double -> metadata.putDouble(sdkKey, value)
                    }
                }
            }

            val imagesData = map["images"] as? List<Map<String, Any?>>
            if (imagesData != null) {
                for (imgMap in imagesData) {
                    metadata.addImage(imageFromMap(imgMap))
                }
            }
            return metadata
        }

        private fun imageFromMap(args: Map<String, Any?>): WebImage {
            val url = args["url"] as String
            val width = args["width"] as Int?
            val height = args["height"] as Int?
            return WebImage(Uri.parse(url), width ?: 250, height ?: 250)
        }
    }
}

fun MediaMetadata.toMap(): Map<String, Any?> {
    val map = mutableMapOf<String, Any?>()
    for (key in this.keySet()) {
        MediaMetadata.getTypeForKey(key)
    }
    return map
}