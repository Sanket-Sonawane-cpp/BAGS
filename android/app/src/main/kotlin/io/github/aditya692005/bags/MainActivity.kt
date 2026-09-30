package io.github.aditya692005.bags

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createHazardChannel()
    }

    // The channel server/fcm.py sends hazard alerts on. It has to exist
    // before a push arrives, otherwise Android falls back to FCM's default
    // channel, which doesn't pop up over other apps. Creating it again is
    // a no-op, so doing it on every launch is fine.
    private fun createHazardChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val channel = NotificationChannel(
            HAZARD_CHANNEL_ID,
            "Road hazard alerts",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Hazards reported by other cars near you"
            enableVibration(true)
        }
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(channel)
    }

    private companion object {
        const val HAZARD_CHANNEL_ID = "hazard_alerts"
    }
}
