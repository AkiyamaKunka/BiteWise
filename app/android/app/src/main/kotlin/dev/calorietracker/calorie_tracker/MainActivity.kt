package dev.calorietracker.calorie_tracker

import android.app.Activity
import android.app.ActivityManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    /// The open pickFiles call, answered from onActivityResult.
    private var pickReply: MethodChannel.Result? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILES_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> pickFiles(result)
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val reply = pickReply ?: return
        pickReply = null
        if (resultCode != Activity.RESULT_OK || data == null) {
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
                reply.success(
                    mapOf("status" to "ok", "paths" to paths, "tooBig" to tooBig, "failed" to failed),
                )
            }
        }.start()
    }

    /// What copying one picked file came to.
    private enum class Copied { OK, TOO_BIG, FAILED }

    /// Copies [uri] to [out]. TOO_BIG: a file over [limit] bytes, by its
    /// declared size when the provider gives one, and by counting while
    /// copying in any case. FAILED: it could not be read or written (a
    /// cloud file that cannot be fetched now, a grant the provider
    /// refuses, a full disk), whatever its size.
    private fun copyAtMost(uri: Uri, out: File, limit: Long): Copied {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0) && c.getLong(0) > limit) return Copied.TOO_BIG
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
        const val MAX_BYTES = 100L * 1024 * 1024
    }
}
