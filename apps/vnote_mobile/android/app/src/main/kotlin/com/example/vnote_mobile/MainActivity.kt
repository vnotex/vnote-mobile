package com.example.vnote_mobile

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.xmlpull.v1.XmlPullParser

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(DocumentExportPlugin::class.java)) {
            flutterEngine.plugins.add(DocumentExportPlugin())
        }
    }
}

/** Owns only a prepared ZIP lease; never opens a notebook or retains a URI grant. */
private class DocumentExportPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val copyBuffer = ByteArray(256 * 1024)
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var active: ExportOperation? = null
    private var engineAttached = false
    // Never reuse a request code in this engine: a dismissed picker's late result
    // cannot be mistaken for a retry of the same prepared artifact.
    private var nextRequestCode = 0x6E00

    private class ExportOperation(
        val id: String,
        val root: File,
        val source: File,
        val resolver: ContentResolver,
        val requestCode: Int,
        var result: MethodChannel.Result?,
    ) {
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        var copying = false // Main thread only.
        var externalMayBeIncomplete = false // Main thread only.
        var destination: ParcelFileDescriptor? = null // Guarded by this operation.
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        engineAttached = true
        channel = MethodChannel(binding.binaryMessenger, "vnote.mobile/document_export")
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engineAttached = false
        channel?.setMethodCallHandler(null)
        channel = null
        active?.let { cancelOperation(it) }
        detachActivity()
        context = null
        // Do not discard queued/running work. Its finally/close path owns the lease.
        worker.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // The plugin, request, worker and result survive a configuration change.
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        active?.let { cancelOperation(it) }
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareStorage" -> {
                try {
                    prepareStorage(requireNotNull(context))
                    result.success(null)
                } catch (_: Exception) {
                    result.error("storage_unavailable", "Private storage protection is unavailable.", null)
                }
            }
            "saveExport" -> save(call, result)
            "cancelExport" -> {
                val id = (call.arguments as? Map<*, *>)?.get("operationId") as? String
                if (id == null || !validId(id)) {
                    result.error("invalid_request", "Invalid export request.", null)
                    return
                }
                active?.takeIf { it.id == id }?.let { cancelOperation(it) }
                // This is an acknowledgement only. saveExport settles after IO closes.
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun save(call: MethodCall, result: MethodChannel.Result) {
        val app = context
        val activity = activityBinding?.activity
        if (!engineAttached || app == null || activity == null || activity.isFinishing ||
            activity.isDestroyed || nextRequestCode > 0x7FFF
        ) {
            reply(result, "unavailable", false)
            return
        }
        if (active != null) {
            reply(result, "failed", false)
            return
        }
        val args = call.arguments as? Map<*, *>
        val id = args?.get("operationId") as? String
        val path = args?.get("path") as? String
        val name = args?.get("suggestedName") as? String
        if (id == null || path == null || name == null || !validId(id) || !validName(name)) {
            reply(result, "failed", false)
            return
        }
        val root: File
        val source: File
        try {
            root = prepareStorage(app)
            source = validateSource(root, id, path)
        } catch (_: Exception) {
            reply(result, "failed", false)
            return
        }
        val operation = ExportOperation(id, root, source, app.contentResolver, nextRequestCode++, result)
        active = operation
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_TITLE, name)
        }
        try {
            activity.startActivityForResult(intent, operation.requestCode)
        } catch (_: Exception) {
            finish(operation, "unavailable")
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        val operation = active ?: return false
        if (requestCode != operation.requestCode || operation.copying) return false
        if (resultCode != Activity.RESULT_OK) {
            finish(operation, "cancelled")
            return true
        }
        // The picker may already have created a zero-length destination.
        operation.externalMayBeIncomplete = true
        val uri = data?.data
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) {
            finish(operation, "failed")
            return true
        }
        operation.copying = true
        try {
            worker.execute {
                var status = "saved"
                try {
                    copy(operation, uri)
                } catch (_: Exception) {
                    status = if (operation.cancelled.get()) "cancelled" else "failed"
                }
                // Only this post, after every source/output descriptor closes, can
                // release the Dart artifact. Cancellation never replies early here.
                main.post { finish(operation, status) }
            }
        } catch (_: Exception) {
            operation.copying = false
            finish(operation, "failed")
        }
        return true
    }

    private fun copy(operation: ExportOperation, uri: Uri) {
        checkCancelled(operation)
        val source = validateSource(operation.root, operation.id, operation.source.path)
        val before = Os.lstat(source.path)
        val descriptor = Os.open(source.path, OsConstants.O_RDONLY or OsConstants.O_CLOEXEC or
            OsConstants.O_NOFOLLOW, 0)
        FileInputStream(descriptor).use { input ->
            val opened = Os.fstat(descriptor)
            requireSameFile(before, opened)
            validateSource(operation.root, operation.id, source.path)
            checkCancelled(operation)
            val destination = operation.resolver.openFileDescriptor(uri, "wt", operation.signal)
                ?: throw IOException("Export destination unavailable")
            try {
                synchronized(operation) {
                    operation.destination = destination
                    if (operation.cancelled.get()) destination.close()
                }
                destination.use {
                    ParcelFileDescriptor.AutoCloseOutputStream(destination).use { output ->
                        var copied = 0L
                        while (true) {
                            checkCancelled(operation)
                            val count = input.read(copyBuffer)
                            if (count < 0) break
                            copied += count
                            if (copied > opened.st_size || copied > MAX_ARCHIVE_BYTES) {
                                throw IOException("Export source changed")
                            }
                            output.write(copyBuffer, 0, count)
                        }
                        if (copied != opened.st_size) throw IOException("Export source changed")
                        requireSameFile(opened, Os.fstat(descriptor))
                        requireSameFile(opened, Os.lstat(source.path))
                        checkCancelled(operation)
                        output.flush()
                        if (destination.canDetectErrors()) destination.checkError()
                    }
                }
            } finally {
                synchronized(operation) { operation.destination = null }
                destination.close()
            }
        }
        checkCancelled(operation)
    }

    private fun cancelOperation(operation: ExportOperation) {
        if (active !== operation) return
        operation.cancelled.set(true)
        try {
            operation.signal.cancel()
        } catch (_: Exception) {
            // A provider cancellation exception must not bypass worker settlement.
        }
        synchronized(operation) {
            try {
                operation.destination?.close()
            } catch (_: Exception) {
                // The worker still closes its streams and reports non-success.
            }
        }
        if (!operation.copying) {
            try {
                activityBinding?.activity?.finishActivity(operation.requestCode)
            } catch (_: Exception) {
                // No source reader exists before the worker starts. Late picker
                // callbacks are rejected by the non-reused request code.
            }
            finish(operation, "cancelled")
        }
    }

    private fun finish(operation: ExportOperation, status: String) {
        if (active !== operation) return
        active = null
        val result = operation.result
        operation.result = null
        val terminal = if (operation.cancelled.get()) "cancelled" else status
        if (engineAttached && result != null) {
            reply(result, terminal, terminal != "saved" && operation.externalMayBeIncomplete)
        }
    }

    private fun checkCancelled(operation: ExportOperation) {
        if (operation.cancelled.get()) throw IOException("Export cancelled")
    }

    private fun prepareStorage(app: Context): File {
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0) {
            throw IOException("Backup protection unavailable")
        }
        // ApplicationInfo's rule resource fields are hidden Android APIs. Inspect
        // the installed binary manifest instead of using reflection on them.
        val manifest = app.assets.openXmlResourceParser("AndroidManifest.xml")
        var verified = false
        try {
            while (manifest.next() != XmlPullParser.END_DOCUMENT) {
                if (manifest.eventType == XmlPullParser.START_TAG && manifest.name == "application") {
                    val ns = "http://schemas.android.com/apk/res/android"
                    verified = !manifest.getAttributeBooleanValue(ns, "allowBackup", true) &&
                        manifest.getAttributeResourceValue(ns, "fullBackupContent", 0) == R.xml.backup_rules &&
                        manifest.getAttributeResourceValue(ns, "dataExtractionRules", 0) == R.xml.data_extraction_rules
                    break
                }
            }
        } finally {
            manifest.close()
        }
        if (!verified) throw IOException("Backup protection unavailable")
        // Path-provider's Application Support namespace on Android is filesDir.
        // OS-managed ancestors may have aliases; none below this trusted anchor may.
        val data = File(app.applicationInfo.dataDir).canonicalFile
        val root = File(data, "files")
        if (app.filesDir.canonicalFile != root) throw IOException("Invalid support namespace")
        ensureDirectory(root)
        for (name in arrayOf("core", "notebooks", "exports")) ensureDirectory(File(root, name))
        return root
    }

    private fun ensureDirectory(directory: File) {
        try {
            Os.lstat(directory.path)
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.ENOENT) throw error
            Os.mkdir(directory.path, 448) // 0700, only these fixed namespaces.
        }
        requireDirectory(directory)
    }

    private fun requireDirectory(directory: File) {
        if (directory.canonicalFile != directory || !OsConstants.S_ISDIR(Os.lstat(directory.path).st_mode)) {
            throw IOException("Invalid private directory")
        }
    }

    private fun validateSource(root: File, id: String, path: String): File {
        if (path.length > 16384 || path.indexOf('\u0000') >= 0) throw IOException("Invalid export source")
        requireDirectory(root)
        val exports = File(root, "exports")
        val transaction = File(exports, id)
        requireDirectory(exports)
        requireDirectory(transaction)
        val source = File(transaction, "notebook.zip")
        if (path != source.path || source.canonicalFile != source) throw IOException("Invalid export source")
        requireRegularFile(Os.lstat(source.path))
        return source
    }

    private fun requireRegularFile(stat: StructStat) {
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_nlink != 1L ||
            stat.st_size <= 0L || stat.st_size > MAX_ARCHIVE_BYTES
        ) throw IOException("Invalid export source")
    }

    private fun requireSameFile(before: StructStat, after: StructStat) {
        requireRegularFile(after)
        if (before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
            before.st_size != after.st_size || before.st_mtime != after.st_mtime ||
            before.st_ctime != after.st_ctime
        ) throw IOException("Export source changed")
    }

    private fun reply(result: MethodChannel.Result, status: String, incomplete: Boolean) {
        result.success(mapOf("status" to status, "externalMayBeIncomplete" to incomplete))
    }

    companion object {
        private const val MAX_ARCHIVE_BYTES = 4L * 1024 * 1024 * 1024
        private val ID = Regex("[0-9a-f]{32}")
        private val NAME = Regex("[A-Za-z0-9][A-Za-z0-9._-]*\\.zip")
        private fun validId(id: String) = ID.matches(id)
        private fun validName(name: String) = name.length <= 100 && !name.contains("..") && NAME.matches(name)
    }
}
