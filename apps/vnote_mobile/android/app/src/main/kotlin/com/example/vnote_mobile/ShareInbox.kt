package com.example.vnote_mobile

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.icu.lang.UCharacter
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.OpenableColumns
import android.provider.Settings
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import android.util.TypedValue
import org.json.JSONArray
import org.json.JSONObject
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

internal class ShareFailure(val code: String) : IOException(code)

/** SDK-only capture/ledger. Nothing here loads Flutter or the notebook core. */
internal class ShareInbox(private val app: Context) {
    val support: File
    val root: File
    private val payloads: File
    private val shares: File

    private fun shareDirectory(lease: JSONObject) = File(
        if (lease.getString("storage") == "core") File(support, "outgoing-shares") else shares, lease.getString("id"))

    private fun reservationDirectory(reservation: JSONObject) = File(when (reservation.getString("kind")) {
        "share" -> shares
        "shareExport" -> File(support, "outgoing-shares")
        else -> payloads
    }, reservation.getString("id"))

    init {
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_ALLOW_BACKUP != 0) fail("storage_unavailable")
        val rules = TypedValue()
        app.resources.getValue(R.xml.backup_rules, rules, true)
        if (rules.assetCookie <= 0) fail("storage_unavailable")
        var protected = false
        app.assets.openXmlResourceParser(rules.assetCookie, "AndroidManifest.xml").use { manifest ->
            while (manifest.next() != XmlPullParser.END_DOCUMENT) {
                if (manifest.eventType == XmlPullParser.START_TAG && manifest.name == "application") {
                    val ns = "http://schemas.android.com/apk/res/android"
                    protected = !manifest.getAttributeBooleanValue(ns, "allowBackup", true) &&
                        manifest.getAttributeResourceValue(ns, "fullBackupContent", 0) == R.xml.backup_rules &&
                        manifest.getAttributeResourceValue(ns, "dataExtractionRules", 0) == R.xml.data_extraction_rules
                    break
                }
            }
        }
        if (!protected) fail("storage_unavailable")
        support = File(File(app.applicationInfo.dataDir).canonicalFile, "files")
        if (app.filesDir.canonicalFile != support) fail("storage_unavailable")
        ensureDirectory(support)
        // Android may create filesDir as 0771. Tighten this owned directory in
        // place before the native private-root proof; never replace user data.
        val supportDescriptor = Os.open(support.path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try {
            val opened = Os.fstat(supportDescriptor)
            if (!OsConstants.S_ISDIR(opened.st_mode) || opened.st_uid != Process.myUid()) fail("storage_corrupt")
            Os.fchmod(supportDescriptor, 448)
            if (Os.fstat(supportDescriptor).st_mode and 511 != 448) fail("storage_unavailable")
        } finally { Os.close(supportDescriptor) }
        requireDirectory(support)
        root = File(support, "inbox")
        ensureDirectory(root)
        payloads = File(root, "payloads").also(::ensureDirectory)
        shares = File(root, "shares").also(::ensureDirectory)
    }

    private data class Source(val uri: Uri, val name: String, val mime: String, val size: Long?)
    private class Writer(val id: String, val directory: File, val channel: FileChannel, val lease: FileLock) {
        fun close() = processLock.withLock {
            try { lease.release() } finally { channel.close(); liveWriters.remove(id) }
        }
    }
    data class CaptureResult(val duplicate: Boolean)
    data class OutgoingFile(val uri: Uri, val mime: String, val name: String)
    data class Outgoing(val id: String, val files: List<OutgoingFile>)

    fun <T> locked(action: () -> T): T {
        if (!processLock.tryLock()) fail("inbox_busy")
        try {
            val lockFile = File(root, "ledger.lock")
            openLock(lockFile).use { channel ->
                val lease = try { channel.tryLock() } catch (_: OverlappingFileLockException) { null }
                if (lease == null) fail("inbox_busy")
                lease.use { return action() }
            }
        } finally { processLock.unlock() }
    }

    fun activate(native: (String, String) -> Int) = locked {
        loadLedger()
        if (native(support.path, root.path) != 0 || !activated()) fail("activation_unavailable")
    }

    fun locale(): String = locked {
        val file = File(root, "locale.json")
        if (!exists(file)) "system" else readJson(file, 1024).let {
            keys(it, setOf("version", "locale"))
            if (it.opt("version") != 1 || it.optString("locale") !in LOCALES) fail("storage_corrupt")
            it.getString("locale")
        }
    }

    fun setLocale(locale: String) = locked {
        if (locale !in LOCALES) fail("invalid_request")
        atomicJson(File(root, "locale.json"), JSONObject().put("version", 1).put("locale", locale))
    }

    fun list(): Map<String, Any> = locked {
        val ledger = loadLedger()
        cleanup(ledger)
        val records = ledger.getJSONArray("records")
        mapOf("available" to true, "records" to (0 until records.length()).map {
            val record = records.getJSONObject(it)
            retained(record)?.let { payload -> validatePayload(record, payload, false) }
            publicRecord(record)
        })
    }

    fun claim(id: String, operationId: String, target: JSONObject): Map<String, Any?> = locked {
        validId(id); validId(operationId); validateTarget(target)
        val ledger = loadLedger()
        val record = record(ledger, id)
        if (record.getString("state") == "importing") {
            if (record.optString("operationId") != operationId || !sameJson(record.getJSONObject("target"), target))
                fail("claim_conflict")
        } else {
            if (record.getString("state") != "ready" || retained(record) == null) fail("invalid_state")
            val records = ledger.getJSONArray("records")
            for (i in 0 until records.length()) {
                if (records.getJSONObject(i).optString("operationId") == operationId) fail("claim_conflict")
            }
            record.put("state", "importing").put("operationId", operationId).put("target", target)
            saveLedger(ledger)
        }
        publicRecord(record)
    }

    fun consume(id: String, operationId: String, cohortId: String, prove: (String, String, String) -> Int) = locked {
        validId(id); validId(operationId); checkedText(cohortId, 127)
        val ledger = loadLedger()
        val record = record(ledger, id)
        if (record.optString("operationId") != operationId) fail("claim_conflict")
        if (record.getString("state") == "consumed") {
            if (record.optString("cohortId") != cohortId) fail("claim_conflict")
            return@locked
        }
        if (record.getString("state") != "importing") fail("invalid_state")
        val claim = proofClaim(record).put("cohortId", cohortId)
        if (prove(support.path, claim.toString(), "consume") != 0) fail("proof_unavailable")
        record.put("state", "consumed").put("cohortId", cohortId)
        releasePayload(ledger, record, "payload")
        saveLedger(ledger) // The tombstone always precedes reclamation.
        cleanup(ledger)
    }

    fun discard(id: String, prove: (String, String, String) -> Int) = locked {
        validId(id)
        val ledger = loadLedger()
        val record = record(ledger, id)
        when (record.getString("state")) {
            "discarded" -> return@locked
            "ready", "failed" -> Unit
            "importing" -> if (prove(support.path, proofClaim(record).toString(), "discard") != 0)
                fail("proof_unavailable")
            else -> fail("invalid_state")
        }
        record.put("state", "discarded")
        releasePayload(ledger, record, "payload")
        releasePayload(ledger, record, "candidate")
        saveLedger(ledger)
        cleanup(ledger)
    }

    fun dismissDuplicate(id: String) = locked {
        val ledger = loadLedger()
        val record = record(ledger, id)
        releasePayload(ledger, record, "candidate")
        saveLedger(ledger)
        cleanup(ledger)
    }

    fun forgetHistory() = locked {
        val ledger = loadLedger()
        val rows = ledger.getJSONArray("records")
        for (i in rows.length() - 1 downTo 0) {
            val row = rows.getJSONObject(i)
            if (row.getString("state") in SETTLED && retained(row) == null) rows.remove(i)
        }
        saveLedger(ledger)
        cleanup(ledger)
    }

    fun cleanupExports() = locked {
        val ledger = loadLedger()
        cleanup(ledger)
        val leases = ledger.getJSONArray("shares")
        for (i in 0 until leases.length()) {
            val lease = leases.getJSONObject(i)
            if (!lease.isNull("chooser") || lease.getJSONArray("readers").length() != 0) fail("readers_active")
        }
        for (i in 0 until leases.length()) leases.getJSONObject(i).put("retiring", true)
        saveLedger(ledger) // Restart can finish only this explicitly confirmed retirement.
        cleanup(ledger)
    }

    fun beginChooser(id: String, nonce: String) = locked {
        validId(id); validId(nonce)
        val ledger = loadLedger()
        val lease = shareLease(ledger, id)
        if (!lease.isNull("chooser") || lease.getBoolean("retiring")) fail("readers_active")
        lease.put("chooser", nonce)
        saveLedger(ledger)
    }

    fun endChooser(id: String, nonce: String) = locked {
        val ledger = loadLedger()
        val lease = shareLease(ledger, id)
        if (lease.optString("chooser") != nonce) fail("lease_unavailable")
        lease.put("chooser", JSONObject.NULL)
        saveLedger(ledger)
    }

    private fun shareLease(ledger: JSONObject, id: String): JSONObject {
        val leases = ledger.getJSONArray("shares")
        for (i in 0 until leases.length()) if (leases.getJSONObject(i).getString("id") == id) return leases.getJSONObject(i)
        fail("lease_unavailable")
    }

    fun capture(intent: Intent, signal: CancellationSignal): CaptureResult {
        if (intent.action != Intent.ACTION_SEND && intent.action != Intent.ACTION_SEND_MULTIPLE) fail("invalid_request")
        locked {
            val ledger = loadLedger()
            cleanup(ledger)
            if (!activated()) fail("activation_required")
        }
        val texts = LinkedHashSet<String>()
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { texts.add(it) }
        val uris = ArrayList<Uri>()
        @Suppress("DEPRECATION")
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.addAll(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { uris.add(it) }
        }
        intent.clipData?.let { clip ->
            if (clip.itemCount > FILE_COUNT) fail("delivery_limit")
            for (i in 0 until clip.itemCount) {
                val item = clip.getItemAt(i)
                item.text?.toString()?.let { texts.add(it) }
                item.uri?.let { uri ->
                    if (uri.scheme == "http" || uri.scheme == "https") texts.add(uri.toString())
                    else if (!uris.contains(uri)) uris.add(uri)
                }
            }
        }
        intent.data?.let { uri ->
            if (uri.scheme == "http" || uri.scheme == "https") texts.add(uri.toString())
            else if (uri.scheme == ContentResolver.SCHEME_CONTENT && !uris.contains(uri)) uris.add(uri)
        }
        if (texts.size > 1) fail("invalid_request") // Never acknowledge one of several different text payloads.
        val textBytes = utf8(texts.firstOrNull() ?: "", TEXT_LIMIT)
        if (uris.size > FILE_COUNT || (uris.isEmpty() && textBytes.isEmpty())) fail("delivery_limit")
        val sources = uris.map { querySource(it, intent.type, signal) }
        checkNames(sources.map { it.name }, textBytes.isNotEmpty())
        val bodyBound = minOf(DELIVERY_LIMIT, sources.sumOf { it.size ?: FILE_LIMIT } + textBytes.size)
        if (sources.sumOf { it.size ?: 0L } + textBytes.size > DELIVERY_LIMIT) fail("delivery_limit")
        val writer = locked { beginWriter(bodyBound + METADATA_RESERVE, "incoming") }
        try {
            val files = JSONArray()
            var total = textBytes.size.toLong()
            if (textBytes.isNotEmpty()) writeBytes(File(writer.directory, "text.txt"), textBytes)
            val directory = File(writer.directory, "files").also(::ensureDirectory)
            for ((index, source) in sources.withIndex()) {
                signal.throwIfCanceled()
                val descriptor = app.contentResolver.openFileDescriptor(source.uri, "r", signal) ?: fail("source_unavailable")
                val copied = descriptor.use {
                    signal.setOnCancelListener { try { descriptor.close() } catch (_: Exception) { } }
                    try {
                        ParcelFileDescriptor.AutoCloseInputStream(it).use { input ->
                            val output = copy(input, File(directory, index.toString()),
                                minOf(source.size ?: FILE_LIMIT, DELIVERY_LIMIT - total), signal)
                            if (source.size != null && output.first != source.size) fail("source_changed")
                            if (it.canDetectErrors()) it.checkError()
                            output
                        }
                    } finally { signal.setOnCancelListener(null) }
                }
                total += copied.first
                files.put(JSONObject().put("name", source.name).put("mime", source.mime)
                    .put("bytes", copied.first).put("sha256", copied.second))
            }
            syncDirectory(directory)
            val fingerprint = fingerprint(textBytes, files)
            val manifest = JSONObject().put("version", 1).put("id", writer.id).put("fingerprint", fingerprint)
                .put("bytes", total).put("textBytes", textBytes.size).put("textSha256", digest(textBytes)).put("files", files)
            atomicJson(File(writer.directory, "manifest.json"), manifest)
            syncDirectory(writer.directory)
            signal.throwIfCanceled()
            return locked {
                val ledger = loadLedger()
                requireReservation(ledger, writer.id)
                val rows = ledger.getJSONArray("records")
                var existing: JSONObject? = null
                for (i in 0 until rows.length()) {
                    val row = rows.getJSONObject(i)
                    if (row.getString("fingerprint") == fingerprint) { existing = row; break }
                }
                if (existing != null) {
                    // A consumed receipt may retain one newly delivered candidate, but it never becomes ready.
                    val retained = retained(existing)
                    if (retained == null) existing.put("candidate", writer.id)
                    else {
                        validatePayload(existing, retained, true)
                        ledger.getJSONArray("garbage").put(writer.id)
                    }
                } else {
                    if (rows.length() >= HISTORY_COUNT) fail("history_full")
                    rows.put(newRecord(manifest, writer.id))
                }
                removeReservation(ledger, writer.id)
                saveLedger(ledger)
                CaptureResult(existing != null)
            }
        } catch (error: Exception) {
            locked { abortWriter(writer.id) }
            throw error
        } finally {
            writer.close()
            locked { cleanup(loadLedger()) }
        }
    }

    fun anotherCopy(id: String): Map<String, Any?> = locked {
        val ledger = loadLedger()
        val original = record(ledger, id)
        val source = retained(original) ?: fail("payload_unavailable")
        validatePayload(original, source, true)
        if (ledger.getJSONArray("records").length() >= HISTORY_COUNT) fail("history_full")
        val writer = beginWriter(original.getLong("bytes") + METADATA_RESERVE, "copy")
        try {
            val sourceDirectory = File(payloads, source)
            val filesDirectory = File(writer.directory, "files").also(::ensureDirectory)
            if (original.getLong("textBytes") > 0) copyVerified(File(sourceDirectory, "text.txt"),
                File(writer.directory, "text.txt"), original.getLong("textBytes"), original.getString("textSha256"))
            val files = original.getJSONArray("files")
            for (i in 0 until files.length()) {
                val file = files.getJSONObject(i)
                copyVerified(File(sourceDirectory, "files/$i"), File(filesDirectory, i.toString()),
                    file.getLong("bytes"), file.getString("sha256"))
            }
            syncDirectory(filesDirectory)
            val manifest = manifestOf(original, writer.id)
            atomicJson(File(writer.directory, "manifest.json"), manifest)
            syncDirectory(writer.directory)
            val current = loadLedger()
            val result = newRecord(manifest, writer.id).put("nonce", writer.id)
            current.getJSONArray("records").put(result)
            removeReservation(current, writer.id)
            saveLedger(current)
            publicRecord(result)
        } catch (error: Exception) {
            abortWriter(writer.id)
            throw error
        } finally {
            writer.close()
            cleanup(loadLedger())
        }
    }

    fun stage(id: String, operationId: String): Map<String, Any> = locked {
        validId(id); validId(operationId)
        val ledger = loadLedger()
        val record = record(ledger, id)
        if (record.getString("state") != "importing" || record.optString("operationId") != operationId) fail("claim_conflict")
        val payload = retained(record) ?: fail("payload_unavailable")
        validatePayload(record, payload, true)
        val cohorts = File(support, "cohorts").also(::requireDirectory)
        val transaction = File(cohorts, operationId).also(::requireDirectory)
        val target = JSONObject(record.getJSONObject("target").toString()).put("version", 1).put("id", operationId)
        val ownership = JSONObject().put("version", 1).put("id", operationId).put("scope", "cohort")
            .put("inboxId", id).put("target", target)
        if (!sameJson(readJson(File(cohorts, "inbox-$operationId.json")), ownership) ||
            !sameJson(readJson(File(transaction, "request.json")), JSONObject().put("version", 2)
                .put("id", operationId).put("scope", "cohort").put("kind", "folder")) ||
            !sameJson(readJson(File(transaction, "target.json")), target)) fail("claim_conflict")
        val allowed = setOf("request.json", "target.json", "unpacked", "accepted.jsonl")
        if (children(transaction).any { it.name !in allowed }) fail("stage_not_receiving")
        val inputs = ArrayList<Triple<String, File, Pair<Long, String>>>()
        val source = File(payloads, payload)
        if (record.getLong("textBytes") > 0) inputs.add(Triple(TEXT_NAME, File(source, "text.txt"),
            record.getLong("textBytes") to record.getString("textSha256")))
        val files = record.getJSONArray("files")
        for (i in 0 until files.length()) {
            val file = files.getJSONObject(i)
            inputs.add(Triple(file.getString("name"), File(source, "files/$i"), file.getLong("bytes") to file.getString("sha256")))
        }
        val inventory = inputs.joinToString("") { JSONObject().put("path", it.first).put("type", "file").toString() + "\n" }
            .toByteArray(Charsets.UTF_8)
        val unpacked = File(transaction, "unpacked")
        val accepted = File(transaction, "accepted.jsonl")
        // Retry only exact prefixes of this immutable claim. No source/prepared/intent or foreign work is erased.
        if (exists(unpacked)) {
            requireDirectory(unpacked)
            for (file in children(unpacked)) {
                val input = inputs.singleOrNull { it.first == file.name } ?: fail("stage_conflict")
                requirePrefix(file, input.second)
            }
        }
        if (exists(accepted)) {
            val previous = readBytes(accepted, inventory.size.toLong())
            if (!previous.contentEquals(inventory.copyOf(previous.size))) fail("stage_conflict")
        }
        if (exists(accepted)) unlink(accepted)
        if (exists(unpacked)) removeTree(unpacked)
        ensureDirectory(unpacked)
        for (input in inputs) copyVerified(input.second, File(unpacked, input.first), input.third.first, input.third.second)
        syncDirectory(unpacked)
        writeBytes(accepted, inventory)
        syncDirectory(transaction)
        mapOf("status" to "captured", "sourceName" to "Shared items", "bytes" to record.getLong("bytes"), "entries" to inputs.size)
    }

    fun export(id: String): Outgoing = locked {
        val ledger = loadLedger()
        val row = record(ledger, id)
        val payload = retained(row) ?: fail("payload_unavailable")
        validatePayload(row, payload, true)
        val source = File(payloads, payload)
        val inputs = ArrayList<ExportInput>()
        if (row.getLong("textBytes") > 0) inputs.add(ExportInput(TEXT_NAME, "text/plain", File(source, "text.txt"),
            row.getLong("textBytes"), row.getString("textSha256")))
        val files = row.getJSONArray("files")
        for (i in 0 until files.length()) {
            val file = files.getJSONObject(i)
            inputs.add(ExportInput(file.getString("name"), file.getString("mime"), File(source, "files/$i"),
                file.getLong("bytes"), file.getString("sha256")))
        }
        createShare("inbox:$id:$payload", inputs)
    }

    fun shareExport(operationId: String, scope: String, path: String, suggestedName: String,
        checkExport: (String, Long) -> Int): Outgoing = locked {
        validId(operationId); validName(suggestedName)
        if (scope != "notebook" && scope != "resource") fail("invalid_request")
        val group = File(support, if (scope == "notebook") "exports" else "resources").also(::requireDirectory)
        val transaction = File(group, operationId).also(::requireDirectory)
        val request = readJson(File(transaction, "request.json"), 65536)
        val ready = readJson(File(transaction, "ready.json"), 65536)
        val source: File
        val mime: String
        if (scope == "resource") {
            keys(request, setOf("version", "id", "scope", "kind"))
            keys(ready, setOf("version", "id", "scope", "name", "bytes", "sha256"))
            if (request.opt("version") != 2 || request.opt("id") != operationId || request.opt("scope") != scope ||
                request.optString("kind") !in setOf("file", "image") || ready.opt("version") != 1 ||
                ready.opt("id") != operationId || ready.opt("scope") != scope || ready.opt("name") != suggestedName)
                fail("invalid_artifact")
            source = File(File(transaction, "output").also(::requireDirectory), suggestedName)
            mime = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(
                suggestedName.substringAfterLast('.', "").lowercase(Locale.ROOT)) ?: "application/octet-stream"
            number(ready, "bytes", INBOX_LIMIT)
        } else {
            if (!Regex("[A-Za-z0-9][A-Za-z0-9._-]*\\.zip").matches(suggestedName) || suggestedName.length > 100 ||
                suggestedName.contains("..")) fail("invalid_artifact")
            val version = request.opt("version")
            if (version != 1 && version != 2) fail("invalid_artifact")
            val formatKey = if (version == 2) setOf("format") else emptySet()
            keys(request, setOf("version", "id", "notebookId", "notebookName", "snapshot", "archive") + formatKey)
            keys(ready, setOf("version", "id", "notebookId", "notebookName", "archive", "bytes", "sha256",
                "sourceBytes", "files", "directories", "archiveLimit") + formatKey)
            for (key in setOf("version", "id", "notebookId", "notebookName") + formatKey)
                if (request.opt(key) != ready.opt(key)) fail("invalid_artifact")
            if (request.opt("id") != operationId || request.opt("snapshot") != "snapshot" ||
                request.opt("archive") != "notebook.zip" || ready.opt("archive") != "notebook.zip" ||
                (version == 2 && request.optString("format") !in setOf("notebook", "filesAndAssets"))) fail("invalid_artifact")
            checkedText(request.getString("notebookId"), 127); checkedText(request.getString("notebookName"), 16384)
            val sourceBytes = number(ready, "sourceBytes", INBOX_LIMIT)
            val count = number(ready, "files", 100000) + number(ready, "directories", 100000)
            val limit = number(ready, "archiveLimit", LEGACY_CORE_LIMIT)
            val bytes = number(ready, "bytes", LEGACY_CORE_LIMIT)
            if (count > 100000 || limit < 22 || bytes < 22 || bytes > limit || sourceBytes + limit > LEGACY_CORE_LIMIT - METADATA_RESERVE)
                fail("invalid_artifact")
            source = File(transaction, "notebook.zip")
            mime = "application/zip"
        }
        if (path != source.path || source.canonicalFile != source) fail("invalid_artifact")
        val size = ready.getLong("bytes")
        val hash = ready.getString("sha256")
        if (!DIGEST.matches(hash) || regular(source).st_size != size) fail("invalid_artifact")
        createShare("artifact:$scope:$operationId:$hash", listOf(ExportInput(suggestedName, mime, source, size, hash)), checkExport)
    }

    private data class ExportInput(val name: String, val mime: String, val file: File, val bytes: Long, val hash: String)

    private fun createShare(key: String, inputs: List<ExportInput>, coreAdmission: ((String, Long) -> Int)? = null): Outgoing {
        val ledger = loadLedger()
        if (coreAdmission == null && !activated()) fail("activation_required")
        cleanup(ledger)
        val leases = ledger.getJSONArray("shares")
        for (i in 0 until leases.length()) {
            val lease = leases.getJSONObject(i)
            if (lease.getString("key") == key) return outgoing(lease)
        }
        val charge = inputs.sumOf { it.bytes } + METADATA_RESERVE
        // Core payloads are charged by native outgoing-shares scanning. Dynamic reader/chooser metadata
        // remains in the inbox partition so recipient opens never grow core staging outside its writer barrier.
        admit(ledger, if (coreAdmission == null) charge else METADATA_RESERVE)
        if (coreAdmission != null && coreAdmission(support.path, charge) != 0) fail("inbox_full")
        if (leases.length() >= PENDING_COUNT || ledger.getJSONArray("reservations").length() >= PENDING_COUNT) fail("inbox_full")
        val id = randomId()
        // A durable reservation owns even an interrupted snapshot. Never infer ownership from a filename alone.
        ledger.getJSONArray("reservations").put(JSONObject().put("id", id)
            .put("bytes", if (coreAdmission == null) charge else METADATA_RESERVE)
            .put("createdAt", System.currentTimeMillis()).put("kind", if (coreAdmission == null) "share" else "shareExport"))
        saveLedger(ledger)
        val group = if (coreAdmission == null) shares else File(support, "outgoing-shares").also(::ensureDirectory)
        val directory = File(group, id).also(::ensureDirectory)
        try {
            val files = JSONArray()
            for (input in inputs) {
                val token = randomId()
                copyVerified(input.file, File(directory, token), input.bytes, input.hash)
                files.put(JSONObject().put("token", token).put("name", input.name).put("mime", input.mime)
                    .put("bytes", input.bytes).put("sha256", input.hash))
            }
            syncDirectory(directory)
            val lease = JSONObject().put("id", id).put("key", key).put("boot", bootCount()).put("files", files)
                .put("readers", JSONArray()).put("chooser", JSONObject.NULL).put("retiring", false)
                .put("storage", if (coreAdmission == null) "inbox" else "core")
            leases.put(lease)
            removeReservation(ledger, id)
            saveLedger(ledger)
            return outgoing(lease)
        } catch (error: Exception) {
            val current = loadLedger()
            val published = current.getJSONArray("shares")
            if ((0 until published.length()).none { published.getJSONObject(it).getString("id") == id }) {
                // Only an unexposed, still-owned reservation may be removed after a failed commit.
                if (exists(directory)) removeTree(directory)
                removeReservation(current, id)
                saveLedger(current)
            }
            throw error
        }
    }

    private fun outgoing(lease: JSONObject): Outgoing {
        val directory = shareDirectory(lease).also(::requireDirectory)
        val files = lease.getJSONArray("files")
        return Outgoing(lease.getString("id"), (0 until files.length()).map {
            val file = files.getJSONObject(it)
            val token = file.getString("token")
            if (regular(File(directory, token)).st_size != file.getLong("bytes")) fail("storage_corrupt")
            OutgoingFile(Uri.Builder().scheme("content").authority(app.packageName + ".share")
                .appendPath(token).build(), file.getString("mime"), file.getString("name"))
        })
    }

    /** Exact opaque token lookup; provider paths are never converted to filesystem paths. */
    fun sharedFile(token: String): Pair<File, JSONObject> = locked {
        val found = findShared(loadLedger(), token)
        found.third to found.second
    }

    fun openSharedFile(token: String, handler: Handler): ParcelFileDescriptor = locked {
        val ledger = loadLedger()
        val found = findShared(ledger, token)
        val lease = found.first
        val readers = lease.getJSONArray("readers")
        if (readers.length() >= 1024) fail("readers_active")
        val nonce = randomId()
        readers.put(nonce)
        saveLedger(ledger) // A killed provider leaves an uncertain reader, never a false idle snapshot.
        var descriptor: ParcelFileDescriptor? = null
        try {
            val before = regular(found.third)
            val opened = ParcelFileDescriptor.open(found.third, ParcelFileDescriptor.MODE_READ_ONLY, handler) {
                readerWorker.execute {
                    try { closeReader(lease.getString("id"), nonce) } catch (_: Exception) { /* Retain the uncertain lease. */ }
                }
            }
            descriptor = opened
            sameFile(before, Os.fstat(opened.fileDescriptor))
            sameFile(before, regular(found.third))
            opened
        } catch (error: Exception) {
            descriptor?.close()
            for (i in readers.length() - 1 downTo 0) if (readers.getString(i) == nonce) readers.remove(i)
            saveLedger(ledger)
            throw error
        }
    }

    private fun closeReader(id: String, nonce: String) = locked {
        val ledger = loadLedger()
        val readers = shareLease(ledger, id).getJSONArray("readers")
        for (i in readers.length() - 1 downTo 0) if (readers.getString(i) == nonce) readers.remove(i)
        saveLedger(ledger)
    }

    private fun findShared(ledger: JSONObject, token: String): Triple<JSONObject, JSONObject, File> {
        validId(token)
        val leases = ledger.getJSONArray("shares")
        for (i in 0 until leases.length()) {
            val lease = leases.getJSONObject(i)
            if (lease.getBoolean("retiring")) continue
            val files = lease.getJSONArray("files")
            for (j in 0 until files.length()) {
                val file = files.getJSONObject(j)
                if (file.getString("token") == token) {
                    val directory = shareDirectory(lease).also(::requireDirectory)
                    val source = File(directory, token)
                    if (regular(source).st_size != file.getLong("bytes")) fail("storage_corrupt")
                    return Triple(lease, file, source)
                }
            }
        }
        fail("lease_unavailable")
    }

    private fun querySource(uri: Uri, fallbackMime: String?, signal: CancellationSignal): Source {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT || uri.authority.isNullOrEmpty()) fail("source_unavailable")
        signal.throwIfCanceled()
        var name: String? = null
        var size: Long? = null
        app.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null, signal)?.use { cursor ->
            if (!cursor.moveToFirst()) fail("source_unavailable")
            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
            if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) size = cursor.getLong(sizeColumn)
            if (cursor.moveToNext()) fail("source_unavailable")
        } ?: fail("source_unavailable")
        val checkedName = name ?: fail("invalid_name")
        validName(checkedName)
        if (size != null && (size!! < 0 || size!! > FILE_LIMIT)) fail("delivery_limit")
        val mime = app.contentResolver.getType(uri) ?: fallbackMime?.takeIf { !it.contains('*') } ?: "application/octet-stream"
        validMime(mime)
        return Source(uri, checkedName, mime, size)
    }

    private fun activated(): Boolean {
        val marker = File(root, "activation.json")
        if (!exists(marker)) return false
        val value = readJson(marker, 1024)
        keys(value, setOf("version", "coreStagingBytes", "inboxBytes"))
        if (value.opt("version") != 1 || number(value, "coreStagingBytes", CORE_LIMIT) != CORE_LIMIT ||
            number(value, "inboxBytes", INBOX_LIMIT) != INBOX_LIMIT) fail("storage_corrupt")
        return true
    }

    private fun beginWriter(bytes: Long, kind: String): Writer {
        val ledger = loadLedger()
        cleanup(ledger)
        if (!activated()) fail("activation_required")
        val rows = ledger.getJSONArray("records")
        val reservations = ledger.getJSONArray("reservations")
        val pending = (0 until rows.length()).count { rows.getJSONObject(it).getString("state") !in SETTLED } +
            (0 until reservations.length()).count { reservations.getJSONObject(it).getString("kind") in setOf("incoming", "copy") }
        if (pending >= PENDING_COUNT) fail("inbox_full")
        if ((0 until reservations.length()).count {
                val value = reservations.getJSONObject(it)
                value.getString("kind") in setOf("incoming", "copy") && writerActive(value.getString("id"))
            } >= WRITER_COUNT) fail("inbox_busy")
        admit(ledger, bytes)
        val id = randomId()
        reservations.put(JSONObject().put("id", id).put("bytes", bytes).put("createdAt", System.currentTimeMillis()).put("kind", kind))
        saveLedger(ledger)
        val directory = File(payloads, id).also(::ensureDirectory)
        val channel = openLock(File(directory, "writer.lock"))
        try {
            val writer = Writer(id, directory, channel, channel.tryLock() ?: fail("inbox_busy"))
            liveWriters.add(id)
            return writer
        } catch (error: Exception) {
            channel.close()
            throw error
        }
    }

    private fun admit(ledger: JSONObject, bytes: Long) {
        if (bytes < 0 || bytes > INBOX_LIMIT) fail("inbox_full")
        val usage = reservedUsage(ledger)
        // Atomic ledger replacement needs a second complete metadata image until rename commits.
        val ledgerSize = if (exists(File(root, "ledger.json"))) regular(File(root, "ledger.json")).st_size else 0L
        if (usage.first + bytes + ledgerSize + METADATA_RESERVE > INBOX_LIMIT ||
            root.usableSpace < usage.second + bytes + ledgerSize + METADATA_RESERVE + HEADROOM) fail("inbox_full")
    }

    private fun reservedUsage(ledger: JSONObject): Pair<Long, Long> {
        var reserved = 0L
        var remaining = 0L
        val excluded = HashSet<String>()
        val reservations = ledger.getJSONArray("reservations")
        for (i in 0 until reservations.length()) {
            val row = reservations.getJSONObject(i)
            val directory = reservationDirectory(row)
            val capacity = row.getLong("bytes")
            val actual = if (row.getString("kind") != "shareExport" && exists(directory)) treeBytes(directory) else 0L
            if (actual > capacity) fail("storage_corrupt")
            excluded.add(directory.path)
            reserved += capacity
            remaining += capacity - actual
        }
        // Charge active directories by their fixed reservation, not two racing samples of growing files.
        return (treeBytes(root, excluded) + reserved) to remaining
    }

    private fun loadLedger(): JSONObject {
        val file = File(root, "ledger.json")
        if (!exists(file)) {
            val outgoing = File(support, "outgoing-shares")
            if (exists(File(root, "activation.json")) || children(payloads).isNotEmpty() || children(shares).isNotEmpty() ||
                (exists(outgoing) && children(outgoing).isNotEmpty()))
                fail("storage_corrupt")
            val ledger = JSONObject().put("version", 1).put("records", JSONArray()).put("reservations", JSONArray())
                .put("garbage", JSONArray()).put("shares", JSONArray())
            saveLedger(ledger)
            return ledger
        }
        val ledger = readJson(file, LEDGER_LIMIT)
        keys(ledger, setOf("version", "records", "reservations", "garbage", "shares", "checksum"))
        val checksum = ledger.getString("checksum")
        if (!DIGEST.matches(checksum)) fail("storage_corrupt")
        ledger.remove("checksum")
        if (digest(utf8(ledger.toString(), LEDGER_LIMIT)) != checksum) fail("storage_corrupt")
        ledger.put("checksum", checksum)
        if (ledger.opt("version") != 1) fail("storage_corrupt")
        val rows = ledger.getJSONArray("records")
        if (rows.length() > HISTORY_COUNT) fail("storage_corrupt")
        val ids = HashSet<String>()
        val payloadIds = HashSet<String>()
        val operations = HashSet<String>()
        for (i in 0 until rows.length()) {
            val row = rows.getJSONObject(i)
            keys(row, RECORD_KEYS, setOf("operationId", "target", "cohortId", "nonce"))
            validId(row.getString("id")); if (!ids.add(row.getString("id"))) fail("storage_corrupt")
            validateManifestFields(row)
            val state = row.getString("state")
            if (state !in STATES) fail("storage_corrupt")
            for (field in arrayOf("payload", "candidate")) if (!row.isNull(field)) {
                val id = row.getString(field); validId(id)
                if (!payloadIds.add(id)) fail("storage_corrupt")
            }
            if (!row.isNull("payload") && !row.isNull("candidate")) fail("storage_corrupt")
            if (state !in SETTLED && row.isNull("payload")) fail("storage_corrupt")
            if (!row.isNull("candidate") && state !in SETTLED) fail("storage_corrupt")
            if (row.has("operationId")) {
                validId(row.getString("operationId")); validateTarget(row.getJSONObject("target"))
                if (!operations.add(row.getString("operationId"))) fail("storage_corrupt")
            } else if (row.has("target") || state == "importing" || state == "consumed") fail("storage_corrupt")
            if (row.has("cohortId")) checkedText(row.getString("cohortId"), 127)
            if (state == "consumed" && !row.has("cohortId")) fail("storage_corrupt")
            if (row.has("nonce")) validId(row.getString("nonce"))
        }
        val reservations = ledger.getJSONArray("reservations")
        if (reservations.length() > PENDING_COUNT) fail("storage_corrupt")
        val shareIds = HashSet<String>()
        val coreShareIds = HashSet<String>()
        for (i in 0 until reservations.length()) {
            val row = reservations.getJSONObject(i)
            keys(row, setOf("id", "bytes", "createdAt", "kind")); validId(row.getString("id"))
            number(row, "bytes", INBOX_LIMIT); number(row, "createdAt", Long.MAX_VALUE)
            val kind = row.getString("kind")
            if (kind !in setOf("incoming", "copy", "share", "shareExport")) fail("storage_corrupt")
            val owners = when (kind) { "share" -> shareIds; "shareExport" -> coreShareIds; else -> payloadIds }
            if (!owners.add(row.getString("id"))) fail("storage_corrupt")
        }
        val garbage = ledger.getJSONArray("garbage")
        for (i in 0 until garbage.length()) { val id = garbage.getString(i); validId(id); if (!payloadIds.add(id)) fail("storage_corrupt") }
        val leases = ledger.getJSONArray("shares")
        if (leases.length() > PENDING_COUNT) fail("storage_corrupt")
        val tokens = HashSet<String>()
        for (i in 0 until leases.length()) {
            val lease = leases.getJSONObject(i)
            keys(lease, setOf("id", "key", "boot", "files", "readers", "chooser", "retiring", "storage")); validId(lease.getString("id"))
            if (lease.optString("storage") !in setOf("inbox", "core")) fail("storage_corrupt")
            if (lease.opt("retiring") !is Boolean) fail("storage_corrupt")
            if (!lease.isNull("chooser")) validId(lease.getString("chooser"))
            val readers = lease.getJSONArray("readers")
            if (readers.length() > 1024) fail("storage_corrupt")
            val readerIds = HashSet<String>()
            for (j in 0 until readers.length()) {
                val reader = readers.getString(j); validId(reader)
                if (!readerIds.add(reader)) fail("storage_corrupt")
            }
            if (lease.getBoolean("retiring") && (!lease.isNull("chooser") || readers.length() > 0)) fail("storage_corrupt")
            checkedText(lease.getString("key"), 512)
            val boot = lease.getLong("boot"); if (boot < -1) fail("storage_corrupt")
            if (!(if (lease.getString("storage") == "core") coreShareIds else shareIds).add(lease.getString("id"))) fail("storage_corrupt")
            val files = lease.getJSONArray("files")
            if (files.length() !in 1..FILE_COUNT + 1) fail("storage_corrupt")
            for (j in 0 until files.length()) {
                val entry = files.getJSONObject(j)
                keys(entry, setOf("token", "name", "mime", "bytes", "sha256")); validId(entry.getString("token"))
                if (!tokens.add(entry.getString("token"))) fail("storage_corrupt")
                validName(entry.getString("name")); validMime(entry.getString("mime"))
                number(entry, "bytes", if (lease.getString("storage") == "core") CORE_LIMIT else INBOX_LIMIT)
                if (!DIGEST.matches(entry.getString("sha256"))) fail("storage_corrupt")
            }
        }
        for (directory in children(payloads)) if (directory.name !in payloadIds) fail("storage_corrupt")
        for (directory in children(shares)) if (directory.name !in shareIds) fail("storage_corrupt")
        val outgoing = File(support, "outgoing-shares")
        if (exists(outgoing)) for (directory in children(outgoing)) if (directory.name !in coreShareIds) fail("storage_corrupt")
        return ledger
    }

    private fun saveLedger(ledger: JSONObject) {
        ledger.remove("checksum")
        ledger.put("checksum", digest(utf8(ledger.toString(), LEDGER_LIMIT)))
        val bytes = utf8(ledger.toString(), LEDGER_LIMIT)
        val previous = File(root, "ledger.json")
        val stale = File(root, "ledger.json.tmp")
        if (exists(stale)) unlink(stale)
        val usage = reservedUsage(ledger)
        if (usage.first + bytes.size > INBOX_LIMIT || root.usableSpace < usage.second + bytes.size + HEADROOM) fail("inbox_full")
        atomicBytes(previous, bytes)
    }

    private fun cleanup(ledger: JSONObject) {
        var changed = false
        val garbage = ledger.getJSONArray("garbage")
        for (i in garbage.length() - 1 downTo 0) {
            val id = garbage.getString(i)
            if (writerActive(id)) continue
            val directory = File(payloads, id)
            if (exists(directory)) removeTree(directory)
            garbage.remove(i); changed = true
        }
        val reservations = ledger.getJSONArray("reservations")
        val now = System.currentTimeMillis()
        for (i in reservations.length() - 1 downTo 0) {
            val row = reservations.getJSONObject(i)
            val created = row.getLong("createdAt")
            if (now < created || now - created <= PARTIAL_AGE) continue
            val id = row.getString("id")
            // A live receiving lease always wins, including exactly at the 24-hour boundary.
            if (row.getString("kind") in setOf("incoming", "copy") && writerActive(id)) continue
            val directory = reservationDirectory(row)
            if (exists(directory)) removeTree(directory)
            reservations.remove(i); changed = true
        }
        val boot = bootCount()
        val leases = ledger.getJSONArray("shares")
        for (i in leases.length() - 1 downTo 0) {
            val lease = leases.getJSONObject(i)
            // A reboot closes every old descriptor and revokes temporary activity URI grants.
            // Chooser return, app restart, detach and age are NOT safe reader completion signals.
            val pastBoot = boot >= 0 && lease.getLong("boot") >= 0 && lease.getLong("boot") != boot.toLong()
            if (!lease.getBoolean("retiring") && !pastBoot) continue
            val files = lease.getJSONArray("files")
            for (j in 0 until files.length()) {
                val uri = Uri.Builder().scheme("content").authority(app.packageName + ".share")
                    .appendPath(files.getJSONObject(j).getString("token")).build()
                app.revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val directory = shareDirectory(lease)
            if (exists(directory)) removeTree(directory)
            leases.remove(i); changed = true
        }
        if (changed) saveLedger(ledger)
    }

    private fun bootCount(): Int = try { Settings.Global.getInt(app.contentResolver, Settings.Global.BOOT_COUNT) } catch (_: Exception) { -1 }

    private fun writerActive(id: String): Boolean {
        if (id in liveWriters) return true
        val directory = File(payloads, id)
        if (!exists(directory)) return false
        requireDirectory(directory)
        val path = File(directory, "writer.lock")
        if (!exists(path)) return false
        return openLock(path).use { channel ->
            try {
                val lease = channel.tryLock()
                if (lease == null) true else { lease.release(); false }
            } catch (_: OverlappingFileLockException) { true }
        }
    }

    private fun abortWriter(id: String) {
        val ledger = loadLedger()
        val reservations = ledger.getJSONArray("reservations")
        if ((0 until reservations.length()).none { reservations.getJSONObject(it).getString("id") == id }) return
        removeReservation(ledger, id)
        ledger.getJSONArray("garbage").put(id)
        saveLedger(ledger)
    }

    private fun requireReservation(ledger: JSONObject, id: String) {
        val rows = ledger.getJSONArray("reservations")
        if ((0 until rows.length()).count { rows.getJSONObject(it).getString("id") == id } != 1) fail("storage_corrupt")
    }

    private fun removeReservation(ledger: JSONObject, id: String) {
        val rows = ledger.getJSONArray("reservations")
        for (i in rows.length() - 1 downTo 0) if (rows.getJSONObject(i).getString("id") == id) { rows.remove(i); return }
        fail("storage_corrupt")
    }

    private fun releasePayload(ledger: JSONObject, record: JSONObject, field: String) {
        if (!record.isNull(field)) ledger.getJSONArray("garbage").put(record.getString(field))
        record.put(field, JSONObject.NULL)
    }

    private fun retained(row: JSONObject): String? = when {
        !row.isNull("payload") -> row.getString("payload")
        !row.isNull("candidate") -> row.getString("candidate")
        else -> null
    }

    private fun record(ledger: JSONObject, id: String): JSONObject {
        validId(id)
        val rows = ledger.getJSONArray("records")
        for (i in 0 until rows.length()) if (rows.getJSONObject(i).getString("id") == id) return rows.getJSONObject(i)
        fail("record_unavailable")
    }

    private fun newRecord(manifest: JSONObject, payload: String): JSONObject = JSONObject()
        .put("id", manifest.getString("id")).put("fingerprint", manifest.getString("fingerprint"))
        .put("state", "ready").put("bytes", manifest.getLong("bytes")).put("files", manifest.getJSONArray("files"))
        .put("textBytes", manifest.getLong("textBytes")).put("textSha256", manifest.getString("textSha256"))
        .put("payload", payload).put("candidate", JSONObject.NULL)

    private fun manifestOf(record: JSONObject, id: String): JSONObject = JSONObject().put("version", 1).put("id", id)
        .put("fingerprint", record.getString("fingerprint")).put("bytes", record.getLong("bytes"))
        .put("textBytes", record.getLong("textBytes")).put("textSha256", record.getString("textSha256"))
        .put("files", record.getJSONArray("files"))

    private fun proofClaim(row: JSONObject) = JSONObject().put("id", row.getString("id"))
        .put("operationId", row.getString("operationId")).put("target", row.getJSONObject("target"))

    private fun publicRecord(row: JSONObject): Map<String, Any?> {
        val output = linkedMapOf<String, Any?>("id" to row.getString("id"), "fingerprint" to row.getString("fingerprint"),
            "state" to row.getString("state"), "bytes" to row.getLong("bytes"),
            "files" to jsonValue(row.getJSONArray("files")), "payloadAvailable" to (retained(row) != null),
            "duplicateAvailable" to !row.isNull("candidate"))
        for (key in arrayOf("operationId", "target", "cohortId")) if (row.has(key)) output[key] = jsonValue(row.get(key))
        return output
    }

    private fun validateManifestFields(value: JSONObject) {
        if (!DIGEST.matches(value.getString("fingerprint")) || !DIGEST.matches(value.getString("textSha256"))) fail("storage_corrupt")
        val text = number(value, "textBytes", TEXT_LIMIT)
        var total = text
        val files = value.getJSONArray("files")
        if (files.length() > FILE_COUNT || (files.length() == 0 && text == 0L)) fail("storage_corrupt")
        val names = ArrayList<String>()
        for (i in 0 until files.length()) {
            val file = files.getJSONObject(i)
            keys(file, setOf("name", "mime", "bytes", "sha256"))
            val name = file.getString("name"); validName(name); names.add(name)
            validMime(file.getString("mime"))
            total += number(file, "bytes", FILE_LIMIT)
            if (!DIGEST.matches(file.getString("sha256"))) fail("storage_corrupt")
        }
        checkNames(names, text > 0)
        if (number(value, "bytes", DELIVERY_LIMIT) != total) fail("storage_corrupt")
    }

    private fun validatePayload(record: JSONObject, id: String, hash: Boolean) {
        validId(id)
        val directory = File(payloads, id).also(::requireDirectory)
        val manifest = readJson(File(directory, "manifest.json"), METADATA_RESERVE)
        if (!sameJson(manifest, manifestOf(record, id))) fail("storage_corrupt")
        val textBytes = record.getLong("textBytes")
        val allowed = if (textBytes > 0) setOf("manifest.json", "writer.lock", "files", "text.txt") else setOf("manifest.json", "writer.lock", "files")
        if (children(directory).any { it.name !in allowed }) fail("storage_corrupt")
        var text = ByteArray(0)
        if (textBytes > 0) {
            val file = File(directory, "text.txt")
            if (regular(file).st_size != textBytes) fail("storage_corrupt")
            if (hash) {
                text = readBytes(file, TEXT_LIMIT)
                if (digest(text) != record.getString("textSha256")) fail("storage_corrupt")
            }
        }
        val files = record.getJSONArray("files")
        val contents = File(directory, "files").also(::requireDirectory)
        if (children(contents).map { it.name }.toSet() != (0 until files.length()).map { it.toString() }.toSet()) fail("storage_corrupt")
        for (i in 0 until files.length()) {
            val entry = files.getJSONObject(i)
            val file = File(contents, i.toString())
            if (regular(file).st_size != entry.getLong("bytes")) fail("storage_corrupt")
            if (hash && hashFile(file) != entry.getString("sha256")) fail("storage_corrupt")
        }
        if (hash && fingerprint(text, files) != record.getString("fingerprint")) fail("storage_corrupt")
    }

    companion object {
        private val processLock = ReentrantLock()
        private val liveWriters = HashSet<String>()
        private val readerWorker = Executors.newSingleThreadExecutor()
        const val FILE_LIMIT = 64L * 1024 * 1024
        const val DELIVERY_LIMIT = 256L * 1024 * 1024
        const val TEXT_LIMIT = 1024L * 1024
        const val INBOX_LIMIT = 1024L * 1024 * 1024
        const val CORE_LIMIT = 3L * INBOX_LIMIT
        private const val LEGACY_CORE_LIMIT = 4L * INBOX_LIMIT
        private const val HEADROOM = 64L * 1024 * 1024
        private const val METADATA_RESERVE = 128L * 1024
        private const val LEDGER_LIMIT = 64L * 1024 * 1024
        private const val PARTIAL_AGE = 24L * 60 * 60 * 1000
        private const val FILE_COUNT = 64
        private const val PENDING_COUNT = 200
        private const val HISTORY_COUNT = 10000
        private const val WRITER_COUNT = 2
        private const val TEXT_NAME = "Shared text.md"
        private val ID = Regex("[0-9a-f]{32}")
        private val DIGEST = Regex("[0-9a-f]{64}")
        private val MIME = Regex("[A-Za-z0-9!#$&^_.+\\-]+/[A-Za-z0-9!#$&^_.+\\-]+")
        private val RESERVED = Regex("(?i)(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])")
        private val LOCALES = setOf("system", "en", "zh")
        private val STATES = setOf("ready", "importing", "consumed", "discarded", "failed")
        private val SETTLED = setOf("consumed", "discarded")
        private val RECORD_KEYS = setOf("id", "fingerprint", "state", "bytes", "files", "textBytes", "textSha256", "payload", "candidate")
        private fun fail(code: String): Nothing = throw ShareFailure(code)
        private fun randomId() = UUID.randomUUID().toString().replace("-", "")
        private fun validId(id: String) { if (!ID.matches(id)) fail("invalid_request") }
        private fun validMime(mime: String) { if (mime.length > 255 || !MIME.matches(mime) || mime == "inode/directory") fail("invalid_type") }
        private fun checkedText(value: String, maximum: Long) {
            if (value.isEmpty() || value.any { it < ' ' || it in '\u007f'..'\u009f' }) fail("invalid_request")
            utf8(value, maximum)
        }
        private fun validName(name: String) {
            if (name.isEmpty() || name == "." || name == ".." || name.endsWith('.') || name.endsWith(' ') ||
                name.any { it < ' ' || it in '\u007f'..'\u009f' || it in "/\\:*?\"<>|" } ||
                RESERVED.matches(name.substringBefore('.'))) fail("invalid_name")
            utf8(name, 255)
        }
        private fun validateTarget(target: JSONObject) {
            keys(target, setOf("notebookId", "parentId", "notebookRelative", "folderName"))
            for (key in arrayOf("notebookId", "parentId", "notebookRelative", "folderName")) validName(target.getString(key))
            checkedText(target.getString("notebookId"), 127); checkedText(target.getString("parentId"), 127)
        }
        private fun checkNames(names: List<String>, text: Boolean) {
            val nfc = HashSet<String>(); val nfd = HashSet<String>()
            for (name in if (text) names + TEXT_NAME else names) {
                validName(name)
                val c = UCharacter.foldCase(Normalizer.normalize(name, Normalizer.Form.NFC), true)
                val d = UCharacter.foldCase(Normalizer.normalize(name, Normalizer.Form.NFD), true)
                if (!nfc.add(c) || !nfd.add(d)) fail("name_collision")
            }
        }
        private fun utf8(value: String, maximum: Long): ByteArray {
            if (value.length.toLong() > maximum) fail("delivery_limit")
            val buffer = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).encode(java.nio.CharBuffer.wrap(value))
            if (buffer.remaining().toLong() > maximum) fail("delivery_limit")
            return ByteArray(buffer.remaining()).also { buffer.get(it) }
        }
        private fun digest(bytes: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(bytes))
        private fun hex(bytes: ByteArray): String {
            val chars = CharArray(bytes.size * 2)
            val alphabet = "0123456789abcdef"
            for (i in bytes.indices) { val value = bytes[i].toInt() and 255; chars[2 * i] = alphabet[value ushr 4]; chars[2 * i + 1] = alphabet[value and 15] }
            return String(chars)
        }
        private fun fingerprint(text: ByteArray, files: JSONArray): String {
            val hash = MessageDigest.getInstance("SHA-256")
            val length = ByteBuffer.allocate(8)
            fun field(bytes: ByteArray) { length.clear(); length.putLong(bytes.size.toLong()); hash.update(length.array()); hash.update(bytes) }
            field("vnote-share-v1".toByteArray(Charsets.UTF_8)); field(text)
            field(files.length().toString().toByteArray(Charsets.UTF_8))
            for (i in 0 until files.length()) {
                val file = files.getJSONObject(i)
                for (key in arrayOf("name", "mime", "bytes", "sha256")) field(file.get(key).toString().toByteArray(Charsets.UTF_8))
            }
            return hex(hash.digest())
        }
        private fun keys(value: JSONObject, required: Set<String>, optional: Set<String> = emptySet()) {
            val actual = value.keys().asSequence().toSet()
            if (!actual.containsAll(required) || (actual - required - optional).isNotEmpty()) fail("storage_corrupt")
        }
        private fun number(value: JSONObject, key: String, maximum: Long): Long {
            val raw = value.get(key)
            val number = when (raw) { is Int -> raw.toLong(); is Long -> raw; else -> fail("storage_corrupt") }
            if (number < 0 || number > maximum) fail("storage_corrupt")
            return number
        }
        private fun jsonValue(value: Any?): Any? = when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWith { jsonValue(value.get(it)) }
            is JSONArray -> (0 until value.length()).map { jsonValue(value.get(it)) }
            is Int -> value.toLong()
            else -> value
        }
        private fun sameJson(first: JSONObject, second: JSONObject) = jsonValue(first) == jsonValue(second)
        private fun exists(file: File): Boolean = try { Os.lstat(file.path); true } catch (error: ErrnoException) {
            if (error.errno != OsConstants.ENOENT) throw error
            false
        }
        internal fun requireDirectory(file: File) {
            val stat = Os.lstat(file.path)
            if (file.canonicalFile != file || !OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != Process.myUid() ||
                stat.st_mode and OsConstants.S_IWOTH != 0) fail("storage_corrupt")
        }
        private fun ensureDirectory(file: File) {
            if (!exists(file)) {
                try { Os.mkdir(file.path, 448); syncDirectory(file.parentFile!!) }
                catch (error: ErrnoException) { if (error.errno != OsConstants.EEXIST) throw error }
            }
            requireDirectory(file)
        }
        internal fun regular(file: File): StructStat {
            val value = Os.lstat(file.path)
            if (file.canonicalFile != file || !OsConstants.S_ISREG(value.st_mode) || value.st_nlink != 1L ||
                value.st_uid != Process.myUid() || value.st_size < 0 || value.st_mode and OsConstants.S_IWOTH != 0) fail("storage_corrupt")
            return value
        }
        internal fun sameFile(first: StructStat, second: StructStat) {
            if (!OsConstants.S_ISREG(second.st_mode) || first.st_dev != second.st_dev || first.st_ino != second.st_ino ||
                first.st_size != second.st_size || first.st_mtime != second.st_mtime || first.st_ctime != second.st_ctime ||
                first.st_nlink != second.st_nlink) fail("source_changed")
        }
        private fun children(file: File): Array<File> { requireDirectory(file); return file.listFiles() ?: fail("storage_unavailable") }
        private fun treeBytes(root: File, excluded: Set<String> = emptySet()): Long {
            requireDirectory(root)
            if (root.path in excluded) return 0L
            var bytes = 4096L
            for (file in children(root)) {
                val stat = Os.lstat(file.path)
                bytes += if (OsConstants.S_ISDIR(stat.st_mode)) treeBytes(file, excluded) else regular(file).st_size
                if (bytes > INBOX_LIMIT) fail("inbox_full")
            }
            return bytes
        }
        private fun openLock(file: File): FileChannel {
            if (!exists(file)) {
                try { exclusive(file) { it.fd.sync() } } catch (error: ErrnoException) { if (error.errno != OsConstants.EEXIST) throw error }
                syncDirectory(file.parentFile!!)
            }
            val before = regular(file)
            val descriptor = Os.open(file.path, OsConstants.O_RDWR or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
            try { sameFile(before, Os.fstat(descriptor)); return ParcelFileDescriptor.AutoCloseOutputStream(ParcelFileDescriptor.dup(descriptor)).channel }
            finally { Os.close(descriptor) }
        }
        private fun <T> input(file: File, action: (FileInputStream) -> T): T {
            val before = regular(file)
            val descriptor = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
            try {
                sameFile(before, Os.fstat(descriptor))
                return FileInputStream(descriptor).use { stream ->
                    val result = action(stream)
                    sameFile(before, Os.fstat(descriptor)); sameFile(before, regular(file))
                    result
                }
            } finally { Os.close(descriptor) }
        }
        private fun exclusive(file: File, action: (FileOutputStream) -> Unit) {
            requireDirectory(file.parentFile!!)
            val descriptor = Os.open(file.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or OsConstants.O_EXCL or
                OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 384)
            try { FileOutputStream(descriptor).use(action) } finally { Os.close(descriptor) }
        }
        private fun readBytes(file: File, maximum: Long): ByteArray {
            val size = regular(file).st_size
            if (size > maximum || size > Int.MAX_VALUE) fail("storage_corrupt")
            return input(file) { stream ->
                val bytes = ByteArray(size.toInt())
                var offset = 0
                while (offset < bytes.size) { val count = stream.read(bytes, offset, bytes.size - offset); if (count <= 0) fail("storage_corrupt"); offset += count }
                if (stream.read() != -1) fail("source_changed")
                bytes
            }
        }
        private fun readJson(file: File, maximum: Long = 16384): JSONObject {
            val bytes = readBytes(file, maximum)
            if (bytes.isEmpty()) fail("storage_corrupt")
            return JSONObject(Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes)).toString())
        }
        private fun writeBytes(file: File, bytes: ByteArray) = exclusive(file) { it.write(bytes); it.fd.sync() }
        private fun atomicJson(file: File, value: JSONObject) = atomicBytes(file, utf8(value.toString(), METADATA_RESERVE))
        private fun atomicBytes(file: File, bytes: ByteArray) {
            val temporary = File(file.parentFile, file.name + ".tmp")
            if (exists(temporary)) unlink(temporary)
            writeBytes(temporary, bytes)
            if (exists(file)) regular(file)
            Os.rename(temporary.path, file.path)
            syncDirectory(file.parentFile!!)
        }
        private fun syncDirectory(file: File) {
            requireDirectory(file)
            val before = Os.lstat(file.path)
            val descriptor = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
            try {
                val opened = Os.fstat(descriptor)
                if (!OsConstants.S_ISDIR(opened.st_mode) || opened.st_dev != before.st_dev || opened.st_ino != before.st_ino) fail("source_changed")
                Os.fsync(descriptor)
            } finally { Os.close(descriptor) }
        }
        private fun unlink(file: File) { regular(file); Os.remove(file.path); syncDirectory(file.parentFile!!) }
        private fun removeTree(directory: File) {
            requireDirectory(directory)
            for (file in children(directory)) {
                if (OsConstants.S_ISDIR(Os.lstat(file.path).st_mode)) removeTree(file) else unlink(file)
            }
            Os.remove(directory.path); syncDirectory(directory.parentFile!!)
        }
        private fun copy(input: InputStream, output: File, maximum: Long, signal: CancellationSignal? = null): Pair<Long, String> {
            val hash = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            var total = 0L
            exclusive(output) { stream ->
                while (true) {
                    signal?.throwIfCanceled()
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (count == 0) continue
                    total += count
                    if (total > maximum || output.parentFile!!.usableSpace < HEADROOM + count) fail("delivery_limit")
                    stream.write(buffer, 0, count); hash.update(buffer, 0, count)
                }
                stream.fd.sync()
            }
            return total to hex(hash.digest())
        }
        private fun copyVerified(source: File, output: File, bytes: Long, hash: String) {
            if (regular(source).st_size != bytes) fail("source_changed")
            val copied = input(source) { copy(it, output, bytes) }
            if (copied.first != bytes || copied.second != hash) fail("source_changed")
        }
        private fun hashFile(file: File): String = input(file) { stream ->
            val hash = MessageDigest.getInstance("SHA-256")
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = stream.read(buffer); if (count < 0) break; if (count > 0) hash.update(buffer, 0, count) }
            hex(hash.digest())
        }
        private fun requirePrefix(partial: File, complete: File) {
            if (regular(partial).st_size > regular(complete).st_size) fail("stage_conflict")
            input(partial) { previous -> input(complete) { source ->
                val a = ByteArray(64 * 1024); val b = ByteArray(64 * 1024)
                while (true) {
                    val count = previous.read(a); if (count < 0) break
                    var offset = 0
                    while (offset < count) { val got = source.read(b, offset, count - offset); if (got <= 0) fail("stage_conflict"); offset += got }
                    for (i in 0 until count) if (a[i] != b[i]) fail("stage_conflict")
                }
            } }
        }
    }
}
