package com.radiocrestin.radio_crestin

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.app.FlutterApplication

/**
 * Starts Flutter with the Skia renderer instead of Impeller when the app
 * asked for it at the previous launch (`lib/services/android_renderer.dart`).
 *
 * On some cheap car head units and tablets, Impeller's Vulkan driver makes
 * the screen flicker or go black; Skia on OpenGL is slower but stable there.
 *
 * The renderer is fixed when Flutter's loader initializes, once per process.
 * Doing it here, before any engine exists (audio_service creates the one the
 * activity and Android Auto share), makes this initialization the first:
 * every later `ensureInitializationComplete` returns at once, without
 * touching the arguments. Otherwise nothing changes from Flutter's default.
 */
class MainApplication : FlutterApplication() {

    override fun onCreate() {
        super.onCreate()
        if (stableRendererRequested()) startFlutterWithSkia()
        createAnnouncementsChannel()
    }

    /**
     * The channel the backend's announcement pushes name
     * (`android.notification.channel_id = announcements`); without it,
     * Android files them under FCM's "Miscellaneous".
     */
    private fun createAnnouncementsChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        try {
            val channel = NotificationChannel(
                ANNOUNCEMENTS_CHANNEL_ID,
                getString(R.string.announcements_channel_name),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = getString(R.string.announcements_channel_description)
            }
            getSystemService(NotificationManager::class.java)
                ?.createNotificationChannel(channel)
        } catch (e: Exception) {
            Log.w(TAG, "Could not create the announcements channel", e)
        }
    }

    private fun stableRendererRequested(): Boolean = try {
        getSharedPreferences(FLUTTER_PREFERENCES, Context.MODE_PRIVATE)
            .getBoolean(USE_SKIA_KEY, false)
    } catch (e: Exception) {
        Log.w(TAG, "Could not read the renderer choice; Impeller stays", e)
        false
    }

    // Never stops the app from starting: if this fails, the first engine
    // initializes Flutter as usual, with Impeller.
    private fun startFlutterWithSkia() {
        try {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(this)
            loader.ensureInitializationComplete(this, arrayOf(DISABLE_IMPELLER))
            Log.i(TAG, "Flutter starts with Skia ($USE_SKIA_KEY)")
        } catch (e: Throwable) {
            Log.w(TAG, "Could not start Flutter with Skia; Impeller stays", e)
        }
    }

    private companion object {
        const val TAG = "RadioCrestinRenderer"

        /** The announcements spec's Android channel. */
        const val ANNOUNCEMENTS_CHANNEL_ID = "announcements"

        /** The file the shared_preferences plugin's legacy API writes. */
        const val FLUTTER_PREFERENCES = "FlutterSharedPreferences"

        /** `AndroidRenderer.useSkiaKey`, with the plugin's `flutter.` prefix. */
        const val USE_SKIA_KEY = "flutter.android_renderer_use_skia"

        /** Allowed in release builds; overrides the manifest. */
        const val DISABLE_IMPELLER = "--enable-impeller=false"
    }
}
