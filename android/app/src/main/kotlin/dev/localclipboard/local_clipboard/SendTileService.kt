package dev.localclipboard.local_clipboard

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile: one tap sends what is on the clipboard to the PC.
 *
 * It opens the same private, focused reader the notification button uses, so
 * Android lets it read the clipboard once, and nothing is read in the
 * background. The connection lives in the app's process, so the tile is active
 * only while Hopboard's background connection notification is showing.
 */
class SendTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        val ready = BackgroundService.running
        tile.state = if (ready) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Send to PC"
        if (Build.VERSION.SDK_INT >= 29) {
            tile.subtitle = if (ready) "Send clipboard" else "Open Hopboard"
        }
        tile.updateTile()
    }

    override fun onClick() {
        // The reader needs the screen unlocked to get window focus.
        if (isLocked) unlockAndRun { openReader() } else openReader()
    }

    private fun openReader() {
        if (!BackgroundService.running) {
            // Nothing is connected, so open the app instead of failing silently.
            open(Intent(this, MainActivity::class.java))
            return
        }
        open(Intent(this, SendClipboardActivity::class.java))
    }

    private fun open(intent: Intent) {
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (Build.VERSION.SDK_INT >= 34) {
            // Android 14 replaced the Intent form with a PendingIntent.
            startActivityAndCollapse(
                PendingIntent.getActivity(
                    this, 0, intent,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                )
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
