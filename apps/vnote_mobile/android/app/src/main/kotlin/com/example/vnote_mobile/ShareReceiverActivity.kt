package com.example.vnote_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import android.os.CancellationSignal
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.util.Locale
import java.util.concurrent.Executors

/** Dedicated SDK-only process: it never starts a Flutter engine or loads vnote_host. */
class ShareReceiverActivity : Activity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val cancellation = CancellationSignal()
    private lateinit var status: TextView
    private lateinit var progress: ProgressBar
    @Volatile private var received = false

    override fun attachBaseContext(base: Context) {
        val language = try { ShareInbox(base).locale() } catch (_: Exception) { "system" }
        val configured = if (language == "en" || language == "zh") {
            val configuration = Configuration(base.resources.configuration)
            configuration.setLocale(if (language == "zh") Locale.SIMPLIFIED_CHINESE else Locale.ENGLISH)
            base.createConfigurationContext(configuration)
        } else base
        super.attachBaseContext(configured)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = getString(R.string.share_title)
        val padding = (16 * resources.displayMetrics.density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(padding, padding, padding, padding)
        }
        val title = TextView(this).apply {
            text = getString(R.string.share_title)
            textSize = 24f
            setAccessibilityHeading(true)
        }
        status = TextView(this).apply {
            text = getString(R.string.share_receiving)
            textSize = 18f
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            setPadding(0, padding, 0, padding)
        }
        progress = ProgressBar(this).apply { isIndeterminate = true; contentDescription = getString(R.string.share_receiving) }
        val open = Button(this).apply {
            text = getString(R.string.share_open_app)
            minHeight = (48 * resources.displayMetrics.density).toInt()
            setOnClickListener {
                startActivity(Intent(this@ShareReceiverActivity, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                finish()
            }
        }
        val close = Button(this).apply {
            text = getString(R.string.share_close)
            minHeight = (48 * resources.displayMetrics.density).toInt()
            setOnClickListener { finish() }
        }
        content.addView(title)
        content.addView(status)
        content.addView(progress)
        content.addView(open)
        content.addView(close)
        val scroll = ScrollView(this).apply { isFillViewport = true; addView(content) }
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION")
            view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            insets
        }
        setContentView(scroll)
        // No incoming URI or text is retained in savedInstanceState. A killed partial is never acknowledged.
        worker.execute {
            val message = try {
                val result = ShareInbox(applicationContext).capture(intent, cancellation)
                received = true
                if (result.duplicate) R.string.share_duplicate else R.string.share_received
            } catch (error: Exception) {
                when ((error as? ShareFailure)?.code) {
                    "activation_required" -> R.string.share_activation_required
                    "inbox_full", "history_full" -> R.string.share_full
                    "inbox_busy" -> R.string.share_busy
                    "delivery_limit", "invalid_name", "invalid_type", "name_collision" -> R.string.share_limits
                    "storage_corrupt", "stage_conflict", "claim_conflict" -> R.string.share_corrupt
                    else -> R.string.share_failed
                }
            }
            runOnUiThread {
                if (!isFinishing && !isDestroyed) {
                    progress.visibility = View.GONE
                    status.setText(message)
                }
            }
        }
    }

    override fun onDestroy() {
        if (!received) cancellation.cancel()
        worker.shutdown()
        super.onDestroy()
    }
}
