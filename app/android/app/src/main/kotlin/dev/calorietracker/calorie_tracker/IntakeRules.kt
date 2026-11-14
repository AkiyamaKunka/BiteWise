package dev.calorietracker.calorie_tracker

import android.content.Intent
import java.io.File

/// MainActivity's decisions, kept free of Android objects so the JVM unit
/// tests (src/test, `./gradlew :app:testDebugUnitTest`, run by
/// .github/workflows/mobile-build.yml) can run them for real. MainActivity
/// only wires them to the platform, and manifest_gate_test pins that
/// wiring. (Intent's flag is a compile-time constant: no Android class is
/// loaded.)
internal object IntakeRules {
    /// Whether the launch intent was delivered before: the activity is
    /// recreated (saved state: Android stopped its process while it sat in
    /// the background) or relaunched from Recents. Either way it still
    /// carries the intent that first started its task.
    fun isRedelivery(hasSavedState: Boolean, flags: Int): Boolean =
        hasSavedState || (flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0

    /// share_plus's FileProvider authority after the package name (its
    /// AndroidManifest.xml: ${applicationId}.flutter.share_provider).
    const val SHARE_OUT_AUTHORITY_SUFFIX = ".flutter.share_provider"

    /// Whether a stream with [scheme] and [authority] is one of the app's
    /// own share-out files (Today's day image, an Export): Chopstats is a
    /// target in its own sharesheet, and such a file is no meal.
    fun isOwnShareOut(scheme: String?, authority: String?, packageName: String): Boolean =
        "content".equals(scheme, ignoreCase = true) &&
            "$packageName$SHARE_OUT_AUTHORITY_SUFFIX".equals(authority, ignoreCase = true)

    /// Whether [path] is [dir] or lies inside it once both are resolved
    /// (symbolic links included). True when that cannot be told: callers
    /// use it to refuse, so an unknown fails closed.
    fun liesIn(dir: File, path: String?): Boolean {
        if (path == null) return true
        return try {
            val target = File(path).canonicalPath
            val own = dir.canonicalPath
            target == own || target.startsWith(own + File.separator)
        } catch (e: Exception) {
            true
        }
    }

    /// The regular file at [path] when its real path (symbolic links
    /// resolved) lies strictly inside [dir]; null for anything else.
    fun regularFileIn(dir: File, path: String?): File? {
        if (path.isNullOrEmpty()) return null
        return try {
            val root = dir.canonicalFile
            val file = File(path).canonicalFile
            if (file.path.startsWith(root.path + File.separator) && file.isFile) file else null
        } catch (e: Exception) {
            null
        }
    }

    /// The most photos one pick returns, whatever the picker allows: each
    /// is copied (up to 25 MB) before the call is answered.
    const val MAX_PICK = 100

    /// [requested] clamped to 1, to MAX_PICK, and to [systemLimit] (the
    /// system picker's own limit, which its contract enforces; null where
    /// there is no system picker).
    fun pickMax(requested: Int, systemLimit: Int?): Int =
        requested.coerceIn(1, minOf(systemLimit ?: MAX_PICK, MAX_PICK).coerceAtLeast(1))

    /// The first [max] of [picked]: the ACTION_OPEN_DOCUMENT fallback
    /// ignores the picker's maximum.
    fun <T> firstPicks(picked: List<T>, max: Int): List<T> = picked.take(max.coerceAtLeast(1))

    const val DAY_MS = 24L * 60 * 60 * 1000

    /// Removes what earlier picks left under [root]: empty folders (Dart
    /// read and deleted their copy), and folders or files untouched for
    /// [maxAgeMs] (a pick whose app was stopped before Dart read it).
    /// Never [root] itself, and never a copy younger than [maxAgeMs].
    fun tidyPickFolders(root: File, nowMs: Long, maxAgeMs: Long = DAY_MS) {
        root.listFiles()?.forEach { entry ->
            try {
                val children = if (entry.isDirectory) entry.listFiles() ?: return@forEach else emptyArray()
                val newest = (children.map { it.lastModified() } + entry.lastModified()).maxOrNull() ?: 0L
                val empty = entry.isDirectory && children.isEmpty()
                if (empty || nowMs - newest > maxAgeMs) entry.deleteRecursively()
            } catch (e: Exception) {
                // The next pick tries again.
            }
        }
    }

    /// What a create-document result leads to: CANCEL when nothing was
    /// created, COPY the checked source into it, DISCARD the new (empty)
    /// document when there is no source to copy (the call that asked for
    /// it is gone and its state with it).
    enum class SaveStep { CANCEL, COPY, DISCARD }

    fun saveStep(resultOk: Boolean, hasTarget: Boolean, hasSource: Boolean): SaveStep = when {
        !resultOk || !hasTarget -> SaveStep.CANCEL
        hasSource -> SaveStep.COPY
        else -> SaveStep.DISCARD
    }

    /// The modes a save opens its new document with, in order. Both
    /// truncate; plain "w" may leave a longer file's old bytes at the end
    /// on some providers, so it is never tried: no stream is a failed save.
    val SAVE_MODES = listOf("wt", "rwt")

    /// The first stream [open] gives for one of [modes]; a mode that
    /// throws or gives null is skipped. Null when none does.
    fun <T : Any> firstStream(modes: List<String>, open: (String) -> T?): T? {
        for (mode in modes) {
            try {
                open(mode)?.let { return it }
            } catch (e: Exception) {
                // The next mode.
            }
        }
        return null
    }

    /// Opens the first of [pages] that [open] accepts (it throws for one
    /// the device lacks). False when none was opened.
    fun <T> openFirst(pages: List<T>, open: (T) -> Unit): Boolean {
        for (page in pages) {
            try {
                open(page)
                return true
            } catch (e: Exception) {
                // Not on this device: the next page.
            }
        }
        return false
    }
}

/// One method call at a time, answered exactly once: MethodChannel.Result
/// throws on a second answer, and a call never answered leaves its Dart
/// caller waiting for good (and, here, every later call busy). [open]
/// numbers each call; only the open call's number can answer it, once.
/// Main thread only.
internal class SingleCall<V> {
    private var pending: ((V) -> Unit)? = null
    private var current = 0L

    val isOpen: Boolean get() = pending != null

    /// Opens a call that [reply] answers; null, opening nothing, while
    /// another call is open.
    fun open(reply: (V) -> Unit): Long? {
        if (pending != null) return null
        pending = reply
        current += 1
        return current
    }

    /// Answers call [call] with [value] and closes it. False, sending
    /// nothing, when [call] is not the open call (already answered, or
    /// never opened).
    fun answer(call: Long, value: V): Boolean {
        val reply = pending ?: return false
        if (call != current) return false
        pending = null
        reply(value)
        return true
    }
}
