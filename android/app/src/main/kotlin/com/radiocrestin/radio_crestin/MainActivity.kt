package com.radiocrestin.radio_crestin

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import com.oguzhnatly.flutter_android_auto.FAAConstants
import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // On Android Automotive OS, redirect to CarAppActivity for the template UI
        if (isAutomotiveOS() && savedInstanceState == null) {
            try {
                val intent = Intent(this, androidx.car.app.activity.CarAppActivity::class.java)
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                startActivity(intent)
                finish()
                return
            } catch (e: Exception) {
                // Fallback to Flutter UI if CarAppActivity is unavailable
            }
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Cache the engine so AndroidAutoService reuses it instead of creating a second one.
        FlutterEngineCache.getInstance()
            .put(FAAConstants.flutterEngineId, flutterEngine)
    }

    private fun isAutomotiveOS(): Boolean {
        return packageManager.hasSystemFeature(PackageManager.FEATURE_AUTOMOTIVE)
    }
}
