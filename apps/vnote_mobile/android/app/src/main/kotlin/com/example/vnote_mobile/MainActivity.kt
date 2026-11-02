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
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.TypedValue
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
import java.io.FileOutputStream
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.nio.charset.CodingErrorAction
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(DocumentTransferPlugin::class.java)) {
            flutterEngine.plugins.add(DocumentTransferPlugin())
        }
    }
}

/** Transfers immutable exports and private import copies, never provider-backed notebooks. */
private class DocumentTransferPlugin : FlutterPlugin, ActivityAware,
    PluginRegistry.ActivityResultListener, MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor()
    private val copyBuffer = ByteArray(256 * 1024)
    private var context: Context? = null
    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var active: ExportOperation? = null
    private var importing: ImportOperation? = null
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
        channel = MethodChannel(binding.binaryMessenger, "vnote.mobile/document_transfer")
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        engineAttached = false
        channel?.setMethodCallHandler(null)
        channel = null
        active?.let { cancelOperation(it) }
        importing?.let { cancelImport(it) }
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
        // Export retains its picker; import grants/readers never survive detachment.
        importing?.let { cancelImport(it) }
        detachActivity()
    }

    override fun onDetachedFromActivity() {
        active?.let { cancelOperation(it) }
        importing?.let { cancelImport(it) }
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
            "pickImport" -> pickImport(call, result)
            "cancelImport" -> {
                val id = (call.arguments as? Map<*, *>)?.get("operationId") as? String
                if (id == null || !validId(id)) {
                    result.error("invalid_request", "Invalid import request.", null)
                    return
                }
                importing?.takeIf { it.id == id }?.let { cancelImport(it) }
                result.success(null)
            }
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
        if (active != null || importing != null) {
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
        importing?.let { operation ->
            if (requestCode == operation.requestCode) {
                return importActivityResult(operation, resultCode, data)
            }
        }
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
        try {
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
        } finally {
            Os.close(descriptor)
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

    private class ImportOperation(
        val id: String,
        val kind: String,
        val root: File,
        val transaction: File,
        val resolver: ContentResolver,
        val requestCode: Int,
        var result: MethodChannel.Result?,
    ) {
        val cancelled = AtomicBoolean(false)
        val signal = CancellationSignal()
        var copying = false // Main thread only.
        var source: ParcelFileDescriptor? = null // Guarded by this operation.
        var sourceName: String? = null // Worker writes; main reads after settlement.
        var bytes = 0L
        var entries = 0
    }

    private data class ProviderEntry(
        val id: String, val name: String, val directory: Boolean, val size: Long?,
    )

    private fun pickImport(call: MethodCall, result: MethodChannel.Result) {
        val app = context
        val activity = activityBinding?.activity
        if (!engineAttached || app == null || activity == null || activity.isFinishing ||
            activity.isDestroyed || nextRequestCode > 0x7FFF
        ) {
            replyImport(result, "unavailable")
            return
        }
        val args = call.arguments as? Map<*, *>
        val id = args?.get("operationId") as? String
        val kind = args?.get("kind") as? String
        if (active != null || importing != null || args?.size != 2 || id == null ||
            !validId(id) || kind == null || (kind != "zip" && kind != "folder")
        ) {
            replyImport(result, "failed")
            return
        }
        val root: File
        val transaction: File
        try {
            root = prepareStorage(app)
            transaction = validateImportRequest(root, id, kind)
        } catch (_: Exception) {
            replyImport(result, "failed")
            return
        }
        val operation = ImportOperation(id, kind, root, transaction, app.contentResolver,
            nextRequestCode++, result)
        importing = operation
        val intent = if (kind == "zip") {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/x-zip-compressed"))
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        }
        // Request only the temporary read lease. Never persist provider grants.
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        try {
            activity.startActivityForResult(intent, operation.requestCode)
        } catch (_: Exception) {
            finishImport(operation, "unavailable")
        }
    }

    private fun importActivityResult(operation: ImportOperation, code: Int, data: Intent?): Boolean {
        if (operation.copying) return false
        if (code != Activity.RESULT_OK) {
            finishImport(operation, "cancelled")
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != ContentResolver.SCHEME_CONTENT) {
            finishImport(operation, "failed")
            return true
        }
        operation.copying = true
        try {
            worker.execute {
                var status = "ready"
                try {
                    copyImport(operation, uri)
                } catch (_: Exception) {
                    status = if (operation.cancelled.get()) "cancelled" else "failed"
                }
                // Provider cursors, source descriptors and private outputs have closed.
                // The URI is not returned, persisted or retained by the operation.
                main.post { finishImport(operation, status) }
            }
        } catch (_: Exception) {
            operation.copying = false
            finishImport(operation, "failed")
        }
        return true
    }

    private fun validateImportRequest(root: File, id: String, kind: String): File {
        requireDirectory(root)
        val imports = File(root, "imports")
        val transaction = File(imports, id)
        requireDirectory(imports)
        requireDirectory(transaction)
        val marker = File(transaction, "request.json")
        val before = Os.lstat(marker.path)
        if (!OsConstants.S_ISREG(before.st_mode) || before.st_nlink != 1L ||
            before.st_size <= 0 || before.st_size > 16384
        ) throw IOException("Invalid import request")
        val descriptor = Os.open(marker.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or
            OsConstants.O_CLOEXEC, 0)
        try {
            FileInputStream(descriptor).use { input ->
                requireSameFile(before, Os.fstat(descriptor))
                val bytes = ByteArray(before.st_size.toInt())
                var offset = 0
                while (offset < bytes.size) {
                    val count = input.read(bytes, offset, bytes.size - offset)
                    if (count <= 0) throw IOException("Invalid import request")
                    offset += count
                }
                if (input.read() != -1) throw IOException("Invalid import request")
                requireSameFile(before, Os.fstat(descriptor))
                requireSameFile(before, Os.lstat(marker.path))
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
                val request = JSONObject(text)
                if (request.length() != 3 || request.opt("version") != 1 ||
                    request.opt("id") != id || request.opt("kind") != kind
                ) throw IOException("Invalid import request")
            }
        } finally {
            Os.close(descriptor)
        }
        return transaction
    }

    private fun copyImport(operation: ImportOperation, uri: Uri) {
        checkImportCancelled(operation)
        validateImportRequest(operation.root, operation.id, operation.kind)
        if (operation.kind == "zip") {
            var name: String? = null
            var size: Long? = null
            operation.resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null, null, null, operation.signal)?.use { cursor ->
                if (!cursor.moveToFirst()) throw IOException("Import source unavailable")
                name = cursor.getString(0)
                if (!cursor.isNull(1)) size = cursor.getLong(1)
                if (cursor.moveToNext()) throw IOException("Invalid import source")
            } ?: throw IOException("Import source unavailable")
            operation.sourceName = checkedSourceName(name)
            reserveImportSpace(operation, size, MAX_INPUT_BYTES)
            copyProviderFile(operation, uri, File(operation.transaction, "input.zip"), size, MAX_INPUT_BYTES)
            if (operation.bytes == 0L) throw IOException("Empty import")
            operation.entries = 1
        } else {
            val rootId = DocumentsContract.getTreeDocumentId(uri)
            checkDocumentId(rootId)
            val source = DocumentsContract.buildDocumentUriUsingTree(uri, rootId)
            val rootEntry = queryDocument(operation, source)
            if (!rootEntry.directory || rootEntry.id != rootId) throw IOException("Invalid import folder")
            operation.sourceName = checkedSourceName(rootEntry.name)
            // Providers do not declare a trustworthy aggregate tree size.
            reserveImportSpace(operation, null, MAX_TREE_BYTES)
            val unpacked = File(operation.transaction, "unpacked")
            Os.mkdir(unpacked.path, 448)
            requireDirectory(unpacked)
            exclusiveOutput(File(operation.transaction, "accepted.jsonl")) { stream ->
                val inventory = BufferedWriter(OutputStreamWriter(stream, Charsets.UTF_8))
                val visited = HashSet<String>()
                visited.add(rootId)
                copyProviderDirectory(operation, uri, rootId, unpacked, "", 0, visited, inventory)
                checkImportCancelled(operation)
                inventory.flush()
                stream.fd.sync()
            }
        }
        checkImportCancelled(operation)
    }

    private fun queryDocument(operation: ImportOperation, uri: Uri): ProviderEntry {
        operation.resolver.query(uri, documentColumns(), null, null, null, operation.signal)?.use { cursor ->
            if (!cursor.moveToFirst()) throw IOException("Import source unavailable")
            val entry = providerEntry(cursor)
            if (cursor.moveToNext()) throw IOException("Invalid import source")
            return entry
        }
        throw IOException("Import source unavailable")
    }

    private fun documentColumns() = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_FLAGS)

    private fun providerEntry(cursor: android.database.Cursor): ProviderEntry {
        val id = cursor.getString(0) ?: throw IOException("Invalid provider entry")
        checkDocumentId(id)
        val name = cursor.getString(1) ?: throw IOException("Invalid provider entry")
        val mime = cursor.getString(2) ?: throw IOException("Invalid provider entry")
        if (cursor.getLong(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT.toLong() != 0L ||
            mime == "inode/symlink"
        ) throw IOException("Unsupported provider entry")
        return ProviderEntry(id, name, mime == DocumentsContract.Document.MIME_TYPE_DIR,
            if (cursor.isNull(3)) null else cursor.getLong(3))
    }

    private fun copyProviderDirectory(operation: ImportOperation, tree: Uri, id: String,
        destination: File, prefix: String, depth: Int, visited: MutableSet<String>, inventory: BufferedWriter
    ) {
        checkImportCancelled(operation)
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
        operation.resolver.query(children, documentColumns(), null, null, null, operation.signal)?.use { cursor ->
            while (cursor.moveToNext()) {
                checkImportCancelled(operation)
                if (operation.entries >= MAX_ENTRIES || depth >= 32) throw IOException("Import limit exceeded")
                val entry = providerEntry(cursor)
                if (!visited.add(entry.id)) throw IOException("Repeated provider document")
                val relative = if (prefix.isEmpty()) entry.name else "$prefix/${entry.name}"
                validateImportName(entry.name, relative)
                operation.entries++
                val output = File(destination, entry.name)
                if (entry.directory) {
                    Os.mkdir(output.path, 448) // Exclusive: never merge pre-existing directories.
                    requireDirectory(output)
                } else {
                    val source = DocumentsContract.buildDocumentUriUsingTree(tree, entry.id)
                    copyProviderFile(operation, source, output, entry.size, MAX_FILE_BYTES)
                }
                if (operation.transaction.usableSpace < SPACE_HEADROOM + 16384) {
                    throw IOException("Import storage unavailable")
                }
                inventory.write(JSONObject().put("path", relative)
                    .put("type", if (entry.directory) "directory" else "file").toString())
                inventory.newLine()
                if (entry.directory) {
                    copyProviderDirectory(operation, tree, entry.id, output, relative, depth + 1, visited, inventory)
                }
            }
        } ?: throw IOException("Import folder unavailable")
    }

    private inline fun exclusiveOutput(file: File, write: (FileOutputStream) -> Unit) {
        val descriptor = Os.open(file.path,
            OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or
                OsConstants.O_CLOEXEC, 384) // 0600
        try {
            // FileOutputStream(FileDescriptor) borrows, rather than owns, this fd.
            FileOutputStream(descriptor).use(write)
        } finally {
            Os.close(descriptor)
        }
    }

    private fun copyProviderFile(operation: ImportOperation, uri: Uri, outputFile: File,
        declaredSize: Long?, maximum: Long
    ) {
        if (declaredSize != null && (declaredSize < 0 || declaredSize > maximum)) {
            throw IOException("Import limit exceeded")
        }
        checkImportCancelled(operation)
        val source = operation.resolver.openFileDescriptor(uri, "r", operation.signal)
            ?: throw IOException("Import source unavailable")
        try {
            synchronized(operation) {
                operation.source = source
                if (operation.cancelled.get()) source.close()
            }
            ParcelFileDescriptor.AutoCloseInputStream(source).use { input ->
                exclusiveOutput(outputFile) { output ->
                    var copied = 0L
                    while (true) {
                        checkImportCancelled(operation)
                        val count = input.read(copyBuffer)
                        if (count < 0) break
                        copied += count
                        operation.bytes += count
                        if (copied > maximum || operation.bytes > MAX_TREE_BYTES ||
                            (declaredSize != null && copied > declaredSize) ||
                            operation.transaction.usableSpace < SPACE_HEADROOM + count
                        ) throw IOException("Import limit exceeded")
                        output.write(copyBuffer, 0, count)
                    }
                    if (declaredSize != null && copied != declaredSize) throw IOException("Import source changed")
                    checkImportCancelled(operation)
                    if (source.canDetectErrors()) source.checkError()
                    output.flush()
                    output.fd.sync()
                }
            }
        } finally {
            synchronized(operation) { operation.source = null }
            source.close()
        }
    }

    private fun reserveImportSpace(operation: ImportOperation, declared: Long?, maximum: Long) {
        if (declared != null && (declared < 0 || declared > maximum)) throw IOException("Import limit exceeded")
        if (operation.transaction.usableSpace < (declared ?: maximum) + SPACE_HEADROOM) {
            throw IOException("Import storage unavailable")
        }
    }

    private fun checkedSourceName(name: String?): String {
        if (name == null || name.isEmpty() || utf8Size(name) > 1024 || name.any { it < ' ' || it == '\u007f' }) {
            throw IOException("Invalid import name")
        }
        return name
    }

    private fun utf8Size(value: String): Int {
        var bytes = 0
        var index = 0
        while (index < value.length) {
            val character = value[index++]
            bytes += when {
                character < '\u0080' -> 1
                character < '\u0800' -> 2
                Character.isHighSurrogate(character) -> {
                    if (index >= value.length || !Character.isLowSurrogate(value[index++])) {
                        throw IOException("Invalid provider text")
                    }
                    4
                }
                Character.isLowSurrogate(character) -> throw IOException("Invalid provider text")
                else -> 3
            }
        }
        return bytes
    }

    private fun checkDocumentId(id: String) {
        if (id.isEmpty() || utf8Size(id) > 16384) throw IOException("Invalid provider document")
    }

    private fun validateImportName(name: String, relative: String) {
        if (name.isEmpty() || name == "." || name == ".." || utf8Size(name) > 255 ||
            utf8Size(relative) > 1024 || name.endsWith('.') || name.endsWith(' ') ||
            name.any { it < ' ' || it in '\u007f'..'\u009f' || it in "/\\:*?\"<>|" } ||
            RESERVED.matches(name.substringBefore('.'))
        ) throw IOException("Invalid import path")
    }

    private fun checkImportCancelled(operation: ImportOperation) {
        if (operation.cancelled.get()) throw IOException("Import cancelled")
    }

    private fun cancelImport(operation: ImportOperation) {
        if (importing !== operation) return
        operation.cancelled.set(true)
        try { operation.signal.cancel() } catch (_: Exception) { }
        synchronized(operation) {
            try { operation.source?.close() } catch (_: Exception) { }
        }
        if (!operation.copying) {
            try { activityBinding?.activity?.finishActivity(operation.requestCode) } catch (_: Exception) { }
            finishImport(operation, "cancelled")
        }
    }

    private fun finishImport(operation: ImportOperation, status: String) {
        if (importing !== operation) return
        importing = null
        val result = operation.result
        operation.result = null
        val terminal = if (operation.cancelled.get()) "cancelled" else status
        if (engineAttached && result != null) {
            replyImport(result, terminal, if (terminal == "ready") operation.sourceName else null,
                if (terminal == "ready") operation.bytes else 0,
                if (terminal == "ready") operation.entries else 0)
        }
    }

    private fun replyImport(result: MethodChannel.Result, status: String, name: String? = null,
        bytes: Long = 0, entries: Int = 0
    ) {
        result.success(mapOf("status" to status, "sourceName" to name, "bytes" to bytes, "entries" to entries))
    }

    private fun prepareStorage(app: Context): File {
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0) {
            throw IOException("Backup protection unavailable")
        }
        // ApplicationInfo's rule resource fields are hidden Android APIs. Inspect
        // the installed binary manifest instead of using reflection on them.
        // WebView adds another APK to this AssetManager. Select our base APK,
        // not whichever AndroidManifest.xml wins an unqualified asset lookup.
        val rules = TypedValue()
        app.resources.getValue(R.xml.backup_rules, rules, true)
        if (rules.assetCookie <= 0) throw IOException("Backup protection unavailable")
        val manifest = app.assets.openXmlResourceParser(rules.assetCookie, "AndroidManifest.xml")
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
        for (name in arrayOf("core", "notebooks", "exports", "imports")) ensureDirectory(File(root, name))
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
        private const val MAX_INPUT_BYTES = 1024L * 1024 * 1024
        private const val MAX_TREE_BYTES = 2L * 1024 * 1024 * 1024
        private const val MAX_FILE_BYTES = 256L * 1024 * 1024
        private const val SPACE_HEADROOM = 64L * 1024 * 1024
        private const val MAX_ENTRIES = 100000
        private val RESERVED = Regex("(?i)(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])")
        private val ID = Regex("[0-9a-f]{32}")
        private val NAME = Regex("[A-Za-z0-9][A-Za-z0-9._-]*\\.zip")
        private fun validId(id: String) = ID.matches(id)
        private fun validName(name: String) = name.length <= 100 && !name.contains("..") && NAME.matches(name)
    }
}
