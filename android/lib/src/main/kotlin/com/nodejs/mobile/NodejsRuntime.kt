package com.nodejs.mobile

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File
import java.io.FileOutputStream

/**
 * NodejsRuntime — run Node.js v24 inside an Android app.
 *
 * Only one instance may be active per process (Node.js constraint).
 *
 * Usage:
 * ```kotlin
 * val runtime = NodejsRuntime(context)
 * runtime.on("response") { msg -> Log.d("App", "Got: $msg") }
 * runtime.start("nodejs-project/main.js")
 * runtime.send("ping", """{"hello": "world"}""")
 * ```
 */
class NodejsRuntime(private val context: Context) {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val channels = NodeEventEmitter()
    private var started = false

    companion object {
        private var instanceCreated = false

        init {
            System.loadLibrary("node_bridge")
        }
    }

    init {
        require(!instanceCreated) {
            "Only one NodejsRuntime may exist per process."
        }
        instanceCreated = true
    }

    // ── External API ────────────────────────────────────────────────────────

    /**
     * Start Node.js with a JS file from the APK assets.
     *
     * @param assetsPath  Path inside assets/, e.g. "nodejs-project/main.js"
     */
    fun start(assetsPath: String) {
        check(!started) { "Node.js is already running." }
        started = true
        val scriptFile = copyAssetToInternal(assetsPath)
        nativeStart(scriptFile.absolutePath)
    }

    /**
     * Start Node.js with an inline JS string.
     */
    fun startWithCode(jsCode: String) {
        check(!started) { "Node.js is already running." }
        started = true
        val scriptFile = File(context.filesDir, "_nodejs_inline_.js")
        scriptFile.writeText(jsCode)
        nativeStart(scriptFile.absolutePath)
    }

    /**
     * Send a message to Node.js on the given channel.
     * Thread-safe; can be called from any thread.
     */
    fun send(channel: String, message: String) {
        check(started) { "Node.js is not running. Call start() first." }
        nativeSend(channel, message)
    }

    /**
     * Register a listener for messages coming FROM Node.js on [channel].
     * The listener is always called on the main thread.
     */
    fun on(channel: String, listener: (String) -> Unit) {
        channels.on(channel, listener)
    }

    /** Remove all listeners for [channel]. */
    fun off(channel: String) {
        channels.off(channel)
    }

    val isRunning: Boolean get() = started

    // ── Called by JNI (node_bridge.cpp) ────────────────────────────────────

    /**
     * Invoked from the Node.js thread via JNI when Node.js sends a message.
     * DO NOT rename — must match the JNI method lookup in node_bridge.cpp.
     */
    @Suppress("unused")
    fun onMessageFromNode(channel: String, message: String) {
        mainHandler.post { channels.emit(channel, message) }
    }

    // ── Internal helpers ────────────────────────────────────────────────────

    /**
     * Copy an asset file (and its siblings) to internal storage so Node.js
     * can read them via the filesystem. Returns the target File.
     */
    private fun copyAssetToInternal(assetsPath: String): File {
        val assetDir = assetsPath.substringBeforeLast('/', "")
        val destDir = File(context.filesDir, assetDir)
        copyAssetDir(assetDir, destDir)
        return File(context.filesDir, assetsPath)
    }

    private fun copyAssetDir(assetPath: String, destDir: File) {
        val assets = context.assets
        val children = assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            // It's a file
            destDir.parentFile?.mkdirs()
            assets.open(assetPath).use { input ->
                FileOutputStream(destDir).use { output -> input.copyTo(output) }
            }
        } else {
            destDir.mkdirs()
            for (child in children) {
                val childAsset = if (assetPath.isEmpty()) child else "$assetPath/$child"
                copyAssetDir(childAsset, File(destDir, child))
            }
        }
    }

    // ── Native methods (implemented in node_bridge.cpp) ─────────────────────

    private external fun nativeStart(scriptPath: String)
    private external fun nativeSend(channel: String, message: String)
}
