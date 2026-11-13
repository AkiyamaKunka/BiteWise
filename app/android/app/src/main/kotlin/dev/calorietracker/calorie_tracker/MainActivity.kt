package dev.calorietracker.calorie_tracker

import android.annotation.SuppressLint
import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ext.SdkExtensions
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URLConnection
import java.util.UUID

class MainActivity : FlutterActivity() {
    /// The open pickFiles call, answered from onActivityResult once the
    /// picked files are copied. Main thread only.
    private var pickReply: MethodChannel.Result? = null

    /// The open pickImages call, and the most photos it asked the picker
    /// for (which contract parses the result). Main thread only.
    private var photoPickReply: MethodChannel.Result? = null
    private var photoPickMax = 1

    /// The open saveFile call and the cached file it saves. Main thread
    /// only.
    private var saveReply: MethodChannel.Result? = null
    private var saveSource: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // receive_sharing_intent reads the launch intent while
        // super.onCreate attaches it: the copies must be there already.
        // A share is delivered once. An activity Android recreates (saved
        // state: its process was stopped while it sat in the background)
        // or relaunches from Recents still carries the intent that first
        // started its task, so the plugins get an empty one, with nothing
        // copied; that also keeps a bitewise://setup link from reopening
        // its dialog. New shares arrive through onNewIntent, as before. A
        // several-photo share cut short by the stop is not resumed.
        val replay = savedInstanceState != null ||
            ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (replay) {
            intent?.let { setIntent(emptyShare(it)) }
        } else {
            intent?.let { setIntent(withSafeShares(it)) }
        }
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(withSafeShares(intent))
    }

    /// receive_sharing_intent copied each shared stream into the cache on
    /// the main thread, under the file name the sender's provider reports,
    /// and caught nothing (review 171, C5): a share that could not be
    /// opened crashed the app, a name such as "../databases/…" wrote over
    /// the app's own files, and a share with no stream handed its text to
    /// Dart as the path, which share intake then deleted. The plugin now
    /// sees only copies made here, of the items it would report as images:
    /// each in a folder of its own under SHARE_FOLDER, under the sender's
    /// base name (its date stays readable), at most MAX_SHARE_BYTES. What
    /// cannot be read is left out, and none of the sender's extras is
    /// passed on; a share with nothing left reaches no plugin. The plugin
    /// reports a file:// URI as it is, without opening it.
    private fun withSafeShares(intent: Intent): Intent {
        val kind = intent.action
        val shareType = intent.type ?: return intent
        if (kind != Intent.ACTION_SEND && kind != Intent.ACTION_SEND_MULTIPLE &&
            kind != Intent.ACTION_VIEW) return intent
        val streams: List<Uri?>
        var listedTypes: Array<String?>? = null
        try {
            streams = when (kind) {
                Intent.ACTION_VIEW -> listOf(intent.data)
                Intent.ACTION_SEND -> listOf(intent.streamExtra())
                else -> intent.streamListExtra()
            }
            if (kind == Intent.ACTION_SEND_MULTIPLE) {
                listedTypes = intent.getStringArrayExtra(Intent.EXTRA_MIME_TYPES)
            }
        } catch (e: Exception) {
            return emptyShare(intent) // extras that cannot be read
        }
        val copies = ArrayList<Uri>()
        val copyTypes = ArrayList<String>()
        try {
            clearEmptyShareFolders()
        } catch (e: Exception) {
        }
        streams.forEachIndexed { i, uri ->
            try {
                if (uri == null) return@forEachIndexed
                if (isOwnShareOut(uri)) return@forEachIndexed
                val name = shareName(uri) ?: return@forEachIndexed
                // The type the plugin gives it: the share's own, or for
                // several, each one's listed type, else its name's.
                val itemType = if (kind == Intent.ACTION_SEND_MULTIPLE)
                    listedTypes?.getOrNull(i) ?: URLConnection.guessContentTypeFromName(name)
                else shareType
                if (itemType?.startsWith("image") != true) return@forEachIndexed
                val copy = copyShare(uri, name) ?: return@forEachIndexed
                copies.add(Uri.fromFile(copy))
                copyTypes.add(itemType)
            } catch (e: Exception) {
                // This item only: the others still go.
            }
        }
        if (copies.isEmpty()) return emptyShare(intent)
        return try {
            Intent(intent).apply {
                replaceExtras(Bundle())
                if (kind == Intent.ACTION_SEND_MULTIPLE) {
                    setDataAndType(null, shareType)
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, copies)
                    putExtra(Intent.EXTRA_MIME_TYPES, copyTypes.toTypedArray())
                } else {
                    // A VIEW of an image reaches the plugin as the SEND it
                    // is to it, with no data left for a deep link to read.
                    action = Intent.ACTION_SEND
                    setDataAndType(null, shareType)
                    putExtra(Intent.EXTRA_STREAM, copies[0])
                }
            }
        } catch (e: Exception) {
            Intent()
        }
    }

    /// Whether [uri] is one of the app's own share-out files (Today's day
    /// image, an Export), served by share_plus's FileProvider: Chopstats
    /// is a target in its own sharesheet, and such a file is no meal.
    private fun isOwnShareOut(uri: Uri): Boolean =
        "content".equals(uri.scheme, ignoreCase = true) &&
            "$packageName$SHARE_OUT_AUTHORITY_SUFFIX".equals(uri.authority, ignoreCase = true)

    /// [intent] with nothing a plugin reads as a share or a link.
    private fun emptyShare(intent: Intent): Intent = try {
        Intent(intent).apply {
            replaceExtras(Bundle())
            action = null
            setDataAndType(null, null)
        }
    } catch (e: Exception) {
        Intent()
    }

    @Suppress("DEPRECATION")
    private fun Intent.streamExtra(): Uri? =
        if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        else getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

    @Suppress("DEPRECATION")
    private fun Intent.streamListExtra(): List<Uri?> =
        if (Build.VERSION.SDK_INT >= 33) getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        else getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()

    /// The name the plugin gave [uri]'s copy, without any folder part: the
    /// display name its provider reports, or the plugin's own fallback; a
    /// file's own name. Null for any other scheme, or a name that is no
    /// file name ("..").
    private fun shareName(uri: Uri): String? = when (uri.scheme?.lowercase()) {
        "content" -> {
            val shown = try {
                contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { c ->
                        val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (c.moveToFirst() && i >= 0 && !c.isNull(i)) c.getString(i) else null
                    }
            } catch (e: Exception) {
                null
            }
            if (shown == null) fallbackShareName(uri) else baseName(shown)
        }
        "file" -> baseName(uri.path)
        else -> null
    }

    private fun baseName(raw: String?): String? {
        val name = raw?.substringAfterLast('/') ?: return null
        return if (name.isEmpty() || name == "." || name == ".." || '\u0000' in name) null else name
    }

    /// The plugin's name for a stream whose provider shows none.
    private fun fallbackShareName(uri: Uri): String {
        val mime = try {
            contentResolver.getType(uri)
        } catch (e: Exception) {
            null
        }
        val prefix = when {
            mime?.startsWith("image") == true -> "IMG"
            mime?.startsWith("video") == true -> "VID"
            else -> "FILE"
        }
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        return "${prefix}_${System.currentTimeMillis()}" + (ext?.let { ".$it" } ?: "")
    }

    /// [uri] copied into a folder of its own under SHARE_FOLDER as [name];
    /// null when it cannot be read or written, is over MAX_SHARE_BYTES, or
    /// is one of the app's own files.
    private fun copyShare(uri: Uri, name: String): File? {
        if ("file".equals(uri.scheme, ignoreCase = true) && isAppFile(uri)) return null
        val dir = File(File(cacheDir, SHARE_FOLDER), UUID.randomUUID().toString())
        if (!dir.mkdirs()) return null
        val out = File(dir, name)
        if (copyAtMost(uri, out, MAX_SHARE_BYTES) == Copied.OK) return out
        out.delete()
        dir.delete()
        return null
    }

    /// Whether the file [uri] names lies in the app's own data directory
    /// (or cannot be told apart from one).
    private fun isAppFile(uri: Uri): Boolean {
        val path = uri.path ?: return true
        return try {
            val target = File(path).canonicalPath
            val own = File(applicationInfo.dataDir).canonicalPath
            target == own || target.startsWith("$own/")
        } catch (e: Exception) {
            true
        }
    }

    /// Folders whose copy Dart has read and deleted.
    private fun clearEmptyShareFolders() {
        File(cacheDir, SHARE_FOLDER).listFiles()?.forEach {
            if (it.isDirectory && it.list()?.isEmpty() == true) it.delete()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Settings › 照片 › 后台扫描 asks whether the user set the app to
        // 电池 › 受限 (App info › App battery usage › Restricted). In that
        // bucket Android parks the periodic WorkManager job — the
        // closed-app photo scan AND the nightly summary — for days, and
        // nothing else in the app could explain the frozen 尚未运行. Only
        // the UI engine goes through this activity; the background engine
        // never needs the answer. No manifest permission is involved.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBackgroundRestricted" -> result.success(isBackgroundRestricted())
                    else -> result.notImplemented()
                }
            }
        // Settings › Your Data › Import › Choose File… (1.7.0): the system
        // file picker (Storage Access Framework), several files at once.
        // Each picked file is copied into the app's cache, and Dart deletes
        // the copy after the import. No storage permission is involved:
        // ACTION_OPEN_DOCUMENT grants access to the picked files only.
        // pickImages: Log and Leftovers through the system Photo Picker,
        // which grants the picked photos only, with no permission at all.
        // saveFile: Export › Save to device, written where the user picks
        // (ACTION_CREATE_DOCUMENT grants that one document only).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> pickFiles(result)
                    "pickImages" -> pickImages(
                        (call.argument<Any?>("max") as? Number)?.toInt() ?: 1,
                        result,
                    )
                    "saveFile" -> saveFile(
                        call.argument<Any?>("path") as? String,
                        call.argument<Any?>("name") as? String,
                        call.argument<Any?>("mime") as? String,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun isBackgroundRestricted(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return am.isBackgroundRestricted
    }

    private fun pickFiles(result: MethodChannel.Result) {
        if (pickReply != null) {
            result.success(mapOf("status" to "busy"))
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            // Many file managers label .json as octet-stream or text.
            type = "*/*"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf("application/json", "text/plain", "application/octet-stream"),
            )
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        pickReply = result
        try {
            startActivityForResult(intent, PICK_REQUEST)
        } catch (e: ActivityNotFoundException) {
            pickReply = null
            result.success(mapOf("status" to "unavailable"))
        }
    }

    /// The system Photo Picker through AndroidX's contracts, run by hand:
    /// FlutterActivity is a plain Activity, with no
    /// registerForActivityResult. Where the picker is missing the contract
    /// itself falls back (Play services' backported picker, see the
    /// ModuleDependencies entry in AndroidManifest.xml, else
    /// ACTION_OPEN_DOCUMENT). [requested] is clamped to 1 and to the
    /// picker's own limit. Answers {status, items, tooBig, failed} once the
    /// picks are copied (onPhotosPicked); busy while a pick is open.
    private fun pickImages(requested: Int, result: MethodChannel.Result) {
        if (photoPickReply != null) {
            result.success(photoPickAnswer("busy"))
            return
        }
        val max = requested.coerceIn(1, pickLimit())
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        val intent = try {
            if (max == 1) ActivityResultContracts.PickVisualMedia().createIntent(this, request)
            else ActivityResultContracts.PickMultipleVisualMedia(max).createIntent(this, request)
        } catch (e: Exception) {
            result.success(photoPickAnswer("unavailable"))
            return
        }
        photoPickReply = result
        photoPickMax = max
        try {
            startActivityForResult(intent, PHOTO_PICK_REQUEST)
        } catch (e: Exception) {
            photoPickReply = null
            result.success(photoPickAnswer("unavailable"))
        }
    }

    /// The system picker's most photos per pick (its contract refuses
    /// more): where AndroidX uses it, API 33+ or R extension 2+. Its
    /// fallbacks take any number.
    @SuppressLint("NewApi")
    private fun pickLimit(): Int =
        if (Build.VERSION.SDK_INT >= 33 ||
            (Build.VERSION.SDK_INT >= 30 && SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) >= 2)
        ) MediaStore.getPickImagesMaxLimit().coerceAtLeast(1) else Int.MAX_VALUE

    private fun photoPickAnswer(
        status: String,
        items: List<Map<String, Any>> = emptyList(),
        tooBig: Int = 0,
        failed: Int = 0,
    ): Map<String, Any> =
        mapOf("status" to status, "items" to items, "tooBig" to tooBig, "failed" to failed)

    /// Copies each picked photo to cacheDir/PICKED_PHOTO_FOLDER/<uuid>/<name>
    /// (the folder emptied first: Dart has read and deleted the last
    /// pick's copies by now), under the share cap, with its capture time
    /// when the provider gives one. Off the UI thread; the call stays open
    /// (busy) until the answer, so a second pick cannot empty the folder
    /// while this one writes it. The grants last only while the app runs,
    /// hence the copies.
    private fun onPhotosPicked(resultCode: Int, data: Intent?) {
        val reply = photoPickReply ?: return
        val uris: List<Uri> = try {
            if (photoPickMax == 1) {
                listOfNotNull(ActivityResultContracts.PickVisualMedia().parseResult(resultCode, data))
            } else {
                ActivityResultContracts.PickMultipleVisualMedia(photoPickMax).parseResult(resultCode, data)
            }
        } catch (e: Exception) {
            emptyList()
        }
        if (resultCode != Activity.RESULT_OK || uris.isEmpty()) {
            photoPickReply = null
            reply.success(photoPickAnswer("cancelled"))
            return
        }
        Thread {
            val items = mutableListOf<Map<String, Any>>()
            var tooBig = 0
            var failed = 0
            val root = File(cacheDir, PICKED_PHOTO_FOLDER)
            try {
                root.deleteRecursively()
                root.mkdirs()
            } catch (e: Exception) {
            }
            uris.forEach { uri ->
                try {
                    val name = shareName(uri)
                        ?: if ("content".equals(uri.scheme, ignoreCase = true)) fallbackShareName(uri) else null
                    val dir = File(root, UUID.randomUUID().toString())
                    if (name == null || !dir.mkdirs()) {
                        failed++
                        return@forEach
                    }
                    val out = File(dir, name)
                    when (copyAtMost(uri, out, MAX_SHARE_BYTES)) {
                        Copied.OK -> {
                            val item = mutableMapOf<String, Any>("path" to out.absolutePath, "name" to name)
                            dateTaken(uri)?.let { item["dateTakenMs"] = it }
                            items.add(item)
                        }
                        Copied.TOO_BIG -> {
                            out.delete()
                            dir.delete()
                            tooBig++
                        }
                        Copied.FAILED -> {
                            out.delete()
                            dir.delete()
                            failed++
                        }
                    }
                } catch (e: Exception) {
                    failed++
                }
            }
            runOnUiThread {
                if (photoPickReply === reply) photoPickReply = null
                reply.success(photoPickAnswer("ok", items, tooBig, failed))
            }
        }.start()
    }

    /// When [uri]'s photo was taken (ms since the epoch), as the provider
    /// reports it; null when it does not (a document provider, say).
    private fun dateTaken(uri: Uri): Long? = try {
        contentResolver.query(uri, arrayOf(MediaStore.MediaColumns.DATE_TAKEN), null, null, null)
            ?.use { c ->
                val i = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
                if (c.moveToFirst() && i >= 0 && !c.isNull(i)) c.getLong(i).takeIf { it > 0 } else null
            }
    } catch (e: Exception) {
        null
    }

    /// Export › Save to device: asks the user where to save [name] (the
    /// system's create-document screen, suggested name and type [mime]),
    /// then copies the file at [path] there (onSaveTargetPicked). Only a
    /// file whose real path lies in the app's cache, where the export is
    /// written, is ever copied: never the database or anything else the
    /// app keeps. Answers {status: ok|cancelled|busy|unavailable|failed}.
    private fun saveFile(path: String?, name: String?, mime: String?, result: MethodChannel.Result) {
        if (saveReply != null) {
            result.success(saveAnswer("busy"))
            return
        }
        val source = cachedFile(path)
        if (source == null) {
            result.success(saveAnswer("failed"))
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mime?.takeIf { it.isNotBlank() } ?: "application/octet-stream"
            putExtra(Intent.EXTRA_TITLE, baseName(name) ?: source.name)
        }
        saveReply = result
        saveSource = source
        try {
            startActivityForResult(intent, SAVE_REQUEST)
        } catch (e: Exception) {
            saveReply = null
            saveSource = null
            result.success(saveAnswer("unavailable"))
        }
    }

    private fun saveAnswer(status: String): Map<String, Any> = mapOf("status" to status)

    /// The regular file at [path] when its real path (symbolic links
    /// resolved) lies inside the app's cache directory; null otherwise.
    private fun cachedFile(path: String?): File? {
        if (path.isNullOrEmpty()) return null
        return try {
            val cache = cacheDir.canonicalFile
            val file = File(path).canonicalFile
            if (file.path.startsWith(cache.path + File.separator) && file.isFile) file else null
        } catch (e: Exception) {
            null
        }
    }

    /// Copies the file saveFile checked into the document the user just
    /// created, off the UI thread (checked again first). A failed copy
    /// removes that document rather than leave an empty or partial file.
    private fun onSaveTargetPicked(resultCode: Int, data: Intent?) {
        val reply = saveReply ?: return
        val uri = data?.data
        val source = saveSource
        if (resultCode != Activity.RESULT_OK || uri == null || source == null) {
            saveReply = null
            saveSource = null
            reply.success(saveAnswer("cancelled"))
            return
        }
        Thread {
            val ok = try {
                val file = cachedFile(source.path) ?: throw IllegalStateException()
                val out = try {
                    contentResolver.openOutputStream(uri, "wt")
                } catch (e: Exception) {
                    null
                } ?: contentResolver.openOutputStream(uri, "w") // new, so empty
                out?.use { o -> file.inputStream().use { it.copyTo(o, 64 * 1024) } } != null
            } catch (e: Exception) {
                false
            }
            if (!ok) {
                try {
                    DocumentsContract.deleteDocument(contentResolver, uri)
                } catch (e: Exception) {
                }
            }
            runOnUiThread {
                if (saveReply === reply) {
                    saveReply = null
                    saveSource = null
                }
                reply.success(if (ok) saveAnswer("ok") else saveAnswer("failed"))
            }
        }.start()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            PICK_REQUEST -> onFilesPicked(resultCode, data)
            PHOTO_PICK_REQUEST -> onPhotosPicked(resultCode, data)
            SAVE_REQUEST -> onSaveTargetPicked(resultCode, data)
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    private fun onFilesPicked(resultCode: Int, data: Intent?) {
        val reply = pickReply ?: return
        if (resultCode != Activity.RESULT_OK || data == null) {
            pickReply = null
            reply.success(mapOf("status" to "cancelled"))
            return
        }
        val uris = mutableListOf<Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        // Copying a few MB off the UI thread; the reply goes back on it.
        // The call stays open until then (pickFiles answers busy): every
        // pick copies into the same folder, which a second pick would
        // empty while this one still writes it. Dart keeps Import busy
        // from the pick until it has read the copies.
        Thread {
            val dir = File(cacheDir, "picked").apply {
                deleteRecursively()
                mkdirs()
            }
            val paths = mutableListOf<String>()
            var tooBig = 0
            var failed = 0
            uris.forEachIndexed { i, uri ->
                val out = File(dir, "picked-$i.json")
                when (copyAtMost(uri, out, MAX_BYTES)) {
                    Copied.OK -> paths.add(out.absolutePath)
                    Copied.TOO_BIG -> {
                        out.delete()
                        tooBig++
                    }
                    Copied.FAILED -> {
                        out.delete()
                        failed++
                    }
                }
            }
            runOnUiThread {
                if (pickReply === reply) pickReply = null
                reply.success(
                    mapOf("status" to "ok", "paths" to paths, "tooBig" to tooBig, "failed" to failed),
                )
            }
        }.start()
    }

    /// What copying one picked or shared file came to.
    private enum class Copied { OK, TOO_BIG, FAILED }

    /// Copies [uri] to [out]. TOO_BIG: a file over [limit] bytes, by its
    /// declared size when the provider gives one, and by counting while
    /// copying in any case. FAILED: it could not be read or written (a
    /// cloud file that cannot be fetched now, a grant the provider
    /// refuses, a full disk), whatever its size. A provider that answers
    /// without a size column is copied and counted.
    private fun copyAtMost(uri: Uri, out: File, limit: Long): Copied {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                val i = c.getColumnIndex(OpenableColumns.SIZE)
                if (i >= 0 && c.moveToFirst() && !c.isNull(i) && c.getLong(i) > limit) return Copied.TOO_BIG
            }
            val input = contentResolver.openInputStream(uri) ?: return Copied.FAILED
            input.use { inp ->
                out.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = inp.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > limit) return Copied.TOO_BIG
                        o.write(buf, 0, n)
                    }
                }
            }
            return Copied.OK
        } catch (e: Exception) {
            return Copied.FAILED
        }
    }

    private companion object {
        const val CHANNEL = "dev.calorietracker/background"
        const val FILES_CHANNEL = "dev.calorietracker/files"
        const val PICK_REQUEST = 4207
        const val PHOTO_PICK_REQUEST = 4208
        const val SAVE_REQUEST = 4209
        const val MAX_BYTES = 100L * 1024 * 1024

        /// Under cacheDir; share_intake.dart's androidShareFolderName.
        const val SHARE_FOLDER = "shared_photos"

        /// Under cacheDir: pickImages' copies, one folder each.
        const val PICKED_PHOTO_FOLDER = "picked_photos"

        /// Dart's maxPhotoBytes: share intake refuses anything larger.
        const val MAX_SHARE_BYTES = 25L * 1024 * 1024

        /// share_plus's FileProvider authority after the package name
        /// (its AndroidManifest.xml: ${applicationId}.flutter.share_provider).
        const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"
    }
}
