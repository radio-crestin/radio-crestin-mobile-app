package com.radiocrestin.radio_crestin

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import com.oguzhnatly.flutter_android_auto.FAAConstants
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Cache the engine so CarPlay/Android Auto plugin can reuse it.
        FlutterEngineCache.getInstance()
            .put(FAAConstants.flutterEngineId, flutterEngine)
    }
}
