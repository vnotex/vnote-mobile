package com.example.vnote_mobile

import android.Manifest
import android.content.pm.PackageManager
import androidx.webkit.ProxyConfig
import androidx.webkit.ProxyController
import androidx.webkit.WebViewFeature
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.Bitmap
import android.net.Uri
import android.net.http.SslError
import android.os.Binder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Parcel
import android.os.ParcelFileDescriptor
import android.os.Process
import android.system.Os
import android.system.OsConstants
import android.view.KeyEvent
import android.view.View
import android.webkit.ClientCertRequest
import android.webkit.ConsoleMessage
import android.webkit.GeolocationPermissions
import android.webkit.HttpAuthHandler
import android.webkit.JsPromptResult
import android.webkit.JsResult
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.SslErrorHandler
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import org.json.JSONArray
import org.json.JSONObject

/** Owns native policy, never note/core authority. Flutter confirms every navigation intent. */
class WebSurfacePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var binding: FlutterPlugin.FlutterPluginBinding
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val ui = Handler(Looper.getMainLooper())
    private val files = Executors.newSingleThreadExecutor()
    private val timer = Executors.newSingleThreadScheduledExecutor()
    private val editors = mutableMapOf<String, Editor>()
    private val views = mutableMapOf<String, PreviewView>()
    private val lock = Any()
    private var active: Render? = null
    private var pending: Render? = null
    private val completed = mutableMapOf<String, Render>()
    private var attached = false

    private data class Editor(val web: WebView, val client: EditorClient, val nonce: String)
    private class Render(val surface: String, val preview: String, val id: String, val prefs: JSONObject,
                         val result: MethodChannel.Result) {
        val token = WebSurfaceSecurity.nonce()
        var snapshot: PreviewSnapshot? = null
        var endpoint: IBinder? = null
        var connection: ServiceConnection? = null
        var pid = -1
        var uid = -1
        var name = ""
        var timeout: ScheduledFuture<*>? = null
        var jobTimeout: ScheduledFuture<*>? = null
        var retired = false
        var retirementFailed = false
        var replied = false
        var cancelling = false
        var finished = false
        var failure: String? = null
        var outputHash: String? = null
        var joins = mutableListOf<(String?) -> Unit>()
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "vnote.mobile/web_surface")
        channel.setMethodCallHandler(this)
        attached = true
        WebSurfaceSecurity.installWorkerDenial()
        binding.platformViewRegistry.registerViewFactory("vnote.mobile/preview", object : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
            override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
                val map = args as? Map<*, *> ?: throw IllegalArgumentException("Preview arguments")
                require(map.keys == setOf("surfaceId"))
                val id = checkedId(map["surfaceId"])
                require(!views.containsKey(id))
                return PreviewView(context, id).also { views[id] = it }
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel.setMethodCallHandler(null)
        editors.keys.toList().forEach { disposeEditor(it) }
        views.values.toList().forEach { it.dispose() }
        synchronized(lock) {
            pending?.let { settleSuperseded(it) }; pending = null
            active?.let { cancelRender(it, "renderer_unavailable") }
        }
        maybeShutdown()
    }

    private fun maybeShutdown() {
        if (!attached && active == null && pending == null && views.isEmpty()) {
            files.shutdown()
            timer.shutdown()
        }
    }

    private fun checkedId(value: Any?): String = (value as? String)?.takeIf { WebSurfaceSecurity.id.matches(it) }
        ?: throw IllegalArgumentException("Invalid identity")
    private fun arguments(call: MethodCall, keys: Set<String>): Map<*, *> {
        val args = call.arguments as? Map<*, *> ?: throw IllegalArgumentException()
        require(args.keys == keys)
        return args
    }
    private fun success(result: MethodChannel.Result, value: Any? = null) { ui.post { result.success(value) } }
    private fun error(result: MethodChannel.Result, category: String) { ui.post { result.error(category, "Web surface unavailable.", null) } }
    private fun event(values: Map<String, Any>) { ui.post { if (attached) channel.invokeMethod("event", values) } }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configureEditor" -> {
                    val a = arguments(call, setOf("surfaceId", "webViewIdentifier"))
                    val id = checkedId(a["surfaceId"])
                    require(!editors.containsKey(id))
                    val rawIdentifier = a["webViewIdentifier"]
                    require(rawIdentifier is Int || rawIdentifier is Long)
                    val identifier = (rawIdentifier as Number).toLong()
                    val web = WebViewFlutterAndroidExternalApi.getWebView(binding, identifier) ?: throw IllegalStateException()
                    require(editors.values.none { it.web === web })
                    val original = web.webViewClient
                    val nonce = WebSurfaceSecurity.nonce()
                    val client = EditorClient(original, context) {
                        editors.remove(id)
                        event(mapOf("type" to "editorLost", "surfaceId" to id))
                    }
                    WebSurfaceSecurity.harden(web, preservePluginClient = true)
                    web.webViewClient = client
                    val editor = Editor(web, client, nonce)
                    editors[id] = editor
                    WebSurfaceSecurity.prepareNetwork(context) { ready ->
                        if (!ready) {
                            editors.remove(id)
                            error(result, "offline_policy_unavailable")
                        } else if (editors[id] === editor && attached) result.success(mapOf("entryUrl" to EDITOR_ORIGIN, "nonce" to nonce))
                        else error(result, "surface_stale")
                    }
                }
                "loadEditor" -> {
                    val id = checkedId(arguments(call, setOf("surfaceId"))["surfaceId"])
                    val editor = editors[id] ?: throw IllegalStateException()
                    if (!WebSurfaceSecurity.networkReady()) { error(result, "offline_policy_unavailable"); return }
                    val shell = WebSurfaceSecurity.shell(context, "editor", editor.nonce, EDITOR_ORIGIN, deferScript = true)
                    editor.client.load(editor.web, shell, result)
                }
                "disposeEditor" -> { disposeEditor(checkedId(arguments(call, setOf("surfaceId"))["surfaceId"])); result.success(null) }
                "render" -> {
                    val a = arguments(call, setOf("surfaceId", "previewId", "renderId", "preferences"))
                    val surface = checkedId(a["surfaceId"])
                    require(views.containsKey(surface))
                    val render = Render(surface, checkedId(a["previewId"]), checkedId(a["renderId"]),
                        WebSurfaceSecurity.preferences(JSONObject(a["preferences"] as? Map<*, *> ?: throw IllegalArgumentException())), result)
                    WebSurfaceSecurity.prepareNetwork(context) { ready ->
                        if (!ready) { reply(render, failure = "offline_policy_unavailable"); return@prepareNetwork }
                        synchronized(lock) {
                            if (!views.containsKey(surface) || active?.id == render.id || pending?.id == render.id || completed.values.any { it.id == render.id }) {
                                reply(render, failure = "surface_stale")
                            } else if (active?.retirementFailed == true) {
                                reply(render, failure = "renderer_unavailable")
                            } else {
                                views[surface]?.wanted = render.id
                                if (active == null) { active = render; prepare(render) }
                                else { pending?.let { settleSuperseded(it) }; pending = render }
                            }
                        }
                    }
                }
                "show" -> {
                    val a = arguments(call, setOf("surfaceId", "previewId", "renderId"))
                    val surface = checkedId(a["surfaceId"])
                    val id = checkedId(a["renderId"])
                    val preview = checkedId(a["previewId"])
                    val render = synchronized(lock) { completed[surface] } ?: throw IllegalStateException()
                    require(render.id == id && render.preview == preview && views[surface]?.wanted == id)
                    views[surface]!!.show(render, result)
                }
                "fragment" -> {
                    val a = arguments(call, setOf("surfaceId", "renderId", "fragment"))
                    val fragment = a["fragment"] as? String ?: throw IllegalArgumentException()
                    require(fragment.length <= 8192 && fragment.none { it.code < 32 || it.code == 127 })
                    views[checkedId(a["surfaceId"])]?.fragment(checkedId(a["renderId"]), fragment, result)
                        ?: throw IllegalStateException()
                }
                "preferences" -> {
                    val a = arguments(call, setOf("surfaceId", "preferences"))
                    val prefs = WebSurfaceSecurity.preferences(JSONObject(a["preferences"] as? Map<*, *> ?: throw IllegalArgumentException()))
                    views[checkedId(a["surfaceId"])]?.preferences(prefs) ?: throw IllegalStateException()
                    result.success(null)
                }
                "cancel" -> {
                    val a = arguments(call, setOf("surfaceId", "renderId"))
                    cancel(checkedId(a["surfaceId"]), checkedId(a["renderId"])) { failure ->
                        if (failure == null) success(result) else error(result, failure)
                    }
                }
                "close" -> {
                    val id = checkedId(arguments(call, setOf("surfaceId"))["surfaceId"])
                    close(id) { failure -> if (failure == null) success(result) else error(result, failure) }
                }
                "openExternal" -> {
                    val url = arguments(call, setOf("url"))["url"] as? String ?: throw IllegalArgumentException()
                    require(url.length <= 8192 && url.none { it.code < 32 || it.code == 127 || it == '\\' })
                    val uri = java.net.URI(url)
                    require(uri.scheme == "https" || uri.scheme == "http")
                    require(!uri.host.isNullOrEmpty() && uri.rawUserInfo == null && (uri.port == -1 || uri.port in 1..65535))
                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri.toASCIIString())).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (_: Exception) { result.error("surface_invalid", "Web surface request refused.", null) }
    }

    private fun disposeEditor(id: String) {
        val editor = editors.remove(id) ?: return
        editor.client.retire()
        editor.web.stopLoading()
        // Keep denial installed until webview_flutter destroys the view; never restore a weaker client.
    }

    private fun prepare(render: Render) {
        files.execute {
            try {
                val snapshot = PreviewSnapshot(context, render.preview, render.id)
                synchronized(lock) {
                    if (render.retired || render.cancelling) { snapshot.closeAndJoin(); return@execute }
                    render.snapshot = snapshot
                }
                snapshot.writeRequest(render.prefs)
                ui.post { if (!render.retired && !render.cancelling) bind(render) else finish(render) }
            } catch (_: Exception) { failBeforeBind(render) }
        }
    }

    private fun failBeforeBind(render: Render) {
        synchronized(lock) { if (!render.retired) render.failure = "renderer_unavailable" }
        finish(render)
    }

    private fun bind(render: Render) {
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName, binder: IBinder) {
                files.execute {
                    try {
                        synchronized(lock) {
                            // Android may auto-rebind after death; one generation owns only its original peer.
                            if (active !== render || render.retired || render.pid > 0) return@execute
                        }
                        val observer = object : Binder() {
                            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                                if (code != PreviewRenderService.EVENT) return super.onTransact(code, data, reply, flags)
                                if (Binder.getCallingUid() != Process.myUid()) throw SecurityException()
                                data.enforceInterface(PreviewRenderService.DESCRIPTOR)
                                val token = data.readString()
                                val event = data.readInt()
                                synchronized(lock) {
                                    if (active !== render || render.retired || render.cancelling || token != render.token ||
                                        render.endpoint !== binder || Binder.getCallingPid() != render.pid) throw SecurityException()
                                    when (event) {
                                        PreviewRenderService.READY -> {
                                            render.timeout?.cancel(false)
                                            render.timeout = timer.schedule({ cancelRender(render, "renderer_timeout") }, 5, TimeUnit.SECONDS)
                                        }
                                        PreviewRenderService.JOB_START -> {
                                            if (render.jobTimeout != null) throw SecurityException()
                                            render.jobTimeout = timer.schedule({ cancelRender(render, "renderer_timeout") }, 2, TimeUnit.SECONDS)
                                        }
                                        PreviewRenderService.JOB_DONE -> { render.jobTimeout?.cancel(false); render.jobTimeout = null }
                                        PreviewRenderService.COMPLETE -> {
                                            render.timeout?.cancel(false); render.jobTimeout?.cancel(false)
                                            render.finished = true
                                            retireProcess(render)
                                        }
                                        PreviewRenderService.FAILED -> timer.execute { cancelRender(render, "renderer_failed") }
                                        PreviewRenderService.POLICY_FAILED -> timer.execute { cancelRender(render, "offline_policy_unavailable") }
                                        else -> throw SecurityException()
                                    }
                                }
                                reply!!.writeNoException(); return true
                            }
                        }
                        val data = Parcel.obtain(); val reply = Parcel.obtain()
                        try {
                            data.writeInterfaceToken(PreviewRenderService.DESCRIPTOR); data.writeString(render.token); data.writeStrongBinder(observer)
                            require(binder.transact(PreviewRenderService.HELLO, data, reply, 0)); reply.readException()
                            val pid = reply.readInt(); val uid = reply.readInt(); val processName = reply.readString(); val token = reply.readString()
                            require(pid > 0 && pid != Process.myPid() && uid == Process.myUid() &&
                                processName == context.packageName + ":preview_renderer" && token == render.token)
                            synchronized(lock) {
                                if (active !== render || render.retired) throw IllegalStateException()
                                render.pid = pid; render.uid = uid; render.name = processName!!; render.endpoint = binder
                                binder.linkToDeath({ rendererDied(render, binder) }, 0)
                            }
                            if (render.cancelling) { cancelRender(render, render.failure); return@execute }
                            require(verified(render))
                            val snapshot = requireNotNull(render.snapshot)
                            snapshot.requestDescriptor().use { input ->
                                snapshot.outputDescriptor().use { output ->
                                    val start = Parcel.obtain(); val response = Parcel.obtain()
                                    try {
                                        start.writeInterfaceToken(PreviewRenderService.DESCRIPTOR); start.writeString(render.token)
                                        input.writeToParcel(start, 0); output.writeToParcel(start, 0)
                                        require(binder.transact(PreviewRenderService.START, start, response, 0)); response.readException()
                                    } finally { start.recycle(); response.recycle() }
                                }
                            }
                        } finally { data.recycle(); reply.recycle() }
                    } catch (_: Exception) { cancelRender(render, "renderer_unavailable") }
                }
            }
            override fun onServiceDisconnected(name: ComponentName) { rendererDied(render, render.endpoint) }
            override fun onBindingDied(name: ComponentName) { rendererDied(render, render.endpoint) }
            override fun onNullBinding(name: ComponentName) { failBeforeBind(render) }
        }
        synchronized(lock) {
            if (render.retired || render.cancelling) { finish(render); return }
            render.connection = connection
            // Trusted cold-process/WebView/bundle startup has its own bound.
            // READY replaces this with the unchanged 5s untrusted-work deadline.
            render.timeout = timer.schedule({ cancelRender(render, "renderer_timeout") }, 30, TimeUnit.SECONDS)
        }
        try {
            if (!context.bindService(Intent(context, PreviewRenderService::class.java), connection, Context.BIND_AUTO_CREATE)) failBeforeBind(render)
        } catch (_: Exception) { failBeforeBind(render) }
    }

    /** Called only by native background/Binder threads, never from WebView/eval callbacks. */
    private fun verified(render: Render): Boolean {
        val binder = render.endpoint ?: return false
        if (!binder.isBinderAlive || render.pid <= 0 || render.pid == Process.myPid() || render.uid != Process.myUid()) return false
        return try {
            val manager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
            manager.runningAppProcesses?.any {
                it.pid == render.pid && it.uid == render.uid && it.processName == context.packageName + ":preview_renderer" && it.processName == render.name
            } == true && binder.isBinderAlive
        } catch (_: Exception) { false }
    }

    private fun cancelRender(render: Render, category: String?) {
        synchronized(lock) {
            if (active !== render) return
            render.cancelling = true
            if (category != null) render.failure = category
        }
        if (!render.retired) retireProcess(render)
    }

    private fun retireProcess(render: Render) {
        timer.execute {
            synchronized(lock) {
                if (render.retired || active !== render) return@execute
                render.timeout?.cancel(false); render.jobTimeout?.cancel(false)
                val binder = render.endpoint
                if (binder == null) {
                    // No job can run before a verified handshake. Join queued file/handshake work first.
                    files.execute { finish(render) }
                } else if (verified(render)) {
                    // Live Binder + current token + exact UID/name/PID guard. Never a persisted PID.
                    try { Process.killProcess(render.pid) } catch (_: Exception) { retainUnproved(render) }
                    // Every generation gets a fresh process. Completion joins actual Binder death.
                } else if (!binder.isBinderAlive) rendererDied(render, binder)
                else {
                    retainUnproved(render)
                }
            }
        }
    }

    private fun retainUnproved(render: Render) {
        synchronized(lock) {
            if (render.retired || active !== render) return
            // Error completion is not a reader join. Keep the live binding and lease
            // until a later explicit retry kills a verified peer and Binder death joins it.
            render.retirementFailed = true
            render.cancelling = true
            render.failure = "renderer_unavailable"
            reply(render, failure = "renderer_unavailable")
            val queued = pending; pending = null
            if (queued != null) reply(queued, failure = "renderer_unavailable")
            val joins = render.joins; render.joins = mutableListOf()
            joins.forEach { it("renderer_unavailable") }
            event(mapOf("type" to "failure", "surfaceId" to render.surface, "renderId" to render.id, "category" to "renderer_unavailable"))
        }
    }

    private fun rendererDied(render: Render, binder: IBinder?) {
        synchronized(lock) {
            if (render.retired || active !== render || (binder != null && render.endpoint !== binder)) return
            if (render.endpoint?.isBinderAlive == true) {
                cancelRender(render, "renderer_unavailable")
                return
            }
            render.timeout?.cancel(false); render.jobTimeout?.cancel(false)
            render.endpoint = null
            if (!render.cancelling && !render.finished) render.failure = "renderer_failed"
        }
        files.execute { finish(render) }
    }

    private fun finish(render: Render) {
        synchronized(lock) {
            if (render.retired) return
            if (render.endpoint?.isBinderAlive == true) {
                // A queued handshake may have completed since a no-endpoint cancellation.
                cancelRender(render, render.failure)
                return
            }
            render.retired = true
            render.timeout?.cancel(false); render.jobTimeout?.cancel(false)
        }
        files.execute {
            var good = render.finished && !render.cancelling && render.failure == null
            val snapshot = render.snapshot
            if (good) try { render.outputHash = snapshot!!.outputDigest() } catch (_: Exception) {
                good = false; render.failure = "output_invalid"
            }
            snapshot?.removeRequest()
            if (!good) snapshot?.closeAndJoin()
            ui.post { publish(render, good) }
        }
    }

    private fun publish(render: Render, good: Boolean) {
        synchronized(lock) {
            val admit = good && !render.cancelling && render.failure == null && views[render.surface]?.wanted == render.id && attached
            if (good && !admit) {
                files.execute { render.snapshot?.closeAndJoin(); ui.post { publish(render, false) } }
                return
            }
            render.connection?.let { try { context.unbindService(it) } catch (_: Exception) {} }
            if (active === render) active = null
            if (admit) {
                val previous = completed.put(render.surface, render)
                if (previous != null && views[render.surface]?.snapshot !== previous.snapshot) files.execute { previous.snapshot?.closeAndJoin() }
                reply(render, ready = true)
            } else if (render.failure != null) {
                reply(render, failure = render.failure!!)
                event(mapOf("type" to "failure", "surfaceId" to render.surface, "renderId" to render.id, "category" to render.failure!!))
            } else settleSuperseded(render)
            val joins = render.joins; render.joins = mutableListOf()
            joins.forEach { it(null) }
            val next = pending; pending = null
            if (next != null && attached) { active = next; prepare(next) }
            else if (next != null) settleSuperseded(next)
            maybeShutdown()
        }
    }

    private fun reply(render: Render, ready: Boolean = false, failure: String? = null) {
        synchronized(lock) {
            if (render.replied) return
            render.replied = true
            if (failure != null) error(render.result, failure)
            else success(render.result, mapOf("status" to if (ready) "ready" else "superseded", "renderId" to render.id))
        }
    }

    private fun settleSuperseded(render: Render) = reply(render)

    private fun cancel(surface: String, id: String, joined: (String?) -> Unit) {
        var waiting = false
        var retained: PreviewSnapshot? = null
        val afterReaders: (String?) -> Unit = { failure -> files.execute { ui.post { joined(failure) } }; Unit }
        synchronized(lock) {
            pending?.takeIf { it.surface == surface && it.id == id }?.let { settleSuperseded(it); pending = null }
            active?.takeIf { it.surface == surface && it.id == id }?.let {
                it.joins.add(afterReaders); waiting = true; cancelRender(it, null)
            }
            completed[surface]?.takeIf { it.id == id }?.let { retained = it.snapshot; completed.remove(surface) }
        }
        val view = views[surface]
        if (view?.snapshot?.id == id) view.clear()
        retained?.let { owner -> files.execute { owner.closeAndJoin() } }
        if (!waiting) afterReaders(null)
    }

    private fun close(surface: String, joined: (String?) -> Unit) {
        val ids = synchronized(lock) {
            listOfNotNull(active?.takeIf { it.surface == surface }?.id, pending?.takeIf { it.surface == surface }?.id,
                completed[surface]?.id, views[surface]?.snapshot?.id).distinct()
        }
        views[surface]?.wanted = null
        fun next(index: Int) {
            if (index == ids.size) joined(null)
            else cancel(surface, ids[index]) { failure ->
                if (failure == null) next(index + 1) else joined(failure)
            }
        }
        next(0)
    }

    private inner class PreviewView(context: Context, val surface: String) : PlatformView {
        val web = WebView(context)
        var wanted: String? = null
        @Volatile var snapshot: PreviewSnapshot? = null
        private var disposed = false
        private var viewLost = false
        @Volatile private var proven = false
        @Volatile private var body: ByteArray? = null
        @Volatile private var page: String? = null
        private var document = 0L
        private var proofStarted = false
        private var installed = false
        private var output: String? = null
        private var outputBytes = 0
        private var installTimeout: ScheduledFuture<*>? = null
        private var prefs = JSONObject().put("dark", false).put("highContrast", false).put("fontScale", 1).put("reducedMotion", false)
        private var shown: MethodChannel.Result? = null
        private val poll = object : Runnable {
            override fun run() {
                val owner = snapshot ?: return
                val current = document
                if (!installed || disposed || viewLost) return
                val stamp = owner.admissionStamp()
                web.evaluateJavascript("window.vnotePreview.status()") { value ->
                    if (current == document && snapshot === owner && !disposed && !viewLost) {
                        try { owner.releaseOffscreen(JSONObject(value), stamp) } catch (_: Exception) { /* Retain admission on uncertain status. */ }
                        ui.postDelayed(this, 100)
                    }
                }
            }
        }
        init {
            WebSurfaceSecurity.harden(web, preservePluginClient = false)
            web.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val owner = snapshot ?: return true
                    if (installed && request.isForMainFrame && request.method == "GET") {
                        val handle = owner.navigation(request.url)
                        if (handle != null) event(mapOf("type" to "navigation", "surfaceId" to surface,
                            "renderId" to owner.id, "handle" to handle, "hasGesture" to request.hasGesture()))
                    }
                    return true
                }
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                    if (request.method != "GET") return WebSurfaceSecurity.denied()
                    val owner = snapshot ?: return WebSurfaceSecurity.denied()
                    if (request.isForMainFrame) {
                        val bytes = body
                        return if (request.url.toString() == page && bytes != null)
                            WebSurfaceSecurity.document(bytes, WebSurfaceSecurity.connectionAllowlist(PREVIEW_ORIGIN, owner.id))
                            else WebSurfaceSecurity.denied()
                    }
                    if (proven) owner.media(request.url)?.let { return it }
                    return WebSurfaceSecurity.bundleResponse(context, request, PREVIEW_ORIGIN)
                }
                override fun onPageFinished(view: WebView, url: String) {
                    val owner = snapshot ?: return
                    if (url != page || disposed || viewLost || proofStarted) return
                    proofStarted = true
                    val current = document
                    WebSurfaceSecurity.proveDocument(web) { allowed ->
                        if (!isCurrent(current, owner)) return@proveDocument
                        if (!allowed) fail("offline_policy_unavailable")
                        else { proven = true; install(current, owner) }
                    }
                }
                override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                    viewLost = true
                    fail("view_lost")
                    (web.parent as? android.view.ViewGroup)?.removeView(web)
                    web.destroy()
                    return true
                }
            }
        }
        override fun getView(): View = web
        private fun isCurrent(value: Long, owner: PreviewSnapshot): Boolean =
            !disposed && !viewLost && value == document && snapshot === owner && wanted == owner.id

        fun show(render: Render, result: MethodChannel.Result) {
            if (!WebSurfaceSecurity.networkReady()) { error(result, "offline_policy_unavailable"); return }
            files.execute {
                try {
                    val owner = requireNotNull(render.snapshot)
                    val content = owner.readOutput(requireNotNull(render.outputHash))
                    val shell = WebSurfaceSecurity.shell(context, "preview", WebSurfaceSecurity.nonce(), PREVIEW_ORIGIN, render.id)
                    ui.post {
                        if (disposed || viewLost || wanted != render.id || completed[surface] !== render) { error(result, "surface_stale"); return@post }
                        clear(owner)
                        snapshot = owner; prefs = render.prefs; shown = result
                        output = content.first; outputBytes = content.second
                        body = shell.toByteArray(Charsets.UTF_8) // Empty trusted document, never the note fragment.
                        page = PREVIEW_ORIGIN + "g/" + render.id + "/"
                        val current = document
                        installTimeout = timer.schedule({ ui.post { if (isCurrent(current, owner) && !installed) fail("output_invalid") } }, 10, TimeUnit.SECONDS)
                        web.loadUrl(requireNotNull(page))
                    }
                } catch (_: Exception) { error(result, "output_invalid") }
            }
        }

        private fun install(value: Long, owner: PreviewSnapshot) {
            val text = output ?: run { fail("output_invalid"); return }
            val begin = JSONObject().put("version", 1).put("renderId", owner.id).put("outputUnits", text.length).put("outputBytes", outputBytes)
            fun invoke(script: String, next: () -> Unit) {
                if (!isCurrent(value, owner) || !proven) return
                web.evaluateJavascript(script) { reply ->
                    if (isCurrent(value, owner)) {
                        if (reply == "true") next() else fail("output_invalid")
                    }
                }
            }
            fun append(offset: Int) {
                if (!isCurrent(value, owner)) return
                if (offset == text.length) {
                    invoke("window.vnotePreview.finish()") {
                        output = null; installed = true
                        installTimeout?.cancel(false); installTimeout = null
                        preferences(prefs)
                        val ready = shown; shown = null
                        if (ready != null) files.execute { success(ready) }
                        ui.removeCallbacks(poll); ui.post(poll)
                    }
                } else {
                    val end = minOf(text.length, offset + 32768)
                    invoke("window.vnotePreview.append($offset,${JSONObject.quote(text.substring(offset, end))})") { append(end) }
                }
            }
            invoke("window.vnotePreview.begin($begin)") { append(0) }
        }

        private fun fail(category: String) {
            snapshot?.let { event(mapOf("type" to "failure", "surfaceId" to surface, "renderId" to it.id, "category" to category)) }
            shown?.let { error(it, category) }; shown = null
            clear()
        }
        fun fragment(id: String, slug: String, result: MethodChannel.Result) {
            require(installed && proven && !disposed && !viewLost && snapshot?.id == id)
            val current = document
            web.evaluateJavascript("window.vnotePreview.fragment(${JSONObject.quote(slug)})") {
                if (current == document && installed && !disposed && snapshot?.id == id) success(result)
                else error(result, "surface_stale")
            }
        }
        fun preferences(value: JSONObject) {
            prefs = value
            if (installed && !disposed && !viewLost) web.evaluateJavascript("window.vnotePreview.preferences($value)", null)
        }
        fun clear(retaining: PreviewSnapshot? = null) {
            document++; ui.removeCallbacks(poll)
            installTimeout?.cancel(false); installTimeout = null
            val wasLoaded = body != null
            body = null; proven = false; proofStarted = false; installed = false; output = null
            if (!viewLost) { web.stopLoading(); if (wasLoaded) web.loadUrl("about:blank") }
            val old = snapshot; snapshot = null; page = null
            shown?.let { error(it, "surface_stale") }; shown = null
            if (old != null && old !== retaining) files.execute { old.closeAndJoin() }
        }
        override fun dispose() {
            if (disposed) return
            close(surface) {
                // Dispose the display even on error, never the unjoined active renderer.
                clear()
                synchronized(lock) {
                    completed.remove(surface)?.let { old -> files.execute { old.snapshot?.closeAndJoin() } }
                }
                if (!viewLost) web.destroy()
                views.remove(surface)
                maybeShutdown()
            }
            disposed = true
        }
    }

    companion object {
        const val EDITOR_ORIGIN = "https://editor.vnote.invalid/"
        const val PREVIEW_ORIGIN = "https://preview.vnote.invalid/"
    }
}

/** Denial wraps public installed clients rather than replacing Flutter's page/transport callbacks. */
private class EditorClient(private val delegate: WebViewClient,
                           private val context: Context, private val lost: () -> Unit) : WebViewClient() {
    @Volatile private var body: ByteArray? = null
    var proven = false
        private set
    private var boot: MethodChannel.Result? = null
    private var navigation = 0
    fun load(view: WebView, shell: String, result: MethodChannel.Result) {
        require(boot == null)
        body = shell.toByteArray(Charsets.UTF_8)
        proven = false; boot = result
        Handler(Looper.getMainLooper()).postDelayed({
            if (boot === result) {
                body = null; proven = false; navigation++; view.stopLoading()
                boot = null
                result.error("offline_policy_unavailable", "Native offline startup did not complete.", null)
            }
        }, 30000)
        view.loadUrl(WebSurfacePlugin.EDITOR_ORIGIN)
    }
    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
        val bytes = body
        return if (request.isForMainFrame && request.method == "GET" && request.url.toString() == WebSurfacePlugin.EDITOR_ORIGIN && bytes != null)
            WebSurfaceSecurity.document(bytes, "()") else WebSurfaceSecurity.denied()
    }
    override fun shouldInterceptRequest(view: WebView, url: String) = WebSurfaceSecurity.denied()
    override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
        if (proven && request.isForMainFrame && request.url.toString() == WebSurfacePlugin.EDITOR_ORIGIN) return delegate.shouldOverrideUrlLoading(view, request)
        return true
    }
    override fun shouldOverrideUrlLoading(view: WebView, url: String): Boolean =
        if (proven && url == WebSurfacePlugin.EDITOR_ORIGIN) delegate.shouldOverrideUrlLoading(view, url) else true
    override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) { proven = false; navigation++ }
    override fun onPageFinished(view: WebView, url: String) {
        if (url != WebSurfacePlugin.EDITOR_ORIGIN || proven || body == null) return
        val current = navigation
        WebSurfaceSecurity.proveDocument(view) { allowed ->
            if (current != navigation || body == null) return@proveDocument
            if (!allowed) {
                boot?.error("offline_policy_unavailable", "Native offline policy is unavailable.", null); boot = null
                body = null; navigation++; view.stopLoading()
                return@proveDocument
            }
            proven = true
            delegate.onPageStarted(view, url, null)
            // Until this proof no editor bundle executes, so even its ready bridge cannot publish a source.
            try {
                view.evaluateJavascript(WebSurfaceSecurity.script(context, "editor")) {
                    if (current == navigation && proven) {
                        delegate.onPageCommitVisible(view, url)
                        delegate.onPageFinished(view, url)
                        boot?.success(null); boot = null
                    }
                }
            } catch (_: Exception) {
                boot?.error("surface_invalid", "Editor startup failed.", null); boot = null
                body = null; proven = false; navigation++; view.stopLoading()
            }
        }
    }
    override fun onPageCommitVisible(view: WebView, url: String) { if (proven) delegate.onPageCommitVisible(view, url) }
    override fun onLoadResource(view: WebView, url: String) { if (proven) delegate.onLoadResource(view, url) }
    override fun doUpdateVisitedHistory(view: WebView, url: String, reload: Boolean) { if (proven) delegate.doUpdateVisitedHistory(view, url, reload) }
    override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) { if (proven) delegate.onReceivedError(view, request, error) }
    override fun onReceivedError(view: WebView, code: Int, description: String, url: String) { if (proven) delegate.onReceivedError(view, code, description, url) }
    override fun onReceivedHttpError(view: WebView, request: WebResourceRequest, response: WebResourceResponse) { if (proven) delegate.onReceivedHttpError(view, request, response) }
    override fun onScaleChanged(view: WebView, old: Float, new: Float) = delegate.onScaleChanged(view, old, new)
    override fun shouldOverrideKeyEvent(view: WebView, event: KeyEvent) = delegate.shouldOverrideKeyEvent(view, event)
    override fun onUnhandledKeyEvent(view: WebView, event: KeyEvent) = delegate.onUnhandledKeyEvent(view, event)
    override fun onReceivedSslError(view: WebView, handler: SslErrorHandler, error: SslError) = handler.cancel()
    override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String) = handler.cancel()
    override fun onReceivedClientCertRequest(view: WebView, request: ClientCertRequest) = request.cancel()
    override fun onFormResubmission(view: WebView, dontResend: Message, resend: Message) = dontResend.sendToTarget()
    fun retire() { body = null; proven = false; navigation++; boot?.error("surface_stale", "Editor retired.", null); boot = null }
    override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
        retire(); lost(); (view.parent as? android.view.ViewGroup)?.removeView(view); view.destroy()
        return true // Flutter's installed client has no loss handler; its default false would kill the app.
    }
}

internal object WebSurfaceSecurity {
    val id = Regex("[0-9a-f]{32}")
    private val digest = Regex("[0-9a-f]{64}")
    private val random = SecureRandom()
    private val policyUi = Handler(Looper.getMainLooper())
    private val policyWaiters = mutableListOf<(Boolean) -> Unit>()
    private var policyStarted = false
    @Volatile private var policyReady = false
    private var policySettled = false
    private var proxySocket: java.net.ServerSocket? = null
    private val manifests = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()

    fun networkReady(): Boolean = policyReady
    fun prepareNetwork(context: Context, done: (Boolean) -> Unit) {
        check(Looper.myLooper() == Looper.getMainLooper())
        if (policySettled) { done(policyReady); return }
        policyWaiters.add(done)
        if (policyStarted) return
        policyStarted = true
        fun settle(ready: Boolean) {
            if (policySettled) return
            policySettled = true; policyReady = ready
            val waiters = policyWaiters.toList(); policyWaiters.clear(); waiters.forEach { it(ready) }
        }
        policyUi.postDelayed({ settle(false) }, 5000)
        try {
            val version = WebView.getCurrentWebViewPackage()?.versionName?.substringBefore('.')?.toIntOrNull()
            if (version == null || version < 152) { settle(false); return }
            if (context.checkSelfPermission(Manifest.permission.INTERNET) != PackageManager.PERMISSION_GRANTED) {
                settle(true); return // The OS denies every network socket. No loopback permission needed.
            }
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.PROXY_OVERRIDE)) { settle(false); return }
            val socket = java.net.ServerSocket(0, 16, java.net.InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
            proxySocket = socket // Never release this port while a process WebView can use the override.
            val response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray(Charsets.US_ASCII)
            Thread({
                while (!socket.isClosed) {
                    try {
                        socket.accept().use { client ->
                            // Never read/parse/log a request, never CONNECT, relay, resolve, or serve files.
                            try { client.getOutputStream().write(response) } catch (_: IOException) {}
                        }
                    } catch (_: IOException) {
                        // Keep the bound port owned. A failed deny server still has no direct fallback.
                        policyReady = false
                        policyUi.post { settle(false) }
                        break
                    }
                }
            }, "VNoteDenyProxy").apply { isDaemon = true; start() }
            val proxy = ProxyConfig.Builder().addProxyRule("http://127.0.0.1:${socket.localPort}").removeImplicitRules().build()
            ProxyController.getInstance().setProxyOverride(proxy, java.util.concurrent.Executor { policyUi.post(it) }) { settle(true) }
        } catch (_: Exception) { settle(false) }
    }

    fun document(body: ByteArray, allowlist: String): WebResourceResponse = WebResourceResponse(
        "text/html", "UTF-8", 200, "OK", mapOf(
            "Connection-Allowlist" to "$allowlist; redirects=block; webrtc=block",
            "Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff",
            "Referrer-Policy" to "no-referrer", "X-DNS-Prefetch-Control" to "off",
            "Permissions-Policy" to "camera=(), microphone=(), geolocation=()"
        ), ByteArrayInputStream(body))

    fun connectionAllowlist(origin: String, renderId: String? = null): String {
        val base = origin.removeSuffix("/")
        val paths = mutableListOf("$base/fonts/*")
        if (renderId != null) { require(id.matches(renderId)); paths.add("$base/g/$renderId/media/*"); paths.add("$base/g/$renderId/nav/*") }
        return paths.joinToString(" ", "(", ")") { "\"$it\"" }
    }

    fun proveDocument(web: WebView, done: (Boolean) -> Unit) {
        if (!networkReady()) { done(false); return }
        var settled = false
        fun finish(value: Boolean) { if (!settled) { settled = true; done(value) } }
        policyUi.postDelayed({ finish(false) }, 2000)
        // Positive native-policy behavior, not a JS API mask. No offer, negotiation or data channel.
        val probe = "(()=>{let p;try{p=new RTCPeerConnection({iceServers:[{urls:'stun:127.0.0.1:9'}]});return p.getConfiguration().iceServers.length===0;}catch(_){return false;}finally{if(p)p.close();}})()"
        try { web.evaluateJavascript(probe) { finish(it == "true") } } catch (_: Exception) { finish(false) }
    }
    fun nonce(): String = ByteArray(16).also { random.nextBytes(it) }.joinToString("") { "%02x".format(it.toInt() and 255) }
    fun utf8(bytes: ByteArray): String = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(bytes)).toString()
    fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it.toInt() and 255) }
    fun readBounded(input: InputStream, limit: Int): ByteArray {
        val out = ByteArrayOutputStream(minOf(limit, 65536)); val block = ByteArray(65536)
        while (true) {
            val n = input.read(block)
            if (n < 0) break
            if (out.size() + n > limit) throw IOException("Bound exceeded")
            out.write(block, 0, n)
        }
        return out.toByteArray()
    }
    fun preferences(value: JSONObject): JSONObject {
        require(value.keys().asSequence().toSet() == setOf("dark", "highContrast", "fontScale", "reducedMotion"))
        require(value.get("dark") is Boolean && value.get("highContrast") is Boolean && value.get("reducedMotion") is Boolean)
        val scale = value.get("fontScale") as? Number ?: throw IllegalArgumentException()
        require(scale.toDouble().isFinite() && scale.toDouble() in 0.75..3.0)
        return value
    }
    fun denied() = WebResourceResponse("text/plain", "UTF-8", 403, "Forbidden", mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"), ByteArrayInputStream(ByteArray(0)))
    fun installWorkerDenial() {
        val service = ServiceWorkerController.getInstance()
        service.serviceWorkerWebSettings.apply { blockNetworkLoads = true; allowContentAccess = false; allowFileAccess = false; cacheMode = WebSettings.LOAD_NO_CACHE }
        service.setServiceWorkerClient(object : ServiceWorkerClient() {
            override fun shouldInterceptRequest(request: WebResourceRequest) = denied()
        })
    }
    fun harden(web: WebView, preservePluginClient: Boolean) {
        web.settings.apply {
            javaScriptEnabled = true
            blockNetworkLoads = true
            blockNetworkImage = false // Exact native media routes remain usable; all network loads are denied.
            allowContentAccess = false; allowFileAccess = false
            allowFileAccessFromFileURLs = false; allowUniversalAccessFromFileURLs = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            javaScriptCanOpenWindowsAutomatically = false; setSupportMultipleWindows(false)
            domStorageEnabled = false; databaseEnabled = false; setGeolocationEnabled(false)
            cacheMode = WebSettings.LOAD_NO_CACHE; mediaPlaybackRequiresUserGesture = true
            saveFormData = false
            safeBrowsingEnabled = false
        }
        web.removeJavascriptInterface("searchBoxJavaBridge_")
        web.removeJavascriptInterface("accessibility")
        web.removeJavascriptInterface("accessibilityTraversal")
        web.setDownloadListener { _, _, _, _, _ -> /* Deliberately denied; export uses Flutter confirmation. */ }
        // Flutter owns a security-specialized client; retain it and use its public
        // Dart denial callbacks. Only native-owned views accept this client.
        if (preservePluginClient) return
        web.webChromeClient = object : WebChromeClient() {
            override fun onConsoleMessage(message: ConsoleMessage) = true
            override fun onCreateWindow(view: WebView, dialog: Boolean, gesture: Boolean, message: Message) = false
            override fun onPermissionRequest(request: PermissionRequest) = request.deny()
            override fun onGeolocationPermissionsShowPrompt(origin: String, callback: GeolocationPermissions.Callback) = callback.invoke(origin, false, false)
            override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean { callback.onReceiveValue(null); return true }
            override fun onJsAlert(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
            override fun onJsConfirm(view: WebView, url: String, message: String, result: JsResult): Boolean { result.cancel(); return true }
            override fun onJsPrompt(view: WebView, url: String, message: String, default: String, result: JsPromptResult): Boolean { result.cancel(); return true }
        }
    }
    private fun asset(context: Context, group: String, name: String): ByteArray {
        require(group == "editor" || group == "preview")
        require(name.matches(Regex("(?:fonts/)?[A-Za-z0-9_.-]+")))
        val prefix = "apps/vnote_mobile/assets/$group/"
        val manifest = manifests.getOrPut(group) {
            context.assets.open("flutter_assets/assets/$group/manifest.json").use { JSONObject(utf8(readBounded(it, 1024 * 1024))) }
        }
        require(manifest.getInt("version") == 2)
        val expected = manifest.getJSONObject("outputs").getString(prefix + name)
        require(digest.matches(expected))
        val bytes = context.assets.open("flutter_assets/assets/$group/$name").use { readBounded(it, 16 * 1024 * 1024) }
        require(hash(bytes) == expected)
        return bytes
    }
    fun script(context: Context, kind: String): String = utf8(asset(context, if (kind == "editor") "editor" else "preview", "$kind.js"))
    private val scriptEnd = "</script".toByteArray(Charsets.US_ASCII)
    private val styleEnd = "</style".toByteArray(Charsets.US_ASCII)
    private fun hasClosingTag(source: ByteArray, ending: ByteArray): Boolean {
        var at = 0
        while (at <= source.size - ending.size) {
            if (source[at].toInt() == 60 && source[at + 1].toInt() == 47) {
                var index = 2
                while (index < ending.size && (source[at + index].toInt() or 32) == ending[index].toInt()) index++
                if (index == ending.size) return true
            }
            at++
        }
        return false
    }
    fun shell(context: Context, kind: String, nonce: String, origin: String, renderId: String = "", deferScript: Boolean = false): String {
        require(id.matches(nonce))
        val group = if (kind == "editor") "editor" else "preview"
        val name = if (kind == "editor") "index.html" else "$kind.html"
        var html = utf8(asset(context, group, name))
        val script = if (deferScript) "" else {
            val bytes = asset(context, group, "$kind.js")
            require(!hasClosingTag(bytes, scriptEnd))
            utf8(bytes)
        }
        val styleBytes = asset(context, group, if (kind == "editor") "editor.css" else "preview.css")
        require(!hasClosingTag(styleBytes, styleEnd))
        val style = utf8(styleBytes)
        require(html.contains("__VNOTE_NONCE__") && html.contains("__VNOTE_SCRIPT__") && html.contains("__VNOTE_STYLE__"))
        html = html.replace("__VNOTE_NONCE__", nonce).replace("__VNOTE_ASSET_ORIGIN__", origin.removeSuffix("/"))
            .replace("__VNOTE_STYLE__", style)
        if (kind == "preview") {
            require(id.matches(renderId) && html.contains("__VNOTE_RENDER_ID__"))
            html = html.replace("__VNOTE_RENDER_ID__", renderId)
        }
        // Insert the large script last: later template substitutions must not
        // repeatedly scan/copy a multi-megabyte bundle on a cold Android runtime.
        return html.replace("__VNOTE_SCRIPT__", script)
    }
    fun bundleResponse(context: Context, request: WebResourceRequest, origin: String): WebResourceResponse {
        val uri = request.url
        if (request.method != "GET" || request.isForMainFrame || !exactOrigin(uri, origin) || uri.encodedQuery != null || uri.encodedFragment != null) return denied()
        val path = uri.encodedPath ?: return denied()
        val name = when {
            path.matches(Regex("/fonts/[A-Za-z0-9_.-]+\\.woff2")) -> path.removePrefix("/")
            else -> return denied() // Script and style are nonce-inline; never executable fetch routes.
        }
        return try {
            val bytes = asset(context, "preview", name)
            WebResourceResponse("font/woff2", null, 200, "OK", mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"), ByteArrayInputStream(bytes))
        } catch (_: Exception) { denied() }
    }
    fun exactOrigin(uri: Uri, origin: String): Boolean {
        val expected = Uri.parse(origin)
        return uri.scheme == expected.scheme && uri.encodedAuthority == expected.encodedAuthority && uri.port == -1 && uri.userInfo == null
    }
    fun directory(file: File) {
        require(file.canonicalFile == file && OsConstants.S_ISDIR(Os.lstat(file.path).st_mode))
    }
    fun readFile(file: File, cap: Int): ByteArray = open(file, false).use { descriptor ->
        val size = Os.fstat(descriptor.fileDescriptor).st_size
        require(size in 0..cap.toLong())
        val bytes = ByteArray(size.toInt())
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            var offset = 0
            while (offset < bytes.size) { val n = input.read(bytes, offset, bytes.size - offset); if (n <= 0) throw IOException("Incomplete file"); offset += n }
            require(input.read() == -1)
        }
        bytes
    }
    fun fileDigest(file: File, cap: Int): String = open(file, false).use { descriptor ->
        val digest = MessageDigest.getInstance("SHA-256")
        val block = ByteArray(65536)
        var total = 0
        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use { input ->
            while (true) {
                val n = input.read(block)
                if (n < 0) break
                total += n; require(total <= cap)
                digest.update(block, 0, n)
            }
        }
        digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    fun open(file: File, write: Boolean): ParcelFileDescriptor {
        directory(requireNotNull(file.parentFile))
        val flags = if (write) OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL else OsConstants.O_RDONLY
        val fd = Os.open(file.path, flags or OsConstants.O_CLOEXEC or OsConstants.O_NOFOLLOW, 384)
        try {
            val info = Os.fstat(fd)
            require(OsConstants.S_ISREG(info.st_mode) && info.st_nlink == 1L)
            val named = Os.lstat(file.path)
            require(named.st_dev == info.st_dev && named.st_ino == info.st_ino)
            return ParcelFileDescriptor.dup(fd)
        } finally { Os.close(fd) }
    }
}

/** Immutable snapshot capabilities; paths are all constructed from fixed names and opaque IDs. */
private class PreviewSnapshot(context: Context, val preview: String, val id: String) {
    private val root: File
    private val manifest: JSONObject
    private val images = mutableMapOf<String, JSONObject>()
    private val navigation = mutableSetOf<String>()
    private val streams = mutableSetOf<InputStream>()
    private val admitted = mutableMapOf<String, Long>()
    private var readers = 0
    private var admissionVersion = 0L
    private var closed = false
    private val gate = Object()
    init {
        val base = context.filesDir.canonicalFile
        WebSurfaceSecurity.directory(base)
        val previews = File(base, "previews"); WebSurfaceSecurity.directory(previews)
        val parent = File(previews, preview); WebSurfaceSecurity.directory(parent)
        root = File(parent, id); WebSurfaceSecurity.directory(root)
        require(!File(root, "revoked.json").exists())
        val raw = WebSurfaceSecurity.readFile(File(root, "manifest.json"), 16 * 1024 * 1024)
        val sealed = WebSurfaceSecurity.utf8(WebSurfaceSecurity.readFile(File(root, "manifest.sha256"), 64))
        require(WebSurfaceSecurity.hash(raw) == sealed)
        manifest = JSONObject(WebSurfaceSecurity.utf8(raw))
        require(manifest.keys().asSequence().toSet() == setOf("version", "previewId", "renderId", "sourceRevision", "sourceHash", "sourceBytes", "notebookId", "nodeId", "images", "files", "navigation", "encodedBytes"))
        require(manifest.getInt("version") == 1 && manifest.getString("previewId") == preview && manifest.getString("renderId") == id)
        require(manifest.getLong("encodedBytes") in 0..64L * 1024 * 1024)
        require(manifest.getLong("sourceBytes") in 0..4L * 1024 * 1024)
        val fileEntries = manifest.getJSONArray("files"); require(fileEntries.length() <= 200)
        val filesByHandle = mutableMapOf<String, JSONObject>()
        var encodedBytes = 0L
        for (i in 0 until fileEntries.length()) {
            val entry = fileEntries.getJSONObject(i)
            val handle = entry.getString("handle")
            require(WebSurfaceSecurity.id.matches(handle) && !filesByHandle.containsKey(handle))
            val bytes = entry.getLong("bytes"); require(bytes in 0..64L * 1024 * 1024)
            encodedBytes += bytes; require(encodedBytes <= 64L * 1024 * 1024)
            filesByHandle[handle] = entry
        }
        require(encodedBytes == manifest.getLong("encodedBytes"))
        val entries = manifest.getJSONArray("images"); require(entries.length() <= 200)
        for (i in 0 until entries.length()) {
            val image = entries.getJSONObject(i); val handle = image.getString("handle")
            require(WebSurfaceSecurity.id.matches(handle))
            require(image.getString("mime") in setOf("image/png", "image/jpeg", "image/webp"))
            require(image.getLong("bytes") in 1..16L * 1024 * 1024)
            val file = filesByHandle[handle] ?: throw IOException("Missing image capability")
            require(file.getLong("bytes") == image.getLong("bytes") && file.getString("mime") == image.getString("mime") && file.getString("sha256") == image.getString("sha256"))
            val width = image.getLong("width"); val height = image.getLong("height")
            require(width in 1L..16000000L && height in 1L..16000000L && width * height <= 16000000L)
            images[handle]?.let { require(it.getString("sha256") == image.getString("sha256")) }
            images[handle] = image
        }
        val nav = manifest.getJSONArray("navigation"); require(nav.length() <= 100000)
        for (i in 0 until nav.length()) { val handle = nav.getJSONObject(i).getString("handle"); require(WebSurfaceSecurity.id.matches(handle)); navigation.add(handle) }
    }
    fun writeRequest(prefs: JSONObject) {
        val source = WebSurfaceSecurity.readFile(File(root, "source.md"), 4 * 1024 * 1024)
        require(source.size.toLong() == manifest.getLong("sourceBytes") && WebSurfaceSecurity.hash(source) == manifest.getString("sourceHash"))
        val text = WebSurfaceSecurity.utf8(source); require(!text.contains('\u0000'))
        val projectedImages = JSONArray()
        val rawImages = manifest.getJSONArray("images")
        for (i in 0 until rawImages.length()) {
            val image = rawImages.getJSONObject(i)
            projectedImages.put(JSONObject().put("source", image.getString("source")).put("handle", image.getString("handle"))
                .put("width", image.getLong("width")).put("height", image.getLong("height")))
        }
        val projectedNav = JSONArray(); val nav = manifest.getJSONArray("navigation")
        for (i in 0 until nav.length()) { val item = nav.getJSONObject(i); projectedNav.put(JSONObject().put("source", item.getString("source")).put("handle", item.getString("handle"))) }
        val request = JSONObject().put("version", 1).put("renderId", id).put("source", text)
            .put("mediaBase", WebSurfacePlugin.PREVIEW_ORIGIN + "g/$id/media/")
            .put("navBase", WebSurfacePlugin.PREVIEW_ORIGIN + "g/$id/nav/")
            .put("images", projectedImages).put("navigation", projectedNav).put("preferences", prefs)
        val bytes = request.toString().toByteArray(Charsets.UTF_8); require(bytes.size <= 48 * 1024 * 1024)
        WebSurfaceSecurity.open(File(root, "renderer-request.json"), true).use { descriptor ->
            ParcelFileDescriptor.AutoCloseOutputStream(descriptor).use { it.write(bytes); it.fd.sync() }
        }
    }
    fun requestDescriptor() = WebSurfaceSecurity.open(File(root, "renderer-request.json"), false)
    fun outputDescriptor() = WebSurfaceSecurity.open(File(root, "output.html"), true)
    fun removeRequest() { File(root, "renderer-request.json").delete() }
    fun outputDigest(): String = WebSurfaceSecurity.fileDigest(File(root, "output.html"), 16 * 1024 * 1024)
    fun readOutput(expected: String): Pair<String, Int> {
        synchronized(gate) { require(!closed) }
        require(!File(root, "revoked.json").exists())
        val bytes = WebSurfaceSecurity.readFile(File(root, "output.html"), 16 * 1024 * 1024)
        require(WebSurfaceSecurity.hash(bytes) == expected)
        return WebSurfaceSecurity.utf8(bytes) to bytes.size
    }
    fun navigation(uri: Uri): String? {
        synchronized(gate) { if (closed) return null }
        if (File(root, "revoked.json").exists()) return null
        if (!WebSurfaceSecurity.exactOrigin(uri, WebSurfacePlugin.PREVIEW_ORIGIN) || uri.encodedQuery != null || uri.encodedFragment != null) return null
        val prefix = "/g/$id/nav/"; val path = uri.encodedPath ?: return null
        if (!path.startsWith(prefix)) return null
        return path.removePrefix(prefix).takeIf { navigation.contains(it) }
    }
    fun media(uri: Uri): WebResourceResponse? {
        if (!WebSurfaceSecurity.exactOrigin(uri, WebSurfacePlugin.PREVIEW_ORIGIN)) return WebSurfaceSecurity.denied()
        val prefix = "/g/$id/media/"; val path = uri.encodedPath ?: return WebSurfaceSecurity.denied()
        if (!path.startsWith(prefix)) return null
        if (uri.encodedQuery != null || uri.encodedFragment != null) return WebSurfaceSecurity.denied()
        val handle = path.removePrefix(prefix); val item = images[handle] ?: return WebSurfaceSecurity.denied()
        val cost = item.getLong("width") * item.getLong("height") * 4
        synchronized(gate) {
            if (closed || readers >= 4 || (!admitted.containsKey(handle) && admitted.values.sum() + cost > 64L * 1024 * 1024)) return WebSurfaceSecurity.denied()
            admitted[handle] = cost; readers++; admissionVersion++
        }
        var descriptor: ParcelFileDescriptor? = null
        try {
            require(!File(root, "revoked.json").exists())
            val files = File(root, "files"); WebSurfaceSecurity.directory(files)
            descriptor = WebSurfaceSecurity.open(File(files, handle), false)
            val stat = Os.fstat(descriptor.fileDescriptor); require(stat.st_size == item.getLong("bytes"))
            val digest = MessageDigest.getInstance("SHA-256"); val buffer = ByteArray(65536)
            var checked = 0L
            while (true) {
                val n = Os.read(descriptor.fileDescriptor, buffer, 0, buffer.size)
                if (n <= 0) break
                checked += n; require(checked <= stat.st_size)
                digest.update(buffer, 0, n)
            }
            require(checked == stat.st_size)
            require(digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) } == item.getString("sha256"))
            Os.lseek(descriptor.fileDescriptor, 0, OsConstants.SEEK_SET)
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeFileDescriptor(descriptor.fileDescriptor, null, bounds)
            require(bounds.outWidth.toLong() == item.getLong("width") && bounds.outHeight.toLong() == item.getLong("height") && bounds.outMimeType == item.getString("mime"))
            Os.lseek(descriptor.fileDescriptor, 0, OsConstants.SEEK_SET)
            val owned = descriptor; descriptor = null
            val response = object : FilterInputStream(ParcelFileDescriptor.AutoCloseInputStream(owned)) {
                private var ended = false
                override fun close() {
                    synchronized(gate) {
                        if (ended) return
                        ended = true
                        try { super.close() } finally { streams.remove(this); readers--; gate.notifyAll() }
                    }
                }
            }
            synchronized(gate) {
                if (closed) { response.close(); return WebSurfaceSecurity.denied() }
                streams.add(response)
            }
            return WebResourceResponse(item.getString("mime"), null, 200, "OK", mapOf("Cache-Control" to "no-store", "X-Content-Type-Options" to "nosniff"), response)
        } catch (_: Exception) {
            descriptor?.close()
            synchronized(gate) { readers--; gate.notifyAll() }
            return WebSurfaceSecurity.denied()
        }
    }
    fun admissionStamp(): Long = synchronized(gate) { admissionVersion }
    fun releaseOffscreen(status: JSONObject, stamp: Long) {
        require(status.getInt("version") == 1 && status.getString("renderId") == id)
        val list = status.getJSONArray("images"); require(list.length() <= 200)
        val held = mutableSetOf<String>()
        for (i in 0 until list.length()) { val handle = list.getString(i); require(images.containsKey(handle)); held.add(handle) }
        synchronized(gate) { if (stamp == admissionVersion) admitted.keys.retainAll(held) }
    }
    fun closeAndJoin() {
        synchronized(gate) {
            closed = true
            streams.toList().forEach { try { it.close() } catch (_: Exception) {} }
            while (readers > 0) gate.wait()
            admitted.clear()
        }
    }
}
