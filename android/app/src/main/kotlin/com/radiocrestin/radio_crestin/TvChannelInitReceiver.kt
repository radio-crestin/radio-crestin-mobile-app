package com.radiocrestin.radio_crestin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import com.oguzhnatly.flutter_android_auto.FAAConstants

/**
 * Receives INITIALIZE_PROGRAMS broadcast from the Android TV system.
 * This is sent when the app is first installed or after a system update,
 * signaling the app to publish its channels/programs to the home screen.
 */
class TvChannelInitReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TvChannelInitReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != "android.media.tv.action.INITIALIZE_PROGRAMS") return

        Log.d(TAG, "INITIALIZE_PROGRAMS broadcast received")

        // Try to reach the Flutter engine to trigger a sync from Dart
        val engine = FlutterEngineCache.getInstance().get(FAAConstants.flutterEngineId)
        if (engine != null) {
            MethodChannel(engine.dartExecutor.binaryMessenger, "com.radiocrestin.tv_channels")
                .invokeMethod("onInitializePrograms", null)
        } else {
            Log.w(TAG, "Flutter engine not available — app will sync channels on next launch")
        }
    }
}
