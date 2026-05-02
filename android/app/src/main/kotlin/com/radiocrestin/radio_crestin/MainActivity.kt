package com.radiocrestin.radio_crestin

import android.content.Intent
import android.os.Build
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
