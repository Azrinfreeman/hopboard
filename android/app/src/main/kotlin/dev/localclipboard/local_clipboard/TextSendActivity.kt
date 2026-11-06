package dev.localclipboard.local_clipboard

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import android.widget.Toast
import io.flutter.plugin.common.MethodChannel

/** Public entry accepts supplied text only. It never reads the clipboard. */
class ShareTextActivity : TextSendActivity() {
    override val sharedText = true
}

/** Only our notification can launch this non-exported, focused clipboard reader. */
class SendClipboardActivity : TextSendActivity() {
    override val sharedText = false
}

abstract class TextSendActivity : Activity() {
    protected abstract val sharedText: Boolean
    private var started = false
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { complete("Delivery is unconfirmed. Open Hopboard to check.") }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || started) return
        started = true
        if (getSystemService(KeyguardManager::class.java).isKeyguardLocked) {
            complete("Unlock your device and try again.")
            return
        }
        try {
            val request = if (sharedText) {
                val text = sharedIntentText(intent)
                    ?: throw IllegalArgumentException("Select text and share it to Hopboard.")
                mapOf<String, Any?>("text" to text, "sharedText" to true)
            } else {
                if (!BackgroundService.running) throw IllegalStateException("Open Hopboard and connect first.")
                val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = clipboard.primaryClip
                val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
                val extras = clip?.description?.extras
                mapOf<String, Any?>(
                    "text" to text, "sharedText" to false,
                    "revision" to MainActivity.revisionForSend(clip?.description),
                    "stamp" to clip?.description?.timestamp,
                    "sensitive" to (extras?.getBoolean("android.content.extra.IS_SENSITIVE", false) == true),
                    "ownWrite" to (extras?.getString("localclipboard.origin") != null)
                )
            }
            val text = request["text"] as? String
            validateSendText(text)
            val channel = MainActivity.channelForService
            if (channel == null || !MainActivity.sendReady) {
                if (!sharedText) throw IllegalStateException("Open Hopboard and try again.")
                // A cold start needs the app's engine, private identity and saved host.
                startActivity(Intent(this, MainActivity::class.java)
                    .setAction(Intent.ACTION_SEND).setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, text)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                finish()
                return
            }
            handler.postDelayed(timeout, 30000)
            channel.invokeMethod("sendExternalText", request, object : MethodChannel.Result {
                override fun success(result: Any?) = complete("Sent to PC")
                override fun error(code: String, message: String?, details: Any?) = complete(message ?: "Open Hopboard and try again.")
                override fun notImplemented() = complete("Open Hopboard and try again.")
            })
        } catch (failure: Exception) {
            complete(failure.message ?: "Open Hopboard and try again.")
        }
    }

    private fun complete(message: String) {
        if (isFinishing || isDestroyed) return
        handler.removeCallbacks(timeout)
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
        finish()
    }

    override fun onDestroy() {
        handler.removeCallbacks(timeout)
        super.onDestroy()
    }
}

internal fun sharedIntentText(intent: Intent): String? = when (intent.action) {
    Intent.ACTION_SEND -> if (intent.type == "text/plain") intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() else null
    Intent.ACTION_PROCESS_TEXT -> if (intent.type == "text/plain") intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString() else null
    else -> null
}

internal fun validateSendText(text: String?) {
    require(!text.isNullOrEmpty() && !text.contains('\u0000')) { "Use non-empty text without null characters." }
    require(text.length <= 65536 && text.toByteArray(Charsets.UTF_8).size <= 65536) { "Text is limited to 64 KiB." }
}
