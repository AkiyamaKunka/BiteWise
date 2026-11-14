package dev.calorietracker.calorie_tracker

import android.content.Intent
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/// MainActivity's decisions on the JVM (IntakeRules.kt). Run with
/// `./gradlew :app:testDebugUnitTest` from app/android; mobile-build.yml
/// runs it on every pull request.
class IntakeRulesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    // --- A launch intent seen before reaches no plugin (share replay).

    @Test
    fun aRecreatedActivityIsARedelivery() {
        assertTrue(IntakeRules.isRedelivery(hasSavedState = true, flags = 0))
    }

    @Test
    fun aLaunchFromRecentsIsARedelivery() {
        assertEquals(0x00100000, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertTrue(IntakeRules.isRedelivery(false, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY))
        assertTrue(IntakeRules.isRedelivery(false, Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY or 0x10000000))
    }

    @Test
    fun aFreshLaunchIsNot() {
        assertFalse(IntakeRules.isRedelivery(false, 0))
        // FLAG_ACTIVITY_NEW_TASK | FLAG_GRANT_READ_URI_PERMISSION: a share.
        assertFalse(IntakeRules.isRedelivery(false, 0x10000000 or 0x00000001))
    }

    // --- The app's own share-out files are no meal.

    @Test
    fun shareOutFilesAreRecognisedByAuthority() {
        val pkg = "dev.calorietracker.calorie_tracker"
        assertTrue(IntakeRules.isOwnShareOut("content", "$pkg.flutter.share_provider", pkg))
        assertTrue(IntakeRules.isOwnShareOut("CONTENT", "$pkg.FLUTTER.share_provider", pkg))
        // Any other provider, or any other scheme, is a share like any other.
        assertFalse(IntakeRules.isOwnShareOut("content", "media", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "com.google.android.apps.photos.contentprovider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "other.app.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", null, pkg))
        assertFalse(IntakeRules.isOwnShareOut("file", "$pkg.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut(null, "$pkg.flutter.share_provider", pkg))
        assertFalse(IntakeRules.isOwnShareOut("content", "content", pkg))
    }

    // --- Only a regular file in the cache is ever saved out.

    private fun layout(): Triple<File, File, File> {
        val data = tmp.newFolder("data")
        val cache = File(data, "cache").apply { mkdirs() }
        val db = File(data, "databases/calorie_tracker.db").apply {
            parentFile!!.mkdirs()
            writeText("meals")
        }
        return Triple(data, cache, db)
    }

    @Test
    fun aFileInTheCacheIsSaved() {
        val (_, cache, _) = layout()
        val export = File(cache, "chopstats-2026-11-13.json").apply { writeText("{}") }
        assertEquals(export.canonicalFile, IntakeRules.regularFileIn(cache, export.path))
        val nested = File(cache, "a/b.json").apply {
            parentFile!!.mkdirs()
            writeText("{}")
        }
        assertEquals(nested.canonicalFile, IntakeRules.regularFileIn(cache, nested.path))
    }

    @Test
    fun nothingOutsideTheCacheIsSaved() {
        val (data, cache, db) = layout()
        assertNull(IntakeRules.regularFileIn(cache, db.path))
        assertNull(IntakeRules.regularFileIn(cache, "${cache.path}/../databases/calorie_tracker.db"))
        assertNull(IntakeRules.regularFileIn(cache, "${cache.path}_x/a.json"))
        assertNull(IntakeRules.regularFileIn(cache, cache.path))
        assertNull(IntakeRules.regularFileIn(cache, File(data, "cache").path + "/"))
        assertNull(IntakeRules.regularFileIn(cache, null))
        assertNull(IntakeRules.regularFileIn(cache, ""))
        // A folder or a missing file in the cache is no regular file.
        File(cache, "dir").mkdirs()
        assertNull(IntakeRules.regularFileIn(cache, File(cache, "dir").path))
        assertNull(IntakeRules.regularFileIn(cache, File(cache, "missing.json").path))
    }

    @Test
    fun aLinkInTheCacheToTheDatabaseIsNotSaved() {
        val (_, cache, db) = layout()
        val link = File(cache, "export.json")
        try {
            Files.createSymbolicLink(link.toPath(), db.toPath())
        } catch (e: IOException) {
            return // no symbolic links on this file system
        } catch (e: UnsupportedOperationException) {
            return
        }
        assertNull(IntakeRules.regularFileIn(cache, link.path))
    }

    // --- A file:// pick or share inside the app's own data is refused.

    @Test
    fun appFilesAreRecognisedAfterResolving() {
        val (data, cache, db) = layout()
        assertTrue(IntakeRules.liesIn(data, db.path))
        assertTrue(IntakeRules.liesIn(data, data.path))
        assertTrue(IntakeRules.liesIn(data, "${cache.path}/../databases/calorie_tracker.db"))
        assertTrue(IntakeRules.liesIn(data, null))
        val outside = tmp.newFile("DCIM-photo.jpg")
        assertFalse(IntakeRules.liesIn(data, outside.path))
        assertFalse(IntakeRules.liesIn(data, "${data.path}_other/x.jpg"))
    }

    // --- How many photos one pick returns.

    @Test
    fun theMaximumIsClamped() {
        assertEquals(1, IntakeRules.pickMax(0, null))
        assertEquals(1, IntakeRules.pickMax(-5, 100))
        assertEquals(1, IntakeRules.pickMax(1, 100))
        assertEquals(8, IntakeRules.pickMax(8, 100))
        // The system picker's own limit (its contract refuses more).
        assertEquals(20, IntakeRules.pickMax(50, 20))
        // No system picker: still at most MAX_PICK.
        assertEquals(100, IntakeRules.MAX_PICK)
        assertEquals(100, IntakeRules.pickMax(Int.MAX_VALUE, null))
        assertEquals(100, IntakeRules.pickMax(500, 1000))
        assertEquals(1, IntakeRules.pickMax(5, 0))
    }

    @Test
    fun aFallbackPickerIsCutToTheMaximum() {
        val picked = (1..150).toList()
        assertEquals(listOf(1), IntakeRules.firstPicks(picked, 1))
        assertEquals((1..100).toList(), IntakeRules.firstPicks(picked, 100))
        assertEquals(listOf(1, 2), IntakeRules.firstPicks(listOf(1, 2), 5))
        assertEquals(listOf(1), IntakeRules.firstPicks(picked, 0))
    }

    // --- picked_photos: only what earlier picks left.

    @Test
    fun tidyingKeepsFreshCopiesAndRemovesEmptyAndOldFolders() {
        val root = tmp.newFolder("picked_photos")
        val now = System.currentTimeMillis()
        val fresh = File(root, "fresh").apply { mkdirs() }
        File(fresh, "IMG_1.jpg").writeText("x")
        val empty = File(root, "empty").apply { mkdirs() }
        val old = File(root, "old").apply { mkdirs() }
        val oldCopy = File(old, "IMG_0.jpg").apply { writeText("x") }
        val longAgo = now - IntakeRules.DAY_MS - 60_000
        oldCopy.setLastModified(longAgo)
        old.setLastModified(longAgo)
        IntakeRules.tidyPickFolders(root, now)
        assertTrue(root.isDirectory)
        assertTrue(File(fresh, "IMG_1.jpg").isFile)
        assertFalse(empty.exists())
        assertFalse(old.exists())
        // Nothing to tidy, or no folder at all, is no error.
        IntakeRules.tidyPickFolders(root, now)
        IntakeRules.tidyPickFolders(File(root, "missing"), now)
        assertTrue(File(fresh, "IMG_1.jpg").isFile)
    }

    // --- A create-document result.

    @Test
    fun aSaveResultCopiesCancelsOrDiscards() {
        assertEquals(IntakeRules.SaveStep.COPY, IntakeRules.saveStep(resultOk = true, hasTarget = true, hasSource = true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(false, true, true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(true, false, true))
        assertEquals(IntakeRules.SaveStep.CANCEL, IntakeRules.saveStep(false, false, false))
        // The document exists but nothing is left to copy into it.
        assertEquals(IntakeRules.SaveStep.DISCARD, IntakeRules.saveStep(true, true, false))
    }

    @Test
    fun aSaveOpensOnlyTruncatingModes() {
        assertEquals(listOf("wt", "rwt"), IntakeRules.SAVE_MODES)
        val tried = mutableListOf<String>()
        val stream = IntakeRules.firstStream(IntakeRules.SAVE_MODES) { mode ->
            tried.add(mode)
            if (mode == "wt") throw UnsupportedOperationException("no wt") else "stream:$mode"
        }
        assertEquals("stream:rwt", stream)
        assertEquals(listOf("wt", "rwt"), tried)
        assertEquals("stream:wt", IntakeRules.firstStream(IntakeRules.SAVE_MODES) { "stream:$it" })
        // No mode works: no stream (a failed save), and never plain "w".
        tried.clear()
        assertNull(IntakeRules.firstStream<String>(IntakeRules.SAVE_MODES) { tried.add(it); null })
        assertEquals(listOf("wt", "rwt"), tried)
    }

    // --- The notification-settings link.

    @Test
    fun aSettingsPageCountsOnlyWhenItOpened() {
        val opened = mutableListOf<String>()
        assertTrue(IntakeRules.openFirst(listOf("notifications", "app info")) { opened.add(it) })
        assertEquals(listOf("notifications"), opened)
        opened.clear()
        assertTrue(
            IntakeRules.openFirst(listOf("notifications", "app info")) {
                if (it == "notifications") throw IllegalStateException("not on this device")
                opened.add(it)
            },
        )
        assertEquals(listOf("app info"), opened)
        assertFalse(IntakeRules.openFirst(listOf("a", "b")) { throw IllegalStateException() })
        assertFalse(IntakeRules.openFirst(emptyList<String>()) { opened.add(it) })
    }

    // --- One call at a time, answered once.

    @Test
    fun aCallIsAnsweredExactlyOnce() {
        val calls = SingleCall<String>()
        val answers = mutableListOf<String>()
        assertFalse(calls.isOpen)
        val call = calls.open { answers.add(it) }!!
        assertTrue(calls.isOpen)
        assertTrue(calls.answer(call, "cancelled"))
        assertFalse(calls.isOpen)
        // A second answer, by mistake, sends nothing (Result would throw).
        assertFalse(calls.answer(call, "ok"))
        assertEquals(listOf("cancelled"), answers)
    }

    @Test
    fun aSecondCallIsRefusedWhileOneIsOpenAndAcceptedAfter() {
        val calls = SingleCall<String>()
        val first = mutableListOf<String>()
        val second = mutableListOf<String>()
        val a = calls.open { first.add(it) }!!
        assertNull(calls.open { second.add(it) })
        assertTrue(calls.answer(a, "ok"))
        val b = calls.open { second.add(it) }!!
        // The finished call's number cannot answer the new one.
        assertFalse(calls.answer(a, "late"))
        assertTrue(calls.answer(b, "cancelled"))
        assertEquals(listOf("ok"), first)
        assertEquals(listOf("cancelled"), second)
    }
}
