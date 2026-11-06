package dev.localclipboard.local_clipboard

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.app.Notification
import android.app.NotificationManager
import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import android.content.pm.PackageManager
import android.os.Build
import android.os.PersistableBundle
import android.net.ConnectivityManager
import android.net.Network
import android.view.WindowManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.lang.ref.WeakReference
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    companion object {
        // The notification buttons live in BackgroundService, which has no
        // channel of its own; it reaches the running Dart session through this.
        @Volatile var channelForService: MethodChannel? = null
        @Volatile var sendReady = false
        private var currentActivity = WeakReference<MainActivity>(null)

        // Called only after our private send activity owns window focus. Share
        // the revision counter so ACK releases only this clipboard snapshot.
        fun revisionForSend(description: ClipDescription?): Long {
            val activity = currentActivity.get() ?: return 0L
            activity.observeClipboardTimestamp(description)
            return activity.revision
        }

        fun sendAction(action: String) {
            channelForService?.invokeMethod("trayAction", action)
        }
    }

    private lateinit var channel: MethodChannel
    private var pendingSharedText: String? = null
    private var sharedSendBusy = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Consume once; rotation / process restoration must never resend text.
        if (savedInstanceState == null) acceptSharedText(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        acceptSharedText(intent)
    }

    private fun acceptSharedText(incoming: Intent) {
        val text = sharedIntentText(incoming) ?: return
        try {
            validateSendText(text)
            if (pendingSharedText != null || sharedSendBusy) {
                Toast.makeText(this, "Waiting for the previous transfer.", Toast.LENGTH_LONG).show()
                return
            }
            pendingSharedText = text
            dispatchSharedText()
        } catch (failure: Exception) {
            Toast.makeText(this, failure.message, Toast.LENGTH_LONG).show()
        } finally {
            incoming.removeExtra(Intent.EXTRA_TEXT)
            incoming.removeExtra(Intent.EXTRA_PROCESS_TEXT)
        }
    }

    private fun dispatchSharedText() {
        if (!sendReady || !hasWindowFocus() || sharedSendBusy) return
        val text = pendingSharedText ?: return
        pendingSharedText = null
        sharedSendBusy = true
        channel.invokeMethod("sendExternalText", mapOf("text" to text, "sharedText" to true), object : MethodChannel.Result {
            override fun success(result: Any?) {
                sharedSendBusy = false
                Toast.makeText(this@MainActivity, "Sent to PC", Toast.LENGTH_SHORT).show()
                moveTaskToBack(true)
            }
            override fun error(code: String, message: String?, details: Any?) {
                sharedSendBusy = false
                Toast.makeText(this@MainActivity, message ?: "Open Hopboard and try again.", Toast.LENGTH_LONG).show()
            }
            override fun notImplemented() = error("send", "Open Hopboard and try again.", null)
        })
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) dispatchSharedText()
    }
    private lateinit var clipboard: ClipboardManager
    private var revision = 0L
    private var ownRevision = -1L
    private var pendingOrigin: String? = null
    private var observedTimestamp = -1L
    private var permissionResult: MethodChannel.Result? = null
    private var notificationResult: MethodChannel.Result? = null
    private var pendingService: Pair<String?, Boolean>? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    // Elapsed time of our last write made without window focus. The change
    // callback for it may arrive later and must still count as our own write.
    private var backgroundWriteAt = -1L
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        revision++
        ownRevision = -1L
        val backgroundWrite = backgroundWriteAt >= 0 &&
            SystemClock.elapsedRealtime() - backgroundWriteAt < 3000
        if (hasWindowFocus()) {
            val description = clipboard.primaryClipDescription
            observedTimestamp = description?.timestamp ?: 0L
            // Some Android builds drop our marker from the clip description, so a
            // change right after our own write counts as ours either way.
            if (pendingOrigin != null && (backgroundWrite || description?.extras
                    ?.getString("localclipboard.origin") == pendingOrigin)) ownRevision = revision
        } else {
            observedTimestamp = -1L
            if (backgroundWrite) ownRevision = revision
        }
        if (backgroundWrite) backgroundWriteAt = -1L
        pendingOrigin = null
        channel.invokeMethod("clipboardChanged", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.localclipboard/native")
        channelForService = channel
        currentActivity = WeakReference(this)
        sendReady = false
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sendReady" -> {
                    sendReady = true
                    result.success(null)
                    window.decorView.post { dispatchSharedText() }
                }
                "clipboardStamp" -> {
                    // The change time only, never the contents. Some phones hide it.
                    val stamp = try { clipboard.primaryClipDescription?.timestamp } catch (_: Exception) { null }
                    result.success(stamp)
                }
                "writeClipboardBackground" -> {
                    val text = call.argument<String>("text")
                    if (text == null || text.toByteArray(Charsets.UTF_8).size > 65536 || text.contains('\u0000')) {
                        result.error("text", "Unsupported clipboard text.", null)
                    } else {
                        val origin = java.util.UUID.randomUUID().toString()
                        pendingOrigin = origin
                        backgroundWriteAt = SystemClock.elapsedRealtime()
                        val clip = ClipData.newPlainText("LocalClipboard", text)
                        clip.description.extras = PersistableBundle().apply {
                            putString("localclipboard.origin", origin)
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        try {
                            clipboard.setPrimaryClip(clip)
                            val stamp = try { clipboard.primaryClipDescription?.timestamp } catch (_: Exception) { null }
                            if (stamp != null) observedTimestamp = stamp
                            ownRevision = revision
                            result.success(mapOf("revision" to revision, "stamp" to stamp))
                        } catch (_: Exception) {
                            pendingOrigin = null
                            backgroundWriteAt = -1L
                            result.error("denied", "Android blocked copying while Hopboard is in the background.", null)
                        }
                    }
                }
                "backgroundService" -> {
                    val enabled = call.argument<Boolean>("enabled") == true
                    val host = call.argument<String>("host")
                    val paused = call.argument<Boolean>("paused") == true
                    if (!enabled) {
                        stopService(Intent(this, BackgroundService::class.java))
                        result.success(null)
                    } else if (Build.VERSION.SDK_INT >= 33 &&
                        checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) {
                        if (notificationResult != null) {
                            result.error("notifications", "Allow notifications so Hopboard can show that it is connected.", null)
                        } else {
                            notificationResult = result
                            pendingService = Pair(host, paused)
                            requestPermissions(arrayOf("android.permission.POST_NOTIFICATIONS"), 905)
                        }
                    } else startBackground(host, paused, result)
                }
                "requestSendTile" -> {
                    // Android 13+ can offer the tile with one confirmation; older
                    // versions add it from the Quick Settings edit screen.
                    if (Build.VERSION.SDK_INT < 33) result.success(-1)
                    else try {
                        getSystemService(android.app.StatusBarManager::class.java).requestAddTileService(
                            android.content.ComponentName(this, SendTileService::class.java),
                            "Send to PC",
                            android.graphics.drawable.Icon.createWithResource(this, R.drawable.ic_tile_send),
                            mainExecutor
                        ) { code -> result.success(code) }
                    } catch (_: Exception) { result.success(-1) }
                }
                "notifyReceived" -> {
                    postReceivedNotice(
                        call.argument<String>("sender") ?: "your computer",
                        call.argument<Boolean>("needsAction") == true
                    )
                    result.success(null)
                }
                "secureRead", "secureWrite" -> {
                    try {
                        val key = call.argument<String>("key") ?: throw IllegalArgumentException()
                        require(key == "identity.v1" || key == "trust.v1")
                        val preferences = getSharedPreferences("localclipboard.secure", Context.MODE_PRIVATE)
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        if (call.method == "secureRead") {
                            val stored = preferences.getString(key, null)
                            if (stored == null) result.success(null)
                            else {
                                val parts = stored.split(":")
                                cipher.init(Cipher.DECRYPT_MODE, storageKey(),
                                    GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)))
                                val plain = cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP))
                                result.success(String(plain, Charsets.UTF_8))
                            }
                        } else {
                            val value = call.argument<String>("value") ?: throw IllegalArgumentException()
                            require(value.toByteArray(Charsets.UTF_8).size <= 262144)
                            cipher.init(Cipher.ENCRYPT_MODE, storageKey())
                            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
                            val stored = Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + ":" +
                                Base64.encodeToString(encrypted, Base64.NO_WRAP)
                            if (!preferences.edit().putString(key, stored).commit()) throw IllegalStateException()
                            result.success(null)
                        }
                    } catch (_: Exception) { result.error("storage", "Private storage is unavailable.", null) }
                }
                "secureDelete" -> {
                    try {
                        val key = call.argument<String>("key") ?: throw IllegalArgumentException()
                        require(key == "identity.v1" || key == "trust.v1")
                        val preferences = getSharedPreferences("localclipboard.secure", Context.MODE_PRIVATE)
                        if (!preferences.edit().remove(key).commit()) throw IllegalStateException()
                        // Once nothing depends on it, drop a key that may be invalidated.
                        if (!preferences.contains("identity.v1") && !preferences.contains("trust.v1")) {
                            KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                                .deleteEntry("localclipboard.v1")
                        }
                        result.success(null)
                    } catch (_: Exception) { result.error("storage", "Could not remove private storage.", null) }
                }
                "initialize" -> {
                    if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
                    clipboard.removePrimaryClipChangedListener(listener)
                    clipboard.addPrimaryClipChangedListener(listener)
                    val manager = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    if (networkCallback == null) {
                        val callback = object : ConnectivityManager.NetworkCallback() {
                            override fun onAvailable(network: Network) { notifyNetwork() }
                            override fun onLost(network: Network) { notifyNetwork() }
                        }
                        networkCallback = callback
                        manager.registerDefaultNetworkCallback(callback)
                    }
                    result.success(null)
                }
                "requestNetwork" -> {
                    val permission = "android.permission.ACCESS_LOCAL_NETWORK"
                    if (Build.VERSION.SDK_INT >= 37 && applicationInfo.targetSdkVersion >= 37 &&
                        checkSelfPermission(permission) != PackageManager.PERMISSION_GRANTED) {
                        if (permissionResult != null) result.success(false)
                        else {
                            permissionResult = result
                            requestPermissions(arrayOf(permission), 904)
                        }
                    } else result.success(true)
                }
                "readClipboard" -> {
                    if (!hasWindowFocus()) result.error("focus", "Open the app to paste text.", null)
                    else {
                        observeClipboardTimestamp()
                        val clip = clipboard.primaryClip
                        val text = if (clip != null && clip.itemCount > 0) clip.getItemAt(0).text?.toString() else null
                        val sensitive = clip?.description?.extras
                            ?.getBoolean("android.content.extra.IS_SENSITIVE", false) == true
                        result.success(mapOf("text" to text, "revision" to revision,
                            "ownWrite" to (revision == ownRevision), "sensitive" to sensitive))
                    }
                }
                "writeClipboard" -> {
                    val text = call.argument<String>("text")
                    val expected = call.argument<Number>("expectedRevision")?.toLong()
                    if (hasWindowFocus()) observeClipboardTimestamp()
                    if (!hasWindowFocus()) result.error("focus", "Open the app to copy text.", null)
                    else if (text == null || text.toByteArray(Charsets.UTF_8).size > 65536 || text.contains('\u0000'))
                        result.error("text", "Unsupported clipboard text.", null)
                    else if (expected != null && expected != revision) result.success(false)
                    else {
                        val origin = java.util.UUID.randomUUID().toString()
                        pendingOrigin = origin
                        val clip = ClipData.newPlainText("LocalClipboard", text)
                        clip.description.extras = PersistableBundle().apply {
                            putString("localclipboard.origin", origin)
                            putBoolean("android.content.extra.IS_SENSITIVE", true)
                        }
                        backgroundWriteAt = SystemClock.elapsedRealtime()
                        clipboard.setPrimaryClip(clip)
                        observedTimestamp = clipboard.primaryClipDescription?.timestamp ?: 0L
                        ownRevision = revision
                        result.success(true)
                    }
                }
                "keepAwake" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startBackground(host: String?, paused: Boolean, result: MethodChannel.Result) {
        try {
            if (BackgroundService.running) BackgroundService.update(this, host, paused)
            else startForegroundService(
                Intent(this, BackgroundService::class.java)
                    .putExtra(BackgroundService.EXTRA_HOST, host)
                    .putExtra(BackgroundService.EXTRA_PAUSED, paused)
            )
            result.success(null)
        } catch (_: Exception) {
            result.error("service", "Background receive could not start. Open Hopboard and try again.", null)
        }
    }

    // A quiet notice. It names the sending device and never shows the text.
    private fun postReceivedNotice(sender: String, needsAction: Boolean) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission("android.permission.POST_NOTIFICATIONS") != PackageManager.PERMISSION_GRANTED) return
        BackgroundService.ensureChannel(this, "hopboard_received", "Copied items", NotificationManager.IMPORTANCE_LOW)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "hopboard_received")
            else Notification.Builder(this)
        val notice = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(if (needsAction) "Text from $sender is waiting" else "Copied from $sender")
            .setContentText(if (needsAction) "Open Hopboard and tap Copy" else "Ready to paste")
            .setContentIntent(BackgroundService.openAppIntent(this))
            .setAutoCancel(true)
            .setTimeoutAfter(5 * 60 * 1000L)
            .build()
        getSystemService(NotificationManager::class.java).notify(42, notice)
    }

    private fun notifyNetwork() {
        runOnUiThread { channel.invokeMethod("networkChanged", null) }
    }

    private fun observeClipboardTimestamp(description: ClipDescription? = clipboard.primaryClipDescription) {
        // Android can omit change callbacks while this app is backgrounded.
        val timestamp = description?.timestamp ?: 0L
        if (timestamp != observedTimestamp) {
            observedTimestamp = timestamp
            revision++
            ownRevision = if (pendingOrigin != null && description?.extras
                ?.getString("localclipboard.origin") == pendingOrigin) revision else -1L
        }
    }

    private fun storageKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey("localclipboard.v1", null) as? SecretKey
        if (existing != null) return existing
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder("localclipboard.v1",
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).setKeySize(256).build())
        return generator.generateKey()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 904) {
            permissionResult?.success(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
            permissionResult = null
        }
        if (requestCode == 905) {
            val waiting = notificationResult
            val wanted = pendingService
            notificationResult = null
            pendingService = null
            if (waiting != null && wanted != null) {
                if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                    startBackground(wanted.first, wanted.second, waiting)
                } else {
                    waiting.error("notifications", "Allow notifications so Hopboard can show that it is connected.", null)
                }
            }
        }
    }

    override fun onDestroy() {
        // The Dart session ends with this activity's engine, so a service that
        // kept running would claim a connection that no longer exists.
        if (!isChangingConfigurations) stopService(Intent(this, BackgroundService::class.java))
        if (::channel.isInitialized && channelForService === channel) {
            channelForService = null
            sendReady = false
            currentActivity.clear()
        }
        if (::clipboard.isInitialized) clipboard.removePrimaryClipChangedListener(listener)
        networkCallback?.let {
            (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager).unregisterNetworkCallback(it)
        }
        super.onDestroy()
    }

    override fun onPause() {
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }
}
