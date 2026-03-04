package com.nodejs.mobile.sample

import android.os.Bundle
import android.util.Log
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.nodejs.mobile.NodejsRuntime
import kotlinx.coroutines.*
import java.net.URL

class MainActivity : AppCompatActivity() {

    private val TAG = "NodejsSample"
    private lateinit var runtime: NodejsRuntime
    private var httpPort: Int = -1

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val statusText = findViewById<TextView>(R.id.statusText)
        val pingButton = findViewById<Button>(R.id.pingButton)
        val httpButton = findViewById<Button>(R.id.httpButton)

        // ── Start Node.js ────────────────────────────────────────────────────
        runtime = NodejsRuntime(this)

        // Listen for pong responses
        runtime.on("pong") { msg ->
            Log.d(TAG, "Got pong: $msg")
            runOnUiThread { statusText.text = "Pong: $msg" }
        }

        // Listen for the HTTP port from Node.js
        runtime.on("http-port") { port ->
            httpPort = port.trim().toIntOrNull() ?: -1
            Log.d(TAG, "Node.js HTTP server on port $httpPort")
            runOnUiThread { statusText.text = "Node.js HTTP ready on :$httpPort" }
        }

        runtime.start("nodejs-project/main.js")
        statusText.text = "Node.js starting..."

        // ── Ping button ──────────────────────────────────────────────────────
        pingButton.setOnClickListener {
            runtime.send("ping", """{"from": "android", "ts": ${System.currentTimeMillis()}}""")
            statusText.text = "Ping sent..."
        }

        // ── HTTP button ──────────────────────────────────────────────────────
        httpButton.setOnClickListener {
            if (httpPort < 0) {
                statusText.text = "HTTP server not ready yet"
                return@setOnClickListener
            }
            CoroutineScope(Dispatchers.IO).launch {
                try {
                    val body = URL("http://127.0.0.1:$httpPort/status").readText()
                    withContext(Dispatchers.Main) { statusText.text = "HTTP: $body" }
                } catch (e: Exception) {
                    withContext(Dispatchers.Main) { statusText.text = "HTTP error: ${e.message}" }
                }
            }
        }
    }
}
