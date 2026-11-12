package com.radiocrestin.radio_crestin

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import android.util.Log
import java.io.IOException

/**
 * The ANRs Android recorded for this app (Android 11+), handed over once
 * each, so the next launch can report them (`lib/services/anr_reporter.dart`).
 *
 * Play Console shows ANRs days later and without the app's context; this
 * brings each one in with the main thread's stack, the build and the device.
 * Reads a file per ANR: call it off the main thread.
 */
object AnrReports {
    private const val TAG = "RadioCrestinAnr"
    private const val PREFERENCES = "anr_reports"
    private const val REPORTED_UNTIL_KEY = "reported_until"

    /** The stack lines sent per ANR: the frames that say what blocked. */
    private const val MAIN_THREAD_LINES = 60

    fun takeNew(context: Context): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        return try {
            takeNewSinceAndroid11(context)
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the recorded ANRs", e)
            emptyList()
        }
    }

    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun takeNewSinceAndroid11(context: Context): List<Map<String, Any?>> {
        val activityManager = context.getSystemService(ActivityManager::class.java)
            ?: return emptyList()
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val exits = activityManager.getHistoricalProcessExitReasons(null, 0, 0)
        val newest = exits.maxOfOrNull { it.timestamp } ?: 0L
        // The first launch of this version doesn't know which build the
        // ANRs recorded before it came from, so it reports none of them.
        if (!preferences.contains(REPORTED_UNTIL_KEY)) {
            preferences.edit().putLong(REPORTED_UNTIL_KEY, newest).apply()
            return emptyList()
        }
        val reportedUntil = preferences.getLong(REPORTED_UNTIL_KEY, 0L)
        val anrs = exits
            .filter { it.reason == ApplicationExitInfo.REASON_ANR && it.timestamp > reportedUntil }
            .sortedBy { it.timestamp }
        preferences.edit().putLong(REPORTED_UNTIL_KEY, maxOf(newest, reportedUntil)).apply()
        if (anrs.isNotEmpty()) Log.i(TAG, "Handing over ${anrs.size} recorded ANR(s)")
        return anrs.map { exit ->
            mapOf(
                "timestamp" to exit.timestamp,
                "description" to exit.description,
                "importance" to exit.importance,
                "main_thread" to mainThread(exit),
            )
        }
    }

    /** The main thread's section of the ANR's trace file. */
    @androidx.annotation.RequiresApi(Build.VERSION_CODES.R)
    private fun mainThread(exit: ApplicationExitInfo): String? = try {
        exit.traceInputStream?.bufferedReader()?.useLines { lines ->
            lines.dropWhile { !it.startsWith("\"main\"") }
                .takeWhile { it.isNotBlank() }
                .take(MAIN_THREAD_LINES)
                .joinToString("\n")
                .ifEmpty { null }
        }
    } catch (e: IOException) {
        null
    }
}
