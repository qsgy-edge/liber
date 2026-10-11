package com.liber.liber

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.Process
import android.provider.DocumentsContract
import android.system.Os
import android.system.OsConstants
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** SAF identities stay URIs/document IDs. A read token owns its PFD until releaseRead. */
internal class LocalLibraryChannel(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "liber/local_library")
    private val resolver get() = activity.contentResolver
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val jobs = ConcurrentHashMap<String, CopyJob>()
    private val leases = mutableMapOf<String, ParcelFileDescriptor>()
    private var picker: Pair<Boolean, MethodChannel.Result>? = null
    @Volatile private var closed = false

    private class Failure(val code: String, message: String, val details: Any? = null) : Exception(message)
    private class CopyJob {
        val cancelled = AtomicBoolean(false)
        val copied = AtomicLong(0)
        @Volatile var total: Long? = null
        @Volatile var finished = false
        fun check() { if (cancelled.get()) throw Failure("cancelled", "Copy cancelled") }
    }

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (closed) throw Failure("io", "Library channel is closed")
            val args = if (call.arguments == null) emptyMap() else map(call.arguments, "arguments")
            when (call.method) {
                "pickDirectory", "pickFiles" -> pick(call.method == "pickDirectory", result)
                "progress" -> {
                    val job = jobs[string(args, "operationId")] ?: throw Failure("missing", "Unknown operation")
                    result.success(mapOf("bytesCopied" to job.copied.get(), "totalBytes" to job.total))
                }
                "cancel" -> {
                    val job = jobs[string(args, "operationId")] ?: throw Failure("missing", "Unknown operation")
                    job.cancelled.set(true)
                    result.success(null)
                }
                // Never queue release behind IO that could be consuming this descriptor.
                "releaseRead" -> {
                    val pfd = synchronized(leases) { leases.remove(string(args, "token")) }
                        ?: throw Failure("missing", "Unknown read lease")
                    pfd.close()
                    result.success(null)
                }
                "copyFile" -> {
                    val id = string(args, "operationId")
                    val job = CopyJob()
                    if (jobs.putIfAbsent(id, job) != null) throw Failure("collision", "Operation ID already used")
                    // Progress is retained for completed operations, with a bounded history.
                    jobs.entries.filter { it.value.finished }.take((jobs.size - 64).coerceAtLeast(0))
                        .forEach { jobs.remove(it.key, it.value) }
                    execute(result) { try { copy(args, job) } finally { job.finished = true } }
                }
                "inspectRoot", "list", "stat", "fileInRoot", "fingerprint", "acquireRead",
                "deleteFile", "renameFile", "replaceFile" -> execute(result) { dispatch(call.method, args) }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { fail(result, error) }
    }

    private fun execute(result: MethodChannel.Result, body: () -> Any?) {
        io.execute {
            try {
                if (closed) throw Failure("cancelled", "Library channel closed")
                val value = body()
                main.post { result.success(value) }
            } catch (error: Exception) { main.post { fail(result, error) } }
        }
    }

    private fun fail(result: MethodChannel.Result, error: Exception) {
        val code = when (error) {
            is Failure -> error.code
            is SecurityException -> "permission"
            is FileNotFoundException -> "missing"
            else -> "io"
        }
        // Provider exception messages can contain private paths. Return a class, not its message.
        result.error(code, if (error is Failure) error.message else "Native document operation failed",
            if (error is Failure) error.details else mapOf("nativeError" to error.javaClass.simpleName))
    }

    private fun pick(directory: Boolean, result: MethodChannel.Result) {
        if (picker != null) throw Failure("io", "A document picker is already open")
        val intent = Intent(if (directory) Intent.ACTION_OPEN_DOCUMENT_TREE else Intent.ACTION_OPEN_DOCUMENT)
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        if (directory) intent.addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
        else {
            intent.addCategory(Intent.CATEGORY_OPENABLE)
            intent.type = "*/*"
            intent.putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "text/markdown", "text/x-markdown"))
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        picker = directory to result
        try { activity.startActivityForResult(intent, PICK_REQUEST) }
        catch (error: Exception) { picker = null; throw error }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_REQUEST) return false
        val pending = picker ?: return true
        picker = null
        if (resultCode == Activity.RESULT_CANCELED) { pending.second.success(null); return true }
        if (resultCode != Activity.RESULT_OK || data == null) {
            fail(pending.second, Failure("io", "Picker returned no document")); return true
        }
        execute(pending.second) {
            if (pending.first) {
                val uri = data.data ?: throw Failure("io", "Picker returned no tree")
                val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                if (flags != READ_WRITE || data.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0)
                    throw Failure("permission", "Directory requires persistent read and write grants")
                resolver.takePersistableUriPermission(uri, flags)
                val root = rootMap(uri)
                inspectRoot(root, true)
            } else {
                val uris = mutableListOf<Uri>()
                data.clipData?.let { clip -> for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri) }
                if (uris.isEmpty()) data.data?.let { uris.add(it) }
                if (uris.isEmpty()) throw Failure("io", "Picker returned no documents")
                uris.distinct().map { uri ->
                    requirePermission(uri, false)
                    val file = query(uri) ?: throw Failure("missing", "Selected document is missing")
                    requireBook(file)
                    // Original URI's temporary OS grant is the authorization, never a picker cache path.
                    file
                }
            }
        }
        return true
    }

    private fun dispatch(method: String, args: Map<String, Any?>): Any? = when (method) {
        "inspectRoot" -> inspectRoot(map(args["root"], "root"), boolean(args, "writable"))
        "list" -> {
            val root = checkedRoot(map(args["root"], "root"), false)
            val directory = args["directory"]?.let { rooted(root, map(it, "directory"), false) } ?: rootDocument(root)
            val info = query(directory) ?: throw Failure("missing", "Directory is missing")
            if (info["directory"] != true) throw Failure("io", "Expected a directory")
            children(root, directory)
        }
        "stat" -> {
            val file = map(args["file"], "file")
            val root = optionalRoot(args, file)
            try {
                val uri = access(file, root, false)
                query(uri, root)
            } catch (error: FileNotFoundException) { null }
            catch (error: Failure) { if (error.code == "missing") null else throw error }
        }
        "fileInRoot" -> {
            val root = checkedRoot(map(args["root"], "root"), false)
            val file = map(args["file"], "file")
            val original = documentUri(string(file, "locator"))
            requirePermission(original, false)
            if (!belongs(root, original)) null else query(canonical(root, original), root)
        }
        "fingerprint" -> {
            val file = map(args["file"], "file")
            val uri = access(file, optionalRoot(args, file), false)
            requireRegular(uri)
            fingerprint(uri)
        }
        "acquireRead" -> {
            val file = map(args["file"], "file")
            val root = optionalRoot(args, file)
            val uri = access(file, root, false)
            val info = requireRegular(uri, root)
            val pfd = openRead(uri)
            try {
                val token = UUID.randomUUID().toString()
                synchronized(leases) {
                    if (closed) throw Failure("cancelled", "Library channel closed")
                    leases[token] = pfd
                }
                mapOf("token" to token, "fd" to pfd.fd, "file" to info)
            } catch (error: Exception) { pfd.close(); throw error }
        }
        "deleteFile" -> {
            val root = checkedRoot(map(args["root"], "root"), true)
            val uri = rooted(root, map(args["file"], "file"), true)
            requireRegular(uri)
            if (!DocumentsContract.deleteDocument(resolver, uri)) throw Failure("io", "Provider refused deletion")
            null
        }
        "renameFile" -> {
            val root = checkedRoot(map(args["root"], "root"), true)
            rooted(root, map(args["file"], "file"), true)
            name(args, "name")
            throw Failure("unsupported", "SAF does not guarantee a no-clobber rename")
        }
        "replaceFile" -> {
            val root = checkedRoot(map(args["root"], "root"), true)
            rooted(root, map(args["staged"], "staged"), true)
            rooted(root, map(args["existing"], "existing"), true)
            name(args, "backupName")
            string(args, "operationId")
            throw Failure("unsupported", "SAF does not guarantee recoverable atomic replacement")
        }
        else -> throw Failure("unsupported", "Unknown operation")
    }

    private fun rootMap(uri: Uri): Map<String, Any?> {
        if (!DocumentsContract.isTreeUri(uri)) throw Failure("permission", "Expected a SAF tree URI")
        val document = DocumentsContract.buildDocumentUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri))
        val file = query(document) ?: throw Failure("missing", "Selected directory is missing")
        if (file["directory"] != true) throw Failure("io", "Root is not a directory")
        return mapOf("kind" to "android", "locator" to uri.toString(), "authorization" to null,
            "identity" to "${uri.authority}:${DocumentsContract.getTreeDocumentId(uri)}", "displayName" to file["name"])
    }

    private fun checkedRoot(root: Map<String, Any?>, writable: Boolean): Map<String, Any?> {
        if (string(root, "kind") != "android") throw Failure("unsupported", "Expected an Android root")
        val uri = Uri.parse(string(root, "locator"))
        if (uri.scheme != "content" || !DocumentsContract.isTreeUri(uri)) throw Failure("permission", "Invalid tree URI")
        val grant = resolver.persistedUriPermissions.firstOrNull { it.uri == uri }
        if (grant == null || !grant.isReadPermission || (writable && !grant.isWritePermission))
            throw Failure("permission", "Persistent directory grant is missing or revoked")
        requirePermission(rootDocument(root), writable)
        return root
    }

    private fun inspectRoot(root: Map<String, Any?>, writable: Boolean): Map<String, Any?> {
        checkedRoot(root, writable)
        val refreshed = rootMap(Uri.parse(string(root, "locator")))
        val existing = children(refreshed, rootDocument(refreshed))
        if (writable) {
            val uri = DocumentsContract.createDocument(resolver, rootDocument(refreshed), "application/octet-stream",
                ".liber-probe-${UUID.randomUUID()}") ?: throw Failure("io", "Provider did not create write probe")
            if (existing.any { it["key"] == DocumentsContract.getDocumentId(uri) })
                throw Failure("verification", "Provider reused an existing document for the probe; it was not modified")
            var failure: Exception? = null
            try {
                resolver.openFileDescriptor(uri, "w")?.use { pfd ->
                    ParcelFileDescriptor.AutoCloseOutputStream(pfd).use { output ->
                        output.write(byteArrayOf(0x4c)); output.flush(); pfd.fileDescriptor.sync()
                    }
                } ?: throw Failure("io", "Provider returned no writable descriptor")
                openRead(uri).use { pfd -> ParcelFileDescriptor.AutoCloseInputStream(pfd).use {
                    if (it.read() != 0x4c || it.read() != -1) throw Failure("verification", "Write probe did not round-trip")
                } }
            } catch (error: Exception) { failure = error }
            cleanup(uri, failure)
            if (failure != null) throw failure
        }
        return refreshed
    }

    private fun rootDocument(root: Map<String, Any?>): Uri {
        val tree = Uri.parse(string(root, "locator"))
        return DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
    }

    private fun canonical(root: Map<String, Any?>, uri: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(
        Uri.parse(string(root, "locator")), DocumentsContract.getDocumentId(uri))

    private fun belongs(root: Map<String, Any?>, uri: Uri): Boolean {
        val parent = rootDocument(root)
        if (parent.authority != uri.authority) return false
        if (DocumentsContract.getDocumentId(parent) == DocumentsContract.getDocumentId(uri)) return true
        if (Build.VERSION.SDK_INT < 24) throw Failure("unsupported", "Provider membership proof requires Android 7")
        // Keep an independently granted child in its original grant context until membership is
        // proved. Wrapping a nonmember in this tree makes the provider reject it before dispatch.
        try { return DocumentsContract.isChildDocument(resolver, parent, uri) }
        catch (error: UnsupportedOperationException) { throw Failure("unsupported", "Provider cannot prove document membership") }
    }

    private fun rooted(root: Map<String, Any?>, file: Map<String, Any?>, writable: Boolean): Uri {
        checkedRoot(root, writable)
        val uri = documentUri(string(file, "locator"))
        if (uri.authority != rootDocument(root).authority) throw Failure("permission", "Document is outside the selected root")
        val canonical = canonical(root, uri)
        requirePermission(canonical, writable)
        if (string(file, "key") != DocumentsContract.getDocumentId(canonical))
            throw Failure("verification", "Document key does not match its locator")
        // Query through the granted tree first: the provider enforces tree access and can distinguish
        // a missing child from a revoked grant before isChildDocument would simply return false.
        if (query(canonical) == null) throw Failure("missing", "Document is missing")
        if (!belongs(root, uri)) throw Failure("permission", "Document is outside the selected root")
        return canonical
    }

    private fun access(file: Map<String, Any?>, root: Map<String, Any?>?, writable: Boolean): Uri {
        if (root != null) return rooted(root, file, writable)
        val uri = documentUri(string(file, "locator"))
        requirePermission(uri, writable)
        return uri
    }

    private fun requirePermission(uri: Uri, writable: Boolean) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or (if (writable) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
        if (activity.checkUriPermission(uri, Process.myPid(), Process.myUid(), flags) != PackageManager.PERMISSION_GRANTED)
            throw Failure("permission", "Document grant is missing or revoked")
    }

    private val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_LAST_MODIFIED)

    private fun query(uri: Uri, root: Map<String, Any?>? = null): Map<String, Any?>? {
        val cursor = resolver.query(uri, columns, null, null, null) ?: throw Failure("io", "Provider returned no metadata cursor")
        cursor.use {
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) || it.extras.getString(DocumentsContract.EXTRA_ERROR) != null)
                throw Failure("io", "Provider metadata is incomplete or failed")
            if (!it.moveToFirst()) return null
            val id = it.getString(0) ?: throw Failure("io", "Provider omitted document identity")
            val displayName = it.getString(1) ?: throw Failure("io", "Provider omitted document name")
            val modified = if (it.isNull(4)) null else it.getLong(4).takeIf { value -> value > 0 }
            return linkedMapOf<String, Any?>("locator" to uri.toString(), "key" to id, "name" to displayName,
                "directory" to (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR),
                "size" to if (it.isNull(3)) null else it.getLong(3).takeIf { value -> value >= 0 },
                "modifiedAt" to modified, "identity" to "${uri.authority}:$id").also { file -> if (root != null) file["root"] = root }
        }
    }

    private fun children(root: Map<String, Any?>, directory: Uri): List<Map<String, Any?>> {
        val tree = Uri.parse(string(root, "locator"))
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getDocumentId(directory))
        val cursor = resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)
            ?: throw Failure("io", "Provider returned no directory cursor")
        val files = mutableListOf<Map<String, Any?>>()
        cursor.use {
            while (it.moveToNext()) {
                val id = it.getString(0) ?: throw Failure("io", "Provider omitted child identity")
                val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                files.add(query(uri, root) ?: throw Failure("io", "Directory changed during enumeration"))
            }
            if (it.extras.getBoolean(DocumentsContract.EXTRA_LOADING, false) || it.extras.getString(DocumentsContract.EXTRA_ERROR) != null)
                throw Failure("io", "Provider directory listing is incomplete or failed")
        }
        return files
    }

    private fun requireRegular(uri: Uri, root: Map<String, Any?>? = null): Map<String, Any?> {
        val file = query(uri, root) ?: throw Failure("missing", "Document is missing")
        if (file["directory"] != false) throw Failure("unsupported", "Expected a file, not a directory")
        return file
    }

    private fun requireBook(file: Map<String, Any?>) {
        if (file["directory"] != false || (file["name"] as String).substringAfterLast('.', "").lowercase() !in setOf("txt", "md"))
            throw Failure("unsupported", "Select TXT or Markdown files")
    }

    private fun openRead(uri: Uri): ParcelFileDescriptor {
        val pfd = resolver.openFileDescriptor(uri, "r") ?: throw Failure("io", "Provider returned no read descriptor")
        try { Os.lseek(pfd.fileDescriptor, 0, OsConstants.SEEK_SET) }
        catch (error: Exception) { pfd.close(); throw Failure("unsupported", "Document is not seekable") }
        return pfd
    }

    private fun fingerprint(uri: Uri, job: CopyJob? = null): Map<String, Any?> {
        val digest = MessageDigest.getInstance("SHA-256")
        var count = 0L
        openRead(uri).use { pfd -> ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                job?.check()
                val length = input.read(buffer)
                if (length < 0) break
                digest.update(buffer, 0, length); count += length
            }
        } }
        return mapOf("bytes" to count, "sha256" to hex(digest.digest()))
    }

    private fun copy(args: Map<String, Any?>, job: CopyJob): Map<String, Any?> {
        val source = map(args["source"], "source")
        val root = checkedRoot(map(args["destinationRoot"], "destinationRoot"), true)
        val name = name(args, "name")
        val sourceUri = access(source, source["root"]?.let { map(it, "source.root") }, false)
        val before = requireRegular(sourceUri)
        job.total = before["size"] as Long?
        val existing = children(root, rootDocument(root))
        if (existing.any { it["name"] == name }) throw Failure("collision", "Destination name already exists")
        job.check()
        val destination = DocumentsContract.createDocument(resolver, rootDocument(root),
            if (name.endsWith(".md", true)) "text/markdown" else "text/plain", name)
            ?: throw Failure("io", "Provider did not create destination")
        // createDocument is a create API, not open/truncate. Reject a broken provider that returns an old ID.
        val id = DocumentsContract.getDocumentId(destination)
        if (existing.any { it["key"] == id } || (destination.authority == sourceUri.authority && id == DocumentsContract.getDocumentId(sourceUri)))
            throw Failure("verification", "Provider reused an existing document; it was not modified")
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            openRead(sourceUri).use { sourcePfd -> ParcelFileDescriptor.AutoCloseInputStream(sourcePfd).use { input ->
                val outputPfd = resolver.openFileDescriptor(destination, "w") ?: throw Failure("io", "Provider returned no write descriptor")
                outputPfd.use { pfd -> ParcelFileDescriptor.AutoCloseOutputStream(pfd).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        job.check()
                        val length = input.read(buffer)
                        if (length < 0) break
                        output.write(buffer, 0, length); digest.update(buffer, 0, length); job.copied.addAndGet(length.toLong())
                    }
                    output.flush(); pfd.fileDescriptor.sync()
                } }
            } }
            val hash = hex(digest.digest())
            val after = requireRegular(sourceUri)
            if (before["size"] != after["size"] || before["modifiedAt"] != after["modifiedAt"] ||
                (job.total != null && job.total != job.copied.get()))
                throw Failure("verification", "Source changed during copy")
            val verified = fingerprint(destination, job)
            if (verified["bytes"] != job.copied.get() || verified["sha256"] != hash)
                throw Failure("verification", "Copied bytes did not verify")
            job.check()
            return mapOf("file" to requireRegular(destination, root), "bytesCopied" to job.copied.get(), "sha256" to hash, "verified" to true)
        } catch (error: Exception) { cleanup(destination, error); throw error }
    }

    private fun cleanup(uri: Uri, original: Exception?) {
        try {
            if (!DocumentsContract.deleteDocument(resolver, uri)) throw Failure("io", "Provider refused cleanup")
        } catch (error: Exception) {
            throw Failure("io", "Owned temporary document cleanup failed", mapOf("cleanupFailed" to true,
                "locator" to uri.toString(), "cause" to if (original is Failure) original.code else "io"))
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        picker?.second?.error("cancelled", "Activity closed", null)
        picker = null
        jobs.values.forEach { it.cancelled.set(true) }
        synchronized(leases) { leases.values.forEach { it.close() }; leases.clear() }
        io.shutdown()
    }

    private fun optionalRoot(args: Map<String, Any?>, file: Map<String, Any?>): Map<String, Any?>? =
        (args["root"] ?: file["root"])?.let { map(it, "root") }
    private fun documentUri(value: String): Uri {
        val uri = Uri.parse(value)
        if (uri.scheme != "content" || !DocumentsContract.isDocumentUri(activity, uri))
            throw Failure("unsupported", "Expected an original SAF document URI")
        return uri
    }
    private fun map(value: Any?, field: String): Map<String, Any?> {
        if (value !is Map<*, *> || value.keys.any { it !is String }) throw Failure("io", "Invalid $field map")
        @Suppress("UNCHECKED_CAST") return value as Map<String, Any?>
    }
    private fun string(args: Map<String, Any?>, field: String): String =
        (args[field] as? String)?.takeIf { it.isNotEmpty() } ?: throw Failure("io", "Invalid $field")
    private fun boolean(args: Map<String, Any?>, field: String): Boolean =
        args[field] as? Boolean ?: throw Failure("io", "Invalid $field")
    private fun name(args: Map<String, Any?>, field: String): String = string(args, field).also {
        if (it == "." || it == ".." || it.any { c -> c == '/' || c == '\\' || c == '\u0000' }) throw Failure("io", "Invalid file name")
    }
    private fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
    companion object {
        private const val PICK_REQUEST = 0x4c12
        private const val READ_WRITE = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
    }
}
