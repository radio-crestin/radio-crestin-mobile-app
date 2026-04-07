package com.oguzhnatly.flutter_android_auto

import android.content.ComponentName
import android.content.Intent
import android.support.v4.media.MediaBrowserCompat
import android.util.Log
import androidx.car.app.Screen
import androidx.car.app.Session
import androidx.car.app.media.MediaPlaybackManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner

class AndroidAutoSession : Session() {
    companion object {
        private const val TAG = "AndroidAutoSession"
    }

    private var mediaBrowser: MediaBrowserCompat? = null
    private var tokenRegistered = false

    override fun onCreateScreen(intent: Intent): Screen {
        val screen = MainScreen(carContext)
        FlutterAndroidAutoPlugin.currentScreen = screen

        lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onCreate(owner: LifecycleOwner) {
                registerMediaSession()
                super.onCreate(owner)
            }

            override fun onStart(owner: LifecycleOwner) {
                FlutterAndroidAutoPlugin.onAndroidAutoConnectionChange(
                    FAAConnectionTypes.connected
                )
                // Retry token registration if it wasn't successful in onCreate
                // (AudioService may not have been started yet)
                if (!tokenRegistered) {
                    registerMediaSession()
                }
                super.onStart(owner)
            }

            override fun onDestroy(owner: LifecycleOwner) {
                FlutterAndroidAutoPlugin.onAndroidAutoConnectionChange(
                    FAAConnectionTypes.disconnected
                )
                mediaBrowser?.disconnect()
                mediaBrowser = null
                tokenRegistered = false
                FlutterAndroidAutoPlugin.currentScreen = null
                FlutterAndroidAutoPlugin.currentPlayerScreen = null
                super.onDestroy(owner)
            }
        })

        return screen
    }

    /**
     * Connects to audio_service's MediaBrowserService to retrieve the
     * MediaSession token and registers it with the car's MediaPlaybackManager.
     *
     * This is the critical bridge that makes the system media status card
     * (home screen) and MediaPlaybackTemplate (Now Playing screen) work.
     * Without it, Android Auto doesn't know which MediaSession to read from.
     */
    private fun registerMediaSession() {
        if (tokenRegistered) return
        // Disconnect previous failed attempt
        mediaBrowser?.disconnect()
        mediaBrowser = null

        try {
            // Use applicationContext (not carContext) for MediaBrowserCompat.
            // CarContext is a ContextWrapper with restricted capabilities that
            // can cause bindService() to fail on some Android versions.
            val appContext = carContext.applicationContext
            val componentName = ComponentName(
                appContext,
                "com.ryanheise.audioservice.AudioService"
            )

            Log.d(TAG, "Connecting to AudioService MediaBrowser...")
            mediaBrowser = MediaBrowserCompat(
                appContext,
                componentName,
                object : MediaBrowserCompat.ConnectionCallback() {
                    override fun onConnected() {
                        Log.d(TAG, "Connected to AudioService MediaBrowser")
                        val token = mediaBrowser?.sessionToken
                        if (token == null) {
                            Log.w(TAG, "MediaBrowser connected but sessionToken is null")
                            return
                        }
                        // Always try to register — the API level check is overly
                        // conservative. Some hosts report level 7 but still support
                        // MediaPlaybackManager. Let the runtime decide.
                        try {
                            val manager = carContext.getCarService(
                                MediaPlaybackManager::class.java
                            )
                            manager.registerMediaPlaybackToken(token)
                            tokenRegistered = true
                            Log.d(TAG, "MediaSession token registered successfully (API level: ${carContext.carAppApiLevel})")
                        } catch (e: Exception) {
                            Log.w(TAG, "Could not register media token (API level: ${carContext.carAppApiLevel}): ${e.message}")
                        }
                    }

                    override fun onConnectionFailed() {
                        Log.w(TAG, "Failed to connect to AudioService MediaBrowser. Is the phone app running?")
                    }

                    override fun onConnectionSuspended() {
                        Log.w(TAG, "AudioService MediaBrowser connection suspended")
                        tokenRegistered = false
                    }
                },
                null
            )
            mediaBrowser?.connect()
        } catch (e: Exception) {
            Log.e(TAG, "Error setting up media session bridge: ${e.message}", e)
        }
    }
}
