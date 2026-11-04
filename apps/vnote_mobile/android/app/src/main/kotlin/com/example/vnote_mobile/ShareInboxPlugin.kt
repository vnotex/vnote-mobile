package com.example.vnote_mobile

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.Keep
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Main-engine adapter only. The stopped-app receiver does not instantiate this class. */
@Keep
class ShareInboxPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var activity: ActivityPluginBinding? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var attached = false
    private var nextRequest = 0x5800
    private var choosing: Choice? = null

    private class Choice(val code: Int, val token: String, val callback: PendingIntent,
        val result: MethodChannel.Result, val inbox: ShareInbox, val leaseId: String, var selected: Boolean = false)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        attached = true
        channel = MethodChannel(binding.binaryMessenger, "vnote.mobile/share_inbox").also { it.setMethodCallHandler(this) }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel?.setMethodCallHandler(null)
        channel = null
        detachActivity(false)
        context = null
        // The worker joins its copy naturally. Reader snapshots are never engine-owned temporary files.
        worker.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivityForConfigChanges() = detachActivity(true)
    override fun onDetachedFromActivity() = detachActivity(false)
    private fun detachActivity(configuration: Boolean) {
        activity?.removeActivityResultListener(this)
        activity = null
        if (!configuration) choosing?.let { finish(it, "unavailable", returned = false) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val app = context
        if (!attached || app == null) { result.error("unavailable", ERROR_MESSAGE, null); return }
        if (call.method !in METHODS) { result.notImplemented(); return }
        val args: Map<*, *>
        try {
            args = arguments(call)
        } catch (_: Exception) {
            result.error("invalid_request", ERROR_MESSAGE, null)
            return
        }
        if (call.method in setOf("export", "shareExport") && choosing != null) {
            result.success(mapOf("status" to "failed")); return
        }
        worker.execute {
            try {
                val inbox = ShareInbox(app)
                val value: Any? = when (call.method) {
                    "getLocale" -> inbox.locale()
                    "setLocale" -> { inbox.setLocale(text(args, "locale")); null }
                    "list" -> inbox.list()
                    "activate" -> { inbox.activate(::activate); null }
                    "claim" -> {
                        val target = args["target"] as? Map<*, *> ?: throw ShareFailure("invalid_request")
                        if (target.keys != TARGET_KEYS || target.values.any { it !is String }) throw ShareFailure("invalid_request")
                        inbox.claim(text(args, "id"), text(args, "operationId"), JSONObject(target))
                    }
                    "stage" -> inbox.stage(text(args, "id"), text(args, "operationId"))
                    "consume" -> { inbox.consume(text(args, "id"), text(args, "operationId"), text(args, "cohortId"), ::prove); null }
                    "discard" -> { inbox.discard(text(args, "id"), ::prove); null }
                    "anotherCopy" -> inbox.anotherCopy(text(args, "id"))
                    "dismissDuplicate" -> { inbox.dismissDuplicate(text(args, "id")); null }
                    "forgetHistory" -> { inbox.forgetHistory(); null }
                    "cleanupExports" -> { inbox.cleanupExports(); null }
                    "export" -> inbox.export(text(args, "id"))
                    "shareExport" -> inbox.shareExport(text(args, "operationId"), text(args, "scope"),
                        text(args, "path"), text(args, "suggestedName"), ::checkExport)
                    else -> throw ShareFailure("invalid_request")
                }
                main.post {
                    if (value is ShareInbox.Outgoing) launch(app, inbox, value, result)
                    else result.success(value)
                }
            } catch (error: Exception) {
                val code = if (error is ShareFailure) error.code else "share_unavailable"
                main.post {
                    if (call.method == "export" || call.method == "shareExport") {
                        if (code == "inbox_full") result.error("share_quota", QUOTA_MESSAGE, null)
                        else result.success(mapOf("status" to "failed"))
                    }
                    else result.error(code, ERROR_MESSAGE, null)
                }
            }
        }
    }

    private fun launch(app: Context, inbox: ShareInbox, outgoing: ShareInbox.Outgoing, result: MethodChannel.Result) {
        val owner = activity?.activity
        if (!attached || owner == null || owner.isFinishing || owner.isDestroyed || nextRequest > 0x5FFF) {
            result.success(mapOf("status" to "unavailable")); return
        }
        if (choosing != null) { result.success(mapOf("status" to "failed")); return }
        val token = UUID.randomUUID().toString().replace("-", "")
        val code = nextRequest++
        val callbackIntent = Intent(app, SelectionReceiver::class.java).setData(Uri.parse("vnote-share-choice:$token"))
        val callback = PendingIntent.getBroadcast(app, code, callbackIntent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val choice = Choice(code, token, callback, result, inbox, outgoing.id)
        choosing = choice
        choices[token] = {
            choice.selected = true
            // The authorized chooser callback proves handoff. Waiting for the
            // recipient Activity to finish would incorrectly retain the UI lease.
            finish(choice, "shared")
        }
        worker.execute {
            try {
                inbox.beginChooser(outgoing.id, token)
            } catch (error: Exception) {
                val status = if ((error as? ShareFailure)?.code == "inbox_full") "share_quota" else "failed"
                main.post { finish(choice, status, returned = false) }
                return@execute
            }
            main.post {
                if (choosing !== choice || !attached) {
                    // This chooser was never launched; unlike detach of an already launched chooser, absence is known.
                    if (!worker.isShutdown) worker.execute {
                        try { inbox.endChooser(outgoing.id, token) } catch (_: Exception) { }
                    }
                    return@post
                }
                try {
                    val files = outgoing.files
                    val send = Intent(if (files.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                        type = if (files.all { it.mime == files.first().mime }) files.first().mime else "*/*"
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        if (files.size == 1) putExtra(Intent.EXTRA_STREAM, files.first().uri)
                        else putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(files.map { it.uri }))
                        clipData = ClipData.newUri(app.contentResolver, files.first().name, files.first().uri).also { clip ->
                            for (file in files.drop(1)) clip.addItem(ClipData.Item(file.uri))
                        }
                    }
                    val chooser = Intent.createChooser(send, null, callback.intentSender).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        clipData = send.clipData
                    }
                    val current = activity?.activity ?: throw ShareFailure("unavailable")
                    if (current.isFinishing || current.isDestroyed) throw ShareFailure("unavailable")
                    current.startActivityForResult(chooser, code)
                } catch (_: Exception) {
                    finish(choice, "unavailable")
                }
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val choice = choosing ?: return false
        if (requestCode != choice.code) return false
        // Selection means only handed to system UI, never that a recipient persisted the bytes.
        finish(choice, if (choice.selected || resultCode == Activity.RESULT_OK) "shared" else "cancelled")
        return true
    }

    private fun finish(choice: Choice, status: String, returned: Boolean = true) {
        if (choosing !== choice) return
        choosing = null
        choices.remove(choice.token)
        choice.callback.cancel()
        if (returned) {
            worker.execute {
                try { choice.inbox.endChooser(choice.leaseId, choice.token) } catch (_: Exception) { /* Retain uncertain lease. */ }
                main.post { choice.result.success(mapOf("status" to status)) }
            }
        } else if (status == "share_quota") choice.result.error("share_quota", QUOTA_MESSAGE, null)
        else choice.result.success(mapOf("status" to status))
    }

    /** PendingIntent is explicit and immutable; no chosen-component or private payload is recorded. */
    class SelectionReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val uri = intent.data ?: return
            if (uri.scheme != "vnote-share-choice") return
            choices[uri.schemeSpecificPart]?.invoke()
        }
    }

    companion object {
        private const val ERROR_MESSAGE = "Shared content could not be completed safely."
        private const val QUOTA_MESSAGE = "Share storage is full. Clean up finished outgoing shares or settle inbox items and history. For a prepared notebook or resource export, use Save As instead."
        private val choices = ConcurrentHashMap<String, () -> Unit>()
        private val TARGET_KEYS = setOf("notebookId", "parentId", "notebookRelative", "folderName")
        private val ARGUMENTS = mapOf(
            "list" to emptySet(), "activate" to emptySet(), "getLocale" to emptySet(), "forgetHistory" to emptySet(),
            "cleanupExports" to emptySet(),
            "setLocale" to setOf("locale"), "claim" to setOf("id", "operationId", "target"),
            "stage" to setOf("id", "operationId"), "consume" to setOf("id", "operationId", "cohortId"),
            "discard" to setOf("id"), "anotherCopy" to setOf("id"), "dismissDuplicate" to setOf("id"),
            "export" to setOf("id"), "shareExport" to setOf("operationId", "scope", "path", "suggestedName"))
        private val METHODS = ARGUMENTS.keys
        private var nativeLoaded = false
        private fun arguments(call: MethodCall): Map<*, *> {
            val expected = ARGUMENTS.getValue(call.method)
            val args = call.arguments as? Map<*, *> ?: if (call.arguments == null && expected.isEmpty()) emptyMap<Any, Any>()
                else throw ShareFailure("invalid_request")
            if (args.keys != expected) throw ShareFailure("invalid_request")
            return args
        }
        private fun text(args: Map<*, *>, key: String) = args[key] as? String ?: throw ShareFailure("invalid_request")
        @Synchronized private fun loadNative() {
            if (nativeLoaded) return
            try { System.loadLibrary("vnote_host"); nativeLoaded = true }
            catch (_: LinkageError) { throw ShareFailure("native_unavailable") }
        }
        private fun activate(support: String, inbox: String): Int {
            loadNative()
            return try { nativeActivate(support, inbox) } catch (_: LinkageError) { throw ShareFailure("native_unavailable") }
        }
        private fun prove(support: String, claim: String, disposition: String): Int {
            loadNative()
            return try { nativeProve(support, claim, disposition) } catch (_: LinkageError) { throw ShareFailure("native_unavailable") }
        }
        private fun checkExport(support: String, requiredBytes: Long): Int {
            loadNative()
            return try { nativeCheckExport(support, requiredBytes) } catch (_: LinkageError) { throw ShareFailure("native_unavailable") }
        }
        @JvmStatic private external fun nativeActivate(supportRoot: String, inboxRoot: String): Int
        @JvmStatic private external fun nativeProve(supportRoot: String, claimJson: String, disposition: String): Int
        @JvmStatic private external fun nativeCheckExport(supportRoot: String, requiredBytes: Long): Int
    }
}
