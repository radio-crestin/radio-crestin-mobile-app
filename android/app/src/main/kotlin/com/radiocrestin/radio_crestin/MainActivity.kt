package com.radiocrestin.radio_crestin

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import com.oguzhnatly.flutter_android_auto.FAAConstants
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Cache the engine so AndroidAutoService reuses it instead of creating a second one.
        FlutterEngineCache.getInstance()
            .put(FAAConstants.flutterEngineId, flutterEngine)
    }
}
