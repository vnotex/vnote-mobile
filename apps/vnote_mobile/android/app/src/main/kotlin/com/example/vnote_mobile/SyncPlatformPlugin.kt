package com.example.vnote_mobile

import android.content.Context
import android.net.http.X509TrustManagerExtensions
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.StrictMode
import android.os.UserManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.UserNotAuthenticatedException
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import androidx.annotation.Keep
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileDescriptor
import java.nio.file.Files
import java.security.KeyStore
import java.security.MessageDigest
import java.security.UnrecoverableKeyException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.UUID
import java.util.concurrent.Executors
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** A dedicated native secret channel; never registered on an offline WebView. */
class SyncPlatformPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    @Volatile private var attached = false

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        attached = true
        // Queue before channel requests. No UI wait and no Activity is retained.
        worker.execute { SyncTlsBridge.initialize() }
        channel = MethodChannel(binding.binaryMessenger, "vnote.mobile/sync_security")
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attached = false
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        // Process-wide vault queue and JNI references outlive all engine owners.
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method !in methods) {
            result.notImplemented()
            return
        }
        val application = context
        if (application == null) {
            result.error("vault_unavailable", errorMessage, null)
            return
        }
        worker.execute {
            try {
                val args = call.arguments as? Map<*, *> ?: throw VaultFailure("vault_invalid")
                val value: Any? = if (call.method == "trustStatus") {
                    requireFields(args, emptySet())
                    mapOf("available" to SyncTlsBridge.available)
                } else {
                    Vault(application).handle(call.method, args)
                }
                main.post { if (attached) result.success(value) }
            } catch (failure: Exception) {
                val error = classify(failure)
                val details = error.revision?.let { mapOf("revision" to it) }
                main.post { if (attached) result.error(error.code, errorMessage, details) }
            }
        }
    }

    companion object {
        private val worker = Executors.newSingleThreadExecutor { job -> Thread(job, "vnote-sync-security") }
        private val main = Handler(Looper.getMainLooper())
        private val methods = setOf("vaultList", "vaultRead", "vaultWrite", "vaultDelete", "trustStatus")
        private const val errorMessage = "Secure sync storage is not available for this request."
    }
}

private class VaultFailure(val code: String, val revision: String? = null) : Exception()

private fun classify(error: Exception): VaultFailure {
    if (error is VaultFailure) return error
    var cause: Throwable? = error
    repeat(8) {
        when (cause) {
            is UserNotAuthenticatedException -> return VaultFailure("vault_locked")
            is KeyPermanentlyInvalidatedException, is UnrecoverableKeyException ->
                return VaultFailure("vault_unavailable")
        }
        cause = cause?.cause
    }
    return VaultFailure("vault_unavailable")
}

private fun validFingerprint(value: Any?): Boolean =
    value is String && value.length == 64 && value.all { it in '0'..'9' || it in 'a'..'f' }

private fun requireFields(args: Map<*, *>, names: Set<String>) {
    if (args.keys != names) throw VaultFailure("vault_invalid")
}

private fun fingerprint(bytes: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
    val digits = "0123456789abcdef"
    val result = CharArray(digest.size * 2)
    for (i in digest.indices) {
        val value = digest[i].toInt() and 255
        result[i * 2] = digits[value ushr 4]
        result[i * 2 + 1] = digits[value and 15]
    }
    return String(result)
}

private class Vault(private val context: Context) {
    private val root = File(context.noBackupFilesDir, "sync-vault-v1")
    private val alias = "${context.packageName}.sync-vault.v1"

    fun handle(method: String, args: Map<*, *>): Any? {
        val fields = when (method) {
            "vaultList" -> emptySet()
            "vaultRead" -> setOf("key")
            "vaultWrite" -> setOf("key", "expectedRevision", "data")
            "vaultDelete" -> setOf("key", "expectedRevision")
            else -> throw VaultFailure("vault_invalid")
        }
        requireFields(args, fields)
        val key = if (method == "vaultList") null else args["key"].also {
            if (!validFingerprint(it)) throw VaultFailure("vault_invalid")
        } as String?
        val expected = args["expectedRevision"]
        if ((method == "vaultDelete" && !validFingerprint(expected)) ||
            (method == "vaultWrite" && expected != null && !validFingerprint(expected))) {
            throw VaultFailure("vault_invalid")
        }
        val data = if (method == "vaultWrite") {
            val bytes = args["data"] as? ByteArray ?: throw VaultFailure("vault_invalid")
            if (bytes.size > maxPlaintext) throw VaultFailure("vault_limit")
            bytes
        } else null
        if (context.getSystemService(UserManager::class.java)?.isUserUnlocked != true) {
            throw VaultFailure("vault_locked")
        }
        prepareDirectory()
        val inventory = enumerate()
        var secret = loadKey(inventory.keys.isNotEmpty() || inventory.pending.isNotEmpty())
        // These files were never published by rename and cannot be a committed
        // generation. Clean only our exact exclusive-write namespace, under CAS serialization.
        for (temporary in inventory.pending) {
            checkedStat(temporary)
            Os.remove(temporary.path)
        }
        if (inventory.pending.isNotEmpty()) flushDirectory(root)
        if (method == "vaultList") return mapOf("keys" to inventory.keys.sorted())
        val scope = requireNotNull(key)
        val file = File(root, "$scope.rec")
        val current = readEnvelope(file)
        val revision = current?.let(::fingerprint)
        if (method == "vaultRead") {
            if (current == null) return mapOf("present" to false)
            val plaintext = decrypt(scope, current, requireNotNull(secret), requireNotNull(revision))
            return mapOf("present" to true, "revision" to revision, "data" to plaintext)
        }
        if (method == "vaultDelete") {
            if (current != null) {
                if (revision != expected) throw VaultFailure("vault_changed")
                // Do not decrypt: explicit authorization may delete this exact
                // corrupt generation, but never a replacement generation.
                Os.remove(file.path)
            }
            // Also flush an absent retry after a preceding unlink/flush failure.
            flushDirectory(root)
            flushDirectory(context.noBackupFilesDir)
            return null
        }
        if (revision != expected) throw VaultFailure("vault_changed")
        if (current != null) {
            val old = decrypt(scope, current, requireNotNull(secret), requireNotNull(revision))
            old.fill(0)
        } else if (inventory.keys.size >= maxRecords) {
            throw VaultFailure("vault_limit")
        }
        if (secret == null) secret = createKey()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secret)
        cipher.updateAAD(aad(scope))
        val nonce = cipher.iv
        if (nonce.size != nonceBytes) throw VaultFailure("vault_unavailable")
        val ciphertext = cipher.doFinal(requireNotNull(data))
        val envelope = ByteArray(magic.size + nonceBytes + ciphertext.size)
        magic.copyInto(envelope)
        nonce.copyInto(envelope, magic.size)
        ciphertext.copyInto(envelope, magic.size + nonceBytes)
        durableReplace(file, envelope)
        return mapOf("revision" to fingerprint(envelope))
    }

    private fun aad(scope: String): ByteArray =
        "vnote.sync-vault\u0000v1\u0000${context.packageName}\u0000$scope".toByteArray(Charsets.UTF_8)

    private fun decrypt(scope: String, envelope: ByteArray, secret: SecretKey, revision: String): ByteArray {
        if (envelope.size < magic.size + nonceBytes + tagBytes ||
            !magic.indices.all { envelope[it] == magic[it] }) throw VaultFailure("vault_corrupt", revision)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(128, envelope, magic.size, nonceBytes))
            cipher.updateAAD(aad(scope))
            return cipher.doFinal(envelope, magic.size + nonceBytes, envelope.size - magic.size - nonceBytes)
        } catch (_: AEADBadTagException) {
            throw VaultFailure("vault_corrupt", revision)
        }
    }

    private fun loadKey(hasCiphertext: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore")
        store.load(null)
        if (!store.containsAlias(alias)) {
            if (hasCiphertext) throw VaultFailure("vault_unavailable")
            return null
        }
        return store.getKey(alias, null) as? SecretKey ?: throw VaultFailure("vault_unavailable")
    }

    private fun createKey(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setKeySize(256)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setRandomizedEncryptionRequired(true)
            .build())
        return generator.generateKey()
    }

    private fun prepareDirectory() {
        try {
            Os.mkdir(root.path, 448) // 0700, never externally readable or backed up.
            flushDirectory(root.parentFile ?: throw VaultFailure("vault_unavailable"))
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.EEXIST) throw error
        }
        val stat = Os.lstat(root.path)
        if (!OsConstants.S_ISDIR(stat.st_mode) || stat.st_uid != Process.myUid() ||
            (stat.st_mode and 511) != 448) throw VaultFailure("vault_corrupt")
    }

    private data class Inventory(val keys: List<String>, val pending: List<File>)

    private fun enumerate(): Inventory {
        val keys = ArrayList<String>()
        val pending = ArrayList<File>()
        Files.newDirectoryStream(root.toPath()).use { entries ->
            for (entry in entries) {
                val name = entry.fileName.toString()
                if (name.length == 68 && name.endsWith(".rec") && validFingerprint(name.substring(0, 64))) {
                    if (keys.size == maxRecords) throw VaultFailure("vault_limit")
                    checkedStat(entry.toFile())
                    keys.add(name.substring(0, 64))
                } else if (name.length == 41 && name.startsWith(".pending-") &&
                    name.substring(9).all { it in '0'..'9' || it in 'a'..'f' }) {
                    if (pending.size == maxRecords) throw VaultFailure("vault_limit")
                    checkedStat(entry.toFile())
                    pending.add(entry.toFile())
                } else {
                    throw VaultFailure("vault_corrupt")
                }
            }
        }
        return Inventory(keys, pending)
    }

    private fun checkedStat(file: File) {
        checkStat(Os.lstat(file.path))
    }

    private fun checkStat(stat: android.system.StructStat) {
        if (!OsConstants.S_ISREG(stat.st_mode) || stat.st_uid != Process.myUid() ||
            stat.st_nlink != 1L || (stat.st_mode and 511) != 384 ||
            stat.st_size < 0 || stat.st_size > maxEnvelope) throw VaultFailure("vault_corrupt")
    }

    private fun readEnvelope(file: File): ByteArray? {
        val fd = try {
            Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.ENOENT) return null
            if (error.errno == OsConstants.ELOOP) throw VaultFailure("vault_corrupt")
            throw error
        }
        try {
            val stat = Os.fstat(fd)
            checkStat(stat)
            val result = ByteArray(stat.st_size.toInt())
            var offset = 0
            while (offset < result.size) {
                val count = Os.read(fd, result, offset, result.size - offset)
                if (count <= 0) throw VaultFailure("vault_corrupt")
                offset += count
            }
            if (Os.read(fd, ByteArray(1), 0, 1) != 0) throw VaultFailure("vault_corrupt")
            return result
        } finally {
            Os.close(fd)
        }
    }

    private fun durableReplace(destination: File, bytes: ByteArray) {
        val temporary = File(root, ".pending-${UUID.randomUUID().toString().replace("-", "")}")
        var fd: FileDescriptor? = null
        try {
            fd = Os.open(temporary.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or
                OsConstants.O_EXCL or OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 384)
            var offset = 0
            while (offset < bytes.size) {
                val count = Os.write(fd, bytes, offset, bytes.size - offset)
                if (count <= 0) throw VaultFailure("vault_unavailable")
                offset += count
            }
            Os.fsync(fd)
            Os.close(fd)
            fd = null
            Os.rename(temporary.path, destination.path)
            flushDirectory(root)
            // Covers a retry after this directory's initial parent flush failed.
            flushDirectory(context.noBackupFilesDir)
        } finally {
            fd?.let { Os.close(it) }
            // Retain an uncommitted temp on error: next serialized access safely
            // removes it, while never discarding the published old generation.
        }
    }

    private fun flushDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or
            OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC, 0)
        try {
            if (!OsConstants.S_ISDIR(Os.fstat(fd).st_mode)) throw VaultFailure("vault_corrupt")
            Os.fsync(fd)
        } finally { Os.close(fd) }
    }

    companion object {
        private const val maxRecords = 1000
        private const val maxPlaintext = 64 * 1024
        private const val nonceBytes = 12
        private const val tagBytes = 16
        private val magic = byteArrayOf(0x56, 0x4e, 0x53, 0x56, 0, 0, 0, 1)
        private const val maxEnvelope = 64 * 1024L + 8 + nonceBytes + tagBytes
    }
}

/** JNI-owned, application-independent trust state, pinned for the VM lifetime. */
@Keep
internal object SyncTlsBridge {
    @Volatile var available = false
        private set
    @Volatile private var trust: X509TrustManagerExtensions? = null

    fun initialize() {
        if (available) return
        try {
            val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            factory.init(null as KeyStore?)
            val managers = factory.trustManagers.filterIsInstance<X509TrustManager>()
            if (managers.size != 1) return
            trust = X509TrustManagerExtensions(managers.single())
            System.loadLibrary("vnote_host")
            available = nativeRegister()
        } catch (_: Exception) {
            available = false
        } catch (_: LinkageError) {
            available = false
        }
    }

    private external fun nativeRegister(): Boolean

    @Keep
    fun verifyServerChain(host: String, encoded: Array<ByteArray>): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper() || host.isEmpty() || host.length > 253 ||
            encoded.isEmpty() || encoded.size > 16) return false
        var total = 0
        for (bytes in encoded) {
            if (bytes.isEmpty() || bytes.size > 1024 * 1024 - total) return false
            total += bytes.size
        }
        val manager = trust ?: return false
        val previous = StrictMode.getThreadPolicy()
        try {
            StrictMode.setThreadPolicy(StrictMode.ThreadPolicy.Builder(previous)
                .detectNetwork().penaltyDeathOnNetwork().build())
            val factory = CertificateFactory.getInstance("X.509")
            val certificates = Array(encoded.size) { index ->
                val input = ByteArrayInputStream(encoded[index])
                val certificate = factory.generateCertificate(input) as X509Certificate
                if (input.available() != 0) return false
                certificate
            }
            // The public Conscrypt extension builds against actual system/app
            // anchors. No OCSP-data overload or network-capable custom checker.
            val authType = certificates[0].publicKey.algorithm
            if (authType.isNullOrEmpty()) return false
            return manager.checkServerTrusted(certificates, authType, host).isNotEmpty()
        } catch (_: Exception) {
            return false
        } finally {
            StrictMode.setThreadPolicy(previous)
        }
    }
}
