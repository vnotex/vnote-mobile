package com.example.vnote_mobile

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.OpenableColumns
import java.io.FileNotFoundException

/** No path mapping/XML roots: each granted URI authorizes one immutable, independently retained file. */
class ShareExportProvider : ContentProvider() {
    private val main = Handler(Looper.getMainLooper())
    override fun onCreate() = true

    private fun token(uri: Uri): String {
        val app = context ?: throw FileNotFoundException("Share unavailable")
        val token = uri.lastPathSegment ?: throw FileNotFoundException("Share unavailable")
        if (uri.scheme != "content" || uri.authority != app.packageName + ".share" ||
            !Regex("[0-9a-f]{32}").matches(token) || uri.encodedPath != "/$token" ||
            uri.query != null || uri.fragment != null) throw FileNotFoundException("Share unavailable")
        if (Binder.getCallingUid() != Process.myUid() && app.checkUriPermission(uri, Binder.getCallingPid(),
                Binder.getCallingUid(), Intent.FLAG_GRANT_READ_URI_PERMISSION) != PackageManager.PERMISSION_GRANTED)
            throw SecurityException("Read grant required")
        return token
    }

    override fun getType(uri: Uri): String {
        val token = token(uri)
        return try { ShareInbox(requireNotNull(context)).sharedFile(token).second.getString("mime") }
        catch (_: Exception) { throw FileNotFoundException("Share unavailable") }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?,
        selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val token = token(uri)
        if (selection != null || selectionArgs != null || sortOrder != null) throw IllegalArgumentException("Unsupported query")
        try {
            val entry = ShareInbox(requireNotNull(context)).sharedFile(token).second
            val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
            if (columns.any { it != OpenableColumns.DISPLAY_NAME && it != OpenableColumns.SIZE })
                throw IllegalArgumentException("Unsupported column")
            return MatrixCursor(columns, 1).apply {
                addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) entry.getString("name") else entry.getLong("bytes") })
            }
        } catch (_: Exception) { throw FileNotFoundException("Share unavailable") }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        val token = token(uri)
        if (mode != "r") throw FileNotFoundException("Read-only share")
        return try { ShareInbox(requireNotNull(context)).openSharedFile(token, main) }
        catch (_: Exception) { throw FileNotFoundException("Share unavailable") }
    }

    override fun openFile(uri: Uri, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        signal?.throwIfCanceled()
        return openFile(uri, mode)
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri = throw UnsupportedOperationException("Read-only share")
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("Read-only share")
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("Read-only share")
}
