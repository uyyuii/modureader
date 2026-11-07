package com.modu.reader

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/**
 * SAF-based import plus original-location ("linked") access.
 *
 * Ordinary imports copy the selection into the app cache so the importer can
 * do its work. Linked books are different: only the absolute path is kept and
 * the original file is read in place, so nothing is duplicated. Android 11+
 * requires the special "All files access" grant for raw paths outside the app
 * sandbox; Android 10 uses legacy storage, older releases the runtime grant.
 */
class BookFolderPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var binding: ActivityPluginBinding? = null
    private var pending: MethodChannel.Result? = null
    private var extensions = emptySet<String>()
    private var pickingFiles = false
    private val entries = linkedMapOf<String, Pair<Uri, String>>()
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private val prefs
        get() = context.getSharedPreferences("moduLinkedBooksV1", Context.MODE_PRIVATE)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.modu.reader/book_folder")
        channel.setMethodCallHandler(::handle)
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pick" -> pick(call, result)
            "link" -> link(call, result)
            "restoreLinks" -> restoreLinks(result)
            "forgetLink" -> forgetLink(call, result)
            "hasAllFilesAccess" -> result.success(hasAllFilesAccess())
            "requestAllFilesAccess" -> {
                requestAllFilesAccess()
                result.success(null)
            }
            "sdkInt" -> result.success(Build.VERSION.SDK_INT)
            "copy" -> copy(call, result)
            "release" -> worker.execute {
                entries.clear()
                main.post { result.success(null) }
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(call: MethodCall, result: MethodChannel.Result) {
        val activity = binding?.activity
        if (pending != null || activity == null) {
            result.error("UNAVAILABLE", "Picker is not available", null)
            return
        }
        entries.clear()
        extensions = (call.argument<List<String>>("extensions") ?: emptyList())
            .map { it.lowercase() }.toSet()
        pickingFiles = call.argument<Boolean>("files") == true
        pending = result
        val intent = if (pickingFiles) {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
        try {
            activity.startActivityForResult(intent, if (pickingFiles) REQUEST_FILES else REQUEST_FOLDER)
        } catch (_: Exception) {
            pending = null
            result.error("PICK_FAILED", "Unable to open picker", null)
        }
    }

    private fun copy(call: MethodCall, result: MethodChannel.Result) {
        val ids = call.argument<List<String>>("ids") ?: emptyList()
        worker.execute {
            var session: File? = null
            try {
                session = File(context.cacheDir, "book-folder-${UUID.randomUUID()}")
                check(session.mkdirs())
                val paths = ids.mapIndexed { index, id ->
                    val entry = entries[id] ?: error("Unknown entry")
                    val dir = File(session, "$index")
                    check(dir.mkdirs())
                    val file = File(dir, File(entry.second).name)
                    context.contentResolver.openInputStream(entry.first).use { input ->
                        checkNotNull(input)
                        file.outputStream().use { output -> input.copyTo(output) }
                    }
                    file.absolutePath
                }
                main.post { result.success(paths) }
            } catch (_: Exception) {
                session?.deleteRecursively()
                main.post { result.error("READ_FAILED", "Unable to copy selected books", null) }
            }
        }
    }

    /** Keeps only the original path; no book bytes are copied. */
    private fun link(call: MethodCall, result: MethodChannel.Result) {
        val entry = call.argument<String>("id")?.let { entries[it] }
        if (entry == null) {
            result.error("LINK_FAILED", "Unknown selection", null)
            return
        }
        worker.execute {
            try {
                val path = localPath(entry.first) ?: throw IllegalArgumentException("Not a local document")
                val file = File(path)
                if (!file.isFile || !file.canRead()) throw IllegalArgumentException("Not readable")
                val extension = entry.second.substringAfterLast('.', "").lowercase()
                val key = "$LINK_PREFIX${UUID.randomUUID()}.$extension"
                prefs.edit().putString(key, file.absolutePath).apply()
                main.post { result.success(mapOf("key" to key, "path" to file.absolutePath)) }
            } catch (_: Exception) {
                main.post {
                    result.error("LINK_FAILED", "Unable to retain original book access", null)
                }
            }
        }
    }

    private fun restoreLinks(result: MethodChannel.Result) {
        worker.execute {
            val paths = mutableMapOf<String, String>()
            for ((key, value) in prefs.all) {
                val path = value as? String ?: continue
                if (!key.startsWith(LINK_PREFIX)) continue
                val file = File(path)
                // Keep entries whose access is temporarily revoked (for example
                // when "All files access" is turned off); only report usable
                // paths now, and let an explicit delete clear the record.
                if (file.isFile && file.canRead()) paths[key] = file.absolutePath
            }
            main.post { result.success(paths) }
        }
    }

    private fun forgetLink(call: MethodCall, result: MethodChannel.Result) {
        val key = call.argument<String>("key")
        worker.execute {
            if (key != null) prefs.edit().remove(key).apply()
            main.post { result.success(null) }
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            // Android 10 uses requestLegacyExternalStorage; older releases the
            // normal runtime permission.
            context.checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestAllFilesAccess() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val appSettings = Intent(
            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
            Uri.parse("package:${context.packageName}")
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(appSettings)
        } catch (_: Exception) {
            try {
                context.startActivity(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (_: Exception) {
                // The grant can still be enabled manually from system settings.
            }
        }
    }

    /**
     * Resolves a document URI to a readable filesystem path. Only providers
     * that expose a real file are accepted; cloud providers stay unsupported
     * because streaming them would require a second, copied file.
     */
    private fun localPath(uri: Uri): String? {
        val docId = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull()
            ?: return null
        when (uri.authority) {
            "com.android.externalstorage.documents" -> {
                val volume = docId.substringBefore(':', "")
                val relative = docId.substringAfter(':', "")
                if (relative.isEmpty()) return null
                val roots = when (volume) {
                    "primary" -> listOf(Environment.getExternalStorageDirectory())
                    "home" -> listOf(
                        Environment.getExternalStoragePublicDirectory(
                            Environment.DIRECTORY_DOCUMENTS
                        ),
                        Environment.getExternalStorageDirectory()
                    )
                    else -> listOf(File("/storage/$volume"), File("/mnt/media_rw/$volume"))
                }
                for (root in roots) {
                    val candidate = File(root, relative)
                    if (!candidate.isFile || !candidate.canRead()) continue
                    val canonical = runCatching { candidate.canonicalPath }.getOrNull()
                        ?: continue
                    val rootCanonical = runCatching { root.canonicalPath }.getOrNull()
                        ?: continue
                    if (!canonical.startsWith(rootCanonical + File.separator)) continue
                    return canonical
                }
            }
            "com.android.providers.downloads.documents" -> {
                if (docId.startsWith("raw:")) {
                    val file = File(docId.removePrefix("raw:"))
                    if (file.isFile && file.canRead()) return file.canonicalPath
                }
                runCatching {
                    context.contentResolver.query(
                        uri, arrayOf(MediaStore.MediaColumns.DATA), null, null, null
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val file = File(cursor.getString(0))
                            if (file.isFile && file.canRead()) return file.canonicalPath
                        }
                    }
                }
                // Scoped DownloadsProvider hides _data but still names the file.
                val name = displayName(uri) ?: return null
                val size = displaySize(uri)
                val candidate = File(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                    name
                )
                if (candidate.isFile && candidate.canRead() &&
                    (size == null || candidate.length() == size)
                ) {
                    return candidate.canonicalPath
                }
            }
        }
        return null
    }

    private fun displayName(uri: Uri): String? = runCatching {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    }.getOrNull()

    private fun displaySize(uri: Uri): Long? = runCatching {
        context.contentResolver.query(
            uri, arrayOf(OpenableColumns.SIZE), null, null, null
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getLong(0) else null
        }
    }.getOrNull()

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_FOLDER && requestCode != REQUEST_FILES) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        if (requestCode == REQUEST_FILES) {
            finishFiles(data, result)
        } else {
            val tree = data?.data
            if (tree == null) {
                result.success(null)
                return true
            }
            finishFolder(tree, result)
        }
        return true
    }

    private fun finishFiles(data: Intent?, result: MethodChannel.Result) {
        val uris = mutableListOf<Uri>()
        data?.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index)?.uri?.let { uris.add(it) }
            }
        }
        if (uris.isEmpty()) data?.data?.let { uris.add(it) }
        worker.execute {
            entries.clear()
            val found = mutableListOf<Map<String, String>>()
            for (uri in uris) {
                val name = displayName(uri) ?: continue
                if (name.startsWith(".") || name.contains('/') || name.contains('\\')) continue
                if (name.substringAfterLast('.', "").lowercase() !in extensions) continue
                val key = found.size.toString()
                entries[key] = Pair(uri, name)
                found.add(mapOf("id" to key, "name" to name, "label" to name))
            }
            main.post { result.success(found) }
        }
    }

    private fun finishFolder(tree: Uri, result: MethodChannel.Result) {
        worker.execute {
            try {
                val found = mutableListOf<Map<String, String>>()
                val visited = mutableSetOf<String>()
                fun visit(id: String, prefix: String) {
                    if (!visited.add(id)) return
                    val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
                    val columns = arrayOf(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                        DocumentsContract.Document.COLUMN_MIME_TYPE
                    )
                    val cursor = context.contentResolver.query(uri, columns, null, null, null)
                        ?: error("Unable to enumerate folder")
                    cursor.use {
                        while (it.moveToNext()) {
                            val childId = it.getString(0)
                            val name = it.getString(1) ?: continue
                            if (name.startsWith(".") || name.contains('/') || name.contains('\\')) continue
                            val label = if (prefix.isEmpty()) name else "$prefix/$name"
                            if (it.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR) {
                                visit(childId, label)
                            } else if (name.substringAfterLast('.', "").lowercase() in extensions) {
                                val key = found.size.toString()
                                entries[key] = Pair(
                                    DocumentsContract.buildDocumentUriUsingTree(tree, childId),
                                    name
                                )
                                found.add(mapOf("id" to key, "name" to name, "label" to label))
                            }
                        }
                    }
                }
                visit(DocumentsContract.getTreeDocumentId(tree), "")
                main.post { result.success(found.sortedBy { it["label"]?.lowercase() }) }
            } catch (_: Exception) {
                entries.clear()
                main.post { result.error("READ_FAILED", "Unable to read selected folder", null) }
            }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        binding?.removeActivityResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        onDetachedFromActivityForConfigChanges()
        pending?.success(null)
        pending = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }

    companion object {
        private const val REQUEST_FOLDER = 48129
        private const val REQUEST_FILES = 48130
        private const val LINK_PREFIX = "file/android-linked-"
    }
}
