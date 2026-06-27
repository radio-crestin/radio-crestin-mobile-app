package com.radiocrestin.radio_crestin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import com.oguzhnatly.flutter_android_auto.FAAConstants
import com.ryanheise.audioservice.AudioServiceActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class MainActivity : AudioServiceActivity() {

    private val tvChannelScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // Snapshot of the launch intent flags taken in onCreate, BEFORE any
    // onNewIntent or setIntent() can replace getIntent(). Used by the
    // "getLaunchSource" method channel so Flutter can suppress autoplay
    // when the cold start originated from the recents list rather than
    // a launcher icon tap.
    private var launchedFromHistory: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        launchedFromHistory =
            (intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0
        suppressAudioNotificationOnTv()
    }

    // On Android TV, pre-create the audio_service notification channel at
    // IMPORTANCE_MIN BEFORE the audio foreground service starts. audio_service
    // creates the channel only if it doesn't already exist, so ours wins: the
    // foreground service (and therefore continuous playback) keeps working, but
    // the ongoing media notification is kept off-screen on TV. We use a TV-only
    // channel id (matching AudioServiceConfig on the Dart side) so this also
    // applies to existing installs — a channel's importance can't be lowered
    // once created. Phones are untouched and keep the normal media notification.
    private fun suppressAudioNotificationOnTv() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (!isRunningOnTv()) return
        val channelId = "$packageName.channel.tv"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(channelId) != null) return
        val channel = NotificationChannel(
            channelId,
            "Radio Crestin",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            setShowBadge(false)
            lockscreenVisibility = Notification.VISIBILITY_SECRET
            enableLights(false)
            enableVibration(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun isRunningOnTv(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature("android.software.leanback") ||
            packageManager.hasSystemFeature("android.hardware.type.television")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Cache the engine so CarPlay/Android Auto plugin can reuse it.
        FlutterEngineCache.getInstance()
            .put(FAAConstants.flutterEngineId, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.radiocrestin.app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bringToForeground" -> {
                        val intent = packageManager.getLaunchIntentForPackage(packageName)
                        if (intent != null) {
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    "getLaunchSource" -> {
                        result.success(if (launchedFromHistory) "recents" else "launcher")
                    }
                    else -> result.notImplemented()
                }
            }

        // Android TV home screen channels
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.radiocrestin.tv_channels")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "syncFavoriteChannel" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val stationsData = call.arguments as? List<*>
                        if (stationsData == null) {
                            result.error("INVALID_ARGS", "Expected list of station maps", null)
                            return@setMethodCallHandler
                        }
                        val stations = stationsData.mapNotNull { item ->
                            val map = item as? Map<*, *> ?: return@mapNotNull null
                            StationDto(
                                slug = map["slug"] as? String ?: return@mapNotNull null,
                                title = map["title"] as? String ?: return@mapNotNull null,
                                thumbnailUrl = map["thumbnailUrl"] as? String,
                                songTitle = map["songTitle"] as? String
                            )
                        }
                        tvChannelScope.launch(Dispatchers.IO) {
                            TvChannelManager(this@MainActivity).syncChannel(stations)
                            launch(Dispatchers.Main) { result.success(true) }
                        }
                    }
                    "deleteChannel" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        tvChannelScope.launch(Dispatchers.IO) {
                            TvChannelManager(this@MainActivity).deleteChannel()
                            launch(Dispatchers.Main) { result.success(true) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        tvChannelScope.cancel()
        super.onDestroy()
    }
}
