package dev.localclipboard.local_clipboard

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ClipboardManager
import android.content.ClipData
import android.content.Context
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
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private lateinit var clipboard: ClipboardManager
    private var revision = 0L
    private var ownRevision = -1L
    private var pendingOrigin: String? = null
    private var observedTimestamp = -1L
    private var permissionResult: MethodChannel.Result? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    private val listener = ClipboardManager.OnPrimaryClipChangedListener {
        revision++
        ownRevision = -1L
        if (hasWindowFocus()) {
            val description = clipboard.primaryClipDescription
            observedTimestamp = description?.timestamp ?: 0L
            if (pendingOrigin != null && description?.extras
                    ?.getString("localclipboard.origin") == pendingOrigin) ownRevision = revision
        } else observedTimestamp = -1L
        pendingOrigin = null
        channel.invokeMethod("clipboardChanged", null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.localclipboard/native")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
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

    private fun notifyNetwork() {
        runOnUiThread { channel.invokeMethod("networkChanged", null) }
    }

    private fun observeClipboardTimestamp() {
        // Android can omit change callbacks while this app is backgrounded.
        val description = clipboard.primaryClipDescription
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
    }

    override fun onDestroy() {
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
