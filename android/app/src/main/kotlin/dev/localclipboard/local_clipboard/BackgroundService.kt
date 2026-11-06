package dev.localclipboard.local_clipboard

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps this process alive while a joined phone waits for the next PC copy.
 * It holds no connection itself: the Dart session keeps running in the app's
 * Flutter engine. Android requires the visible notification below.
 */
class BackgroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                MainActivity.sendAction("stopBackground")
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                MainActivity.sendAction("pause")
                return START_NOT_STICKY
            }
        }
        host = intent?.getStringExtra(EXTRA_HOST)
        paused = intent?.getBooleanExtra(EXTRA_PAUSED, false) == true
        val notification = buildNotification(this, host, paused)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    companion object {
        const val ACTION_STOP = "dev.localclipboard.STOP_BACKGROUND"
        const val ACTION_PAUSE = "dev.localclipboard.PAUSE_BACKGROUND"
        const val EXTRA_HOST = "host"
        const val EXTRA_PAUSED = "paused"
        private const val CHANNEL = "hopboard_connection"
        private const val NOTIFICATION_ID = 41
        @Volatile var running = false
        private var host: String? = null
        private var paused = false

        fun refresh(context: Context) {
            if (running) update(context, host, paused)
        }

        /** Changes the wording of the running notification without restarting it. */
        fun update(context: Context, host: String?, paused: Boolean) {
            this.host = host
            this.paused = paused
            context.getSystemService(NotificationManager::class.java)
                .notify(NOTIFICATION_ID, buildNotification(context, host, paused))
        }

        fun ensureChannel(context: Context, id: String, name: String, importance: Int) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java)
            if (manager.getNotificationChannel(id) == null) {
                manager.createNotificationChannel(NotificationChannel(id, name, importance))
            }
        }

        fun openAppIntent(context: Context): PendingIntent =
            PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

        private fun serviceAction(context: Context, action: String): PendingIntent =
            PendingIntent.getService(
                context, action.hashCode(),
                Intent(context, BackgroundService::class.java).setAction(action),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )

        // Never put clipboard text in a notification: the lock screen may show it.
        private fun buildNotification(context: Context, host: String?, paused: Boolean): Notification {
            ensureChannel(context, CHANNEL, "Hopboard connection", NotificationManager.IMPORTANCE_LOW)
            val where = host ?: "your computer"
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
                else Notification.Builder(context)
            return builder
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(if (paused) "Hopboard is paused" else "Hopboard is connected")
                .setContentText(
                    if (paused) "Not copying from $where"
                    else "Copies from $where go to this clipboard"
                )
                .setContentIntent(openAppIntent(context))
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .apply {
                    // Android hides background clipboard changes from apps, so
                    // sending is always an explicit tap on this action.
                    if (!paused) addAction(Notification.Action.Builder(null, "Send to PC",
                        PendingIntent.getActivity(context, 43,
                            Intent(context, SendClipboardActivity::class.java),
                            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                    ).build())
                }
                .addAction(
                    Notification.Action.Builder(
                        null, if (paused) "Resume" else "Pause", serviceAction(context, ACTION_PAUSE)
                    ).build()
                )
                .addAction(Notification.Action.Builder(null, "Stop", serviceAction(context, ACTION_STOP)).build())
                .build()
        }
    }
}
