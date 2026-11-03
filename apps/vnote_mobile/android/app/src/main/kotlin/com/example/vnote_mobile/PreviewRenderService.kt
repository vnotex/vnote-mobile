package com.example.vnote_mobile

import android.app.Application
import android.app.Service
import android.content.Intent
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.util.JsonReader
import android.util.JsonToken
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.FileOutputStream
import java.io.StringReader
import java.nio.charset.CodingErrorAction
import java.util.concurrent.Executors
import org.json.JSONObject

/** No Flutter engine and no Javascript interface exists in this process. */
class PreviewRenderService : Service() {
    private val ui = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private var session = ""
    private var observer: IBinder? = null
    private var web: WebView? = null
    private var source: ParcelFileDescriptor? = null
    private var output: ParcelFileDescriptor? = null
    private var busy = false
    private var dead = false
    private var renderId = ""
    private var proofStarted = false
    private var job = -1
    private var outputUnits = 0
    private var outputBytes = 0
    private var offset = 0
    private var emittedBytes = 0
    private val outputEncoder = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
    private var sink: FileOutputStream? = null

    override fun onCreate() {
        super.onCreate()
        // This MUST be the first android.webkit call in :preview_renderer.
        if (suffixSet.compareAndSet(false, true)) WebView.setDataDirectorySuffix("preview_renderer")
        WebSurfaceSecurity.installWorkerDenial()
    }

    private val endpoint = object : Binder() {
        override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
            if (code == INTERFACE_TRANSACTION) { reply?.writeString(DESCRIPTOR); return true }
            if (Binder.getCallingUid() != Process.myUid()) throw SecurityException("Renderer caller")
            data.enforceInterface(DESCRIPTOR)
            when (code) {
                HELLO -> {
                    val token = data.readString() ?: throw SecurityException("Renderer token")
                    if (!WebSurfaceSecurity.id.matches(token) || session.isNotEmpty()) throw SecurityException("Renderer session")
                    session = token
                    observer = data.readStrongBinder() ?: throw SecurityException("Renderer observer")
                    observer!!.linkToDeath({ ui.post { retire(false) } }, 0)
                    reply!!.writeNoException()
                    reply.writeInt(Process.myPid())
                    reply.writeInt(Process.myUid())
                    reply.writeString(Application.getProcessName())
                    reply.writeString(session)
                    return true
                }
                START -> {
                    if (data.readString() != session || session.isEmpty() || busy) throw SecurityException("Renderer session")
                    val input = ParcelFileDescriptor.CREATOR.createFromParcel(data)
                    var target: ParcelFileDescriptor? = null
                    try {
                        target = ParcelFileDescriptor.CREATOR.createFromParcel(data)
                        busy = true
                        source = input
                        output = target
                        ui.post { start() }
                    } catch (error: Exception) {
                        input.close(); target?.close(); throw error
                    }
                    reply!!.writeNoException()
                    return true
                }
            }
            return super.onTransact(code, data, reply, flags)
        }
    }

    override fun onBind(intent: Intent?): IBinder = endpoint
    override fun onUnbind(intent: Intent?): Boolean { retire(false); stopSelf(); return false }
    override fun onDestroy() { retire(false); io.shutdown(); super.onDestroy() }

    private fun start() {
        if (dead) return
        WebSurfaceSecurity.prepareNetwork(this) { ready ->
            if (!dead) {
                if (ready) loadRenderer()
                else try { notify(POLICY_FAILED) } catch (_: Exception) { retire(false) }
            }
        }
    }

    private fun loadRenderer() {
        try {
            val renderer = WebView(this)
            web = renderer
            WebSurfaceSecurity.harden(renderer, preservePluginClient = false)
            if (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) WebView.setWebContentsDebuggingEnabled(true)
            val shell = WebSurfaceSecurity.shell(this, "render", WebSurfaceSecurity.nonce(), RENDER_ORIGIN).toByteArray(Charsets.UTF_8)
            renderer.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: android.webkit.WebResourceRequest) = true
                override fun shouldInterceptRequest(view: WebView, request: android.webkit.WebResourceRequest): android.webkit.WebResourceResponse {
                    if (request.isForMainFrame) {
                        return if (request.method == "GET" && request.url.toString() == RENDER_ORIGIN && !dead)
                            WebSurfaceSecurity.document(shell, WebSurfaceSecurity.connectionAllowlist(RENDER_ORIGIN))
                            else WebSurfaceSecurity.denied()
                    }
                    return WebSurfaceSecurity.bundleResponse(this@PreviewRenderService, request, RENDER_ORIGIN)
                }
                override fun onPageFinished(view: WebView, url: String) {
                    if (url != RENDER_ORIGIN || dead || proofStarted) return
                    proofStarted = true
                    WebSurfaceSecurity.proveDocument(renderer) { allowed ->
                        if (!dead) {
                            if (!allowed) try { notify(POLICY_FAILED) } catch (_: Exception) { retire(false) }
                            else evaluate("typeof window.vnoteRender === 'object'") { value ->
                                if (value != "true") fail() else prepareSource()
                            }
                        }
                    }
                }
                override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                    web = null; view.destroy(); fail(); return true
                }
            }
            renderer.loadUrl(RENDER_ORIGIN)
        } catch (_: Exception) { fail() }
    }

    private fun prepareSource() {
        // No source enters Javascript before this document's positive native-policy proof.
        notify(READY)
        io.execute {
            try {
                val descriptor = source ?: throw IllegalStateException()
                val bytes = ParcelFileDescriptor.AutoCloseInputStream(descriptor).use {
                    WebSurfaceSecurity.readBounded(it, 48 * 1024 * 1024)
                }
                source = null
                // The parent already serialized the complete request, including
                // validated preferences. Validate JSON without copying its source
                // into a second object graph and serializing it all over again.
                val request = WebSurfaceSecurity.utf8(bytes)
                var parsedId: String? = null
                JsonReader(StringReader(request)).use { reader ->
                    reader.beginObject()
                    while (reader.hasNext()) {
                        if (reader.nextName() == "renderId") {
                            require(parsedId == null && reader.peek() == JsonToken.STRING)
                            parsedId = reader.nextString()
                        } else reader.skipValue()
                    }
                    reader.endObject()
                    require(reader.peek() == JsonToken.END_DOCUMENT)
                }
                val id = requireNotNull(parsedId)
                require(WebSurfaceSecurity.id.matches(id))
                val script = "window.vnoteRender.prepare($request)"
                ui.post { renderId = id; evaluate(script) { status(it) } }
            } catch (_: Exception) { ui.post { fail() } }
        }
    }

    private fun evaluate(script: String, next: (String) -> Unit) {
        if (dead) return
        web?.evaluateJavascript(script) { value ->
            if (!dead) try { next(value) } catch (_: Exception) { fail() }
        }
    }

    private fun status(encoded: String) {
        val state = JSONObject(encoded)
        if (state.getInt("version") != 1 || state.getString("renderId") != renderId) throw IllegalArgumentException()
        val count = state.getInt("jobs")
        val next = state.getInt("nextJob")
        if (count !in 0..220 || next !in 0..count) throw IllegalArgumentException()
        when (state.getString("phase")) {
            "prepared" -> {
                if (job >= 0) { notify(JOB_DONE); job = -1 }
                if (next >= count) throw IllegalArgumentException()
                job = next
                // A synchronous Binder acknowledgment arms a thread independent of JS/UI.
                notify(JOB_START)
                evaluate("void window.vnoteRender.runJob($next)") { poll() }
            }
            "running" -> ui.postDelayed({ poll() }, 10)
            "ready" -> {
                if (job >= 0) { notify(JOB_DONE); job = -1 }
                evaluate("window.vnoteRender.finish()") { status(it) }
            }
            "complete" -> {
                outputUnits = state.getInt("outputUnits")
                outputBytes = state.getInt("outputBytes")
                if (outputUnits !in 0..16 * 1024 * 1024 || outputBytes !in 0..16 * 1024 * 1024) throw IllegalArgumentException()
                sink = ParcelFileDescriptor.AutoCloseOutputStream(requireNotNull(output))
                readChunk()
            }
            else -> fail()
        }
    }

    private fun poll() = evaluate("window.vnoteRender.status()") { status(it) }

    private fun readChunk() {
        if (offset == outputUnits) {
            if (emittedBytes != outputBytes) { fail(); return }
            io.execute {
                try {
                    sink!!.fd.sync()
                    sink!!.close(); sink = null
                    output?.close(); output = null
                    ui.post { retire(true) }
                } catch (_: Exception) { ui.post { fail() } }
            }
            return
        }
        val count = minOf(32768, outputUnits - offset)
        // Android's strict reader requires an object/array at the root. A
        // one-string array avoids copying the encoded chunk just to wrap it.
        evaluate("[window.vnoteRender.readOutput($offset,$count)]") { encoded ->
            val part = JsonReader(StringReader(encoded)).use { reader ->
                reader.beginArray()
                require(reader.peek() == JsonToken.STRING)
                val value = reader.nextString()
                require(!reader.hasNext())
                reader.endArray()
                require(reader.peek() == JsonToken.END_DOCUMENT)
                value
            }
            require(part.isNotEmpty() && part.length <= count && part.length >= count - 1)
            offset += part.length
            val bytes = outputEncoder.reset().encode(java.nio.CharBuffer.wrap(part))
            emittedBytes += bytes.remaining()
            if (emittedBytes > outputBytes || emittedBytes > 16 * 1024 * 1024) throw IllegalArgumentException()
            io.execute {
                try {
                    val channel = requireNotNull(sink).channel
                    while (bytes.hasRemaining()) channel.write(bytes)
                    ui.post { readChunk() }
                } catch (_: Exception) { ui.post { fail() } }
            }
        }
    }

    private fun notify(event: Int) {
        val data = Parcel.obtain(); val reply = Parcel.obtain()
        try {
            data.writeInterfaceToken(DESCRIPTOR); data.writeString(session); data.writeInt(event)
            if (observer?.transact(EVENT, data, reply, 0) != true) throw IllegalStateException()
            reply.readException()
        } finally { data.recycle(); reply.recycle() }
    }

    private fun fail() {
        if (dead) return
        // The parent retires the verified process; it never relies on JS cancellation.
        try { notify(FAILED) } catch (_: Exception) { retire(false) }
    }

    private fun retire(success: Boolean) {
        if (dead) return
        dead = true
        web?.stopLoading(); web?.destroy(); web = null
        io.execute {
            try { source?.close() } catch (_: Exception) {}
            try { sink?.close() } catch (_: Exception) {}
            try { output?.close() } catch (_: Exception) {}
            source = null; sink = null; output = null
            if (success) try { notify(COMPLETE) } catch (_: Exception) {}
        }
    }

    companion object {
        private val suffixSet = java.util.concurrent.atomic.AtomicBoolean(false)
        const val DESCRIPTOR = "com.example.vnote_mobile.PreviewRender"
        const val HELLO = IBinder.FIRST_CALL_TRANSACTION
        const val START = HELLO + 1
        const val EVENT = HELLO + 2
        const val READY = 1
        const val JOB_START = 2
        const val JOB_DONE = 3
        const val COMPLETE = 4
        const val FAILED = 5
        const val POLICY_FAILED = 6
        const val RENDER_ORIGIN = "https://render.vnote.invalid/"
    }
}
