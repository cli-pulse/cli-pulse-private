package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException

/**
 * 1.63 D7: SecurePrefs deletes the encrypted preferences only when a second open, after a
 * pause, shows their keyset no longer authenticates; only after recording a reset intent that
 * outlives the deletion; and TokenStore handles each reset once. The fakes stand in for
 * EncryptedSharedPreferences.create and Context.deleteSharedPreferences; the real FileIntent
 * runs on a temporary folder. Nothing here touches a real Keystore.
 */
class SecurePrefsTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val healthy = InMemorySharedPreferences().also { it.edit().putString("k", "v").commit() }
    private val fresh = InMemorySharedPreferences()

    /** An intent in memory; the real FileIntent is tested on disk below. */
    private class FakeIntent(val order: MutableList<String>) : SecurePrefs.ResetIntent {
        var stored: String? = null
        var recordThrows = false
        var tokenThrows = false
        var clearResult = true
        override fun token(): String? {
            if (tokenThrows) throw IOException("cannot read the intent")
            return stored
        }
        override fun record(): String {
            order += "intent"
            if (recordThrows) throw IOException("disk full")
            return (stored ?: "token-1").also { stored = it }
        }
        override fun clear(): Boolean {
            order += "clear"
            if (clearResult) stored = null
            return clearResult
        }
    }

    /** Each call to create() takes the next outcome: an exception to throw or prefs to return. */
    private class Script(vararg outcomes: Any) {
        private val queue = ArrayDeque(outcomes.toList())
        val order = mutableListOf<String>()
        val intent = FakeIntent(order)
        var fileDeleteResult = true
        var fileDeleteThrows = false

        fun create(): SharedPreferences {
            order += "create"
            return when (val next = queue.removeFirst()) {
                is Exception -> throw next
                is SharedPreferences -> next
                else -> error("bad script")
            }
        }

        fun deleteFile(): Boolean {
            order += "file"
            if (fileDeleteThrows) throw SecurityException("cannot delete")
            return fileDeleteResult
        }

        fun open() = SecurePrefs.open(::create, ::deleteFile, intent, pause = { order += "pause" })
    }

    /** What Tink throws when the keyset was encrypted under a key that is gone. */
    private fun badTag() = AEADBadTagException("message authentication failed")

    private inline fun <reified T : Throwable> assertThrowsSame(expected: Throwable, block: () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (e: Throwable) {
            assertTrue("got $e", e is T)
            assertSame(expected, e)
        }
    }

    // ── SecurePrefs.open ─────────────────────────────────────────────────

    @Test
    fun `a healthy store opens once and nothing is deleted`() {
        val s = Script(healthy)
        val opened = s.open()
        assertSame(healthy, opened.prefs)
        assertNull(opened.resetToken)
        assertEquals(listOf("create"), s.order)
        assertEquals("v", opened.prefs.getString("k", null))
    }

    @Test
    fun `a failure followed by success pauses, keeps the store and deletes nothing`() {
        for (transient in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"), badTag())) {
            val s = Script(transient, healthy)
            val opened = s.open()
            assertSame("after $transient", healthy, opened.prefs)
            assertNull(opened.resetToken)
            assertEquals("after $transient", listOf("create", "pause", "create"), s.order)
        }
    }

    @Test
    fun `an unreadable keyset twice records the intent, then deletes the file, then opens empty`() {
        val s = Script(badTag(), badTag(), fresh)
        val opened = s.open()
        assertSame(fresh, opened.prefs)
        assertEquals("token-1", opened.resetToken)
        assertEquals(listOf("create", "pause", "create", "intent", "file", "create"), s.order)
        opened.resetDone()
        assertNull(s.intent.stored)
    }

    @Test
    fun `the bad tag is found anywhere in the cause chain`() {
        val wrapped = GeneralSecurityException("keyset", IOException("read", badTag()))
        val s = Script(wrapped, wrapped, fresh)
        assertNotNull(s.open().resetToken)
        assertEquals(1, s.order.count { it == "file" })
    }

    @Test
    fun `an UnrecoverableKeyException deletes nothing`() {
        // Android also wraps passing Keystore failures in it (Codex code review r1, MUST 1).
        val wrapped = UnrecoverableKeyException("key info").apply { initCause(KeyStoreException("busy")) }
        val s = Script(wrapped, wrapped)
        assertThrowsSame<UnrecoverableKeyException>(wrapped) { s.open() }
        assertEquals(listOf("create", "pause", "create"), s.order)
    }

    @Test
    fun `any failure without a bad tag is thrown after the retry and nothing is deleted`() {
        for (other in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"), InvalidKeyException("x"))) {
            val s = Script(other, other)
            assertThrowsSame<Exception>(other) { s.open() }
            assertEquals("for $other", listOf("create", "pause", "create"), s.order)
        }
    }

    @Test
    fun `a bug is thrown at once, on either attempt, and nothing is recorded or deleted`() {
        val bug = IllegalStateException("bug")
        listOf(Script(bug), Script(badTag(), bug)).forEach { s ->
            assertThrowsSame<IllegalStateException>(bug) { s.open() }
            assertFalse(s.order.contains("intent"))
            assertFalse(s.order.contains("file"))
        }
    }

    @Test
    fun `a failure on the open after the deletion is thrown and the intent stays for the next start`() {
        val third = IOException("still broken")
        val s = Script(badTag(), badTag(), third)
        assertThrowsSame<IOException>(third) { s.open() }
        assertEquals("token-1", s.intent.stored)
    }

    @Test
    fun `an intent that could not be recorded stops the recovery before the deletion`() {
        val failure = badTag()
        val s = Script(badTag(), failure).apply { intent.recordThrows = true }
        assertThrowsSame<AEADBadTagException>(failure) { s.open() }
        assertEquals(listOf("create", "pause", "create", "intent"), s.order)
    }

    @Test
    fun `a file that could not be deleted, or a deletion that throws, stops the recovery`() {
        for (throws in listOf(false, true)) {
            val failure = badTag()
            val s = Script(badTag(), failure).apply { fileDeleteResult = false; fileDeleteThrows = throws }
            assertThrowsSame<AEADBadTagException>(failure) { s.open() }
            assertEquals(listOf("create", "pause", "create", "intent", "file"), s.order)
        }
    }

    @Test
    fun `a reset left pending by an earlier start is reported on a healthy open`() {
        val s = Script(fresh).apply { intent.stored = "token-earlier" }
        val opened = s.open()
        assertEquals("token-earlier", opened.resetToken)
        assertEquals(listOf("create"), s.order)
    }

    @Test
    fun `an intent that cannot be read is not taken as no reset`() {
        val s = Script(fresh).apply { intent.tokenThrows = true }
        try {
            s.open()
            fail("an unreadable intent must not open as if no reset were pending")
        } catch (e: IOException) {
            // expected
        }
    }

    @Test
    fun `isUndecryptable is true only for a bad tag`() {
        assertTrue(SecurePrefs.isUndecryptable(badTag()))
        assertTrue(SecurePrefs.isUndecryptable(GeneralSecurityException(IOException(badTag()))))
        assertFalse(SecurePrefs.isUndecryptable(UnrecoverableKeyException("x")))
        assertFalse(SecurePrefs.isUndecryptable(KeyStoreException("x")))
        assertFalse(SecurePrefs.isUndecryptable(InvalidKeyException("x")))
        assertFalse(SecurePrefs.isUndecryptable(IOException("x")))
        assertFalse(SecurePrefs.isUndecryptable(ProviderException("x")))
    }

    // ── FileIntent on a real folder ──────────────────────────────────────

    @Test
    fun `the file intent records a token, keeps it across records, and clears`() {
        val file = File(tmp.root, SecurePrefs.RESET_INTENT_FILE)
        val intent = SecurePrefs.FileIntent(file)
        assertNull(intent.token())
        val token = intent.record()
        assertTrue(file.exists())
        assertEquals(token, intent.token())
        assertEquals("a second record keeps the same reset's token", token, intent.record())
        assertEquals(token, SecurePrefs.FileIntent(file).token())
        assertTrue(intent.clear())
        assertFalse(file.exists())
        assertNull(intent.token())
        assertTrue("clearing nothing is done", intent.clear())
    }

    @Test
    fun `an empty intent file means no reset (its write never finished, so nothing was deleted)`() {
        val file = File(tmp.root, SecurePrefs.RESET_INTENT_FILE).apply { writeText("") }
        assertNull(SecurePrefs.FileIntent(file).token())
    }

    // ── The real steps' wiring ───────────────────────────────────────────

    @Test
    fun `the real steps delete this file and keep the intent in the no-backup folder`() {
        val context = mockk<Context>()
        every { context.deleteSharedPreferences(any()) } returns true
        every { context.noBackupFilesDir } returns tmp.root

        assertTrue(SecurePrefs.deleteFileStep(context)())
        verify(exactly = 1) { context.deleteSharedPreferences("cli_pulse_secure_prefs") }

        val token = SecurePrefs.intentFor(context).record()
        assertEquals(token, File(tmp.root, "secure_prefs_reset_pending").readText())
    }

    // ── TokenStore and a reset ───────────────────────────────────────────

    private fun opened(prefs: InMemorySharedPreferences, token: String?, onDone: () -> Unit) =
        SecurePrefs.Opened(prefs, token, onDone)

    @Test
    fun `the context constructor's path carries the reset into TokenStore and marks the cache once`() {
        var done = 0
        val prefs = InMemorySharedPreferences()
        val store = TokenStore(opened(prefs, "t1") { done++ })
        assertNull(store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.state.value.teardownPending)
        assertEquals(1, done)
        // The start-up check has nothing left to add, and does not mark twice.
        assertFalse(store.markLegacyCacheForTeardownIfNeeded())
    }

    @Test
    fun `a reset already handled is not marked again, even when its intent could not be removed`() {
        val prefs = InMemorySharedPreferences()
        TokenStore(opened(prefs, "t1") {}) // handled, but say the intent file stayed
        // A later session: signed in, its marker settled, its cache written.
        val later = TokenStore(prefs.restart())
        val id = later.installSession("access", "refresh", "user")!!
        later.clearPendingIfEquals(TokenStore.LEGACY_CACHE_MARKER)
        assertNull(later.teardownPending)

        var done = 0
        val next = TokenStore(opened(prefs.restart(), "t1") { done++ })
        assertNull("the later session's cache is not marked for this old reset", next.teardownPending)
        assertEquals(id, next.sessionId)
        assertEquals("the stale intent is removed again", 1, done)
    }

    @Test
    fun `the handled reset survives a sign-out, so a stale intent never marks the next session`() {
        val prefs = InMemorySharedPreferences()
        val store = TokenStore(opened(prefs, "t1") {})
        store.clearPendingIfEquals(TokenStore.LEGACY_CACHE_MARKER)
        val a = store.installSession("access", "refresh", "user")!!
        store.endIfCurrent(a, EndReason.UserSignedOut)
        store.clearPendingIfEquals(a)

        val next = TokenStore(opened(prefs.restart(), "t1") {})
        assertNull(next.teardownPending)
    }

    @Test
    fun `a mark that did not reach disk keeps the intent, and a later re-commit makes it handled`() {
        var done = 0
        val prefs = InMemorySharedPreferences().apply { failCommits = true }
        val store = TokenStore(opened(prefs, "t1") { done++ })
        assertEquals("not removed while the mark is only in memory", 0, done)
        assertNull("nothing reached disk", TokenStore(prefs.restart()).teardownPending)

        // The coordinator's re-commit succeeds later in the same process.
        prefs.failCommits = false
        assertTrue(store.recommit())

        // Next start: the intent is still there, but the reset is handled on disk.
        val next = TokenStore(opened(prefs.restart(), "t1") { done++ })
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, next.teardownPending)
        assertEquals("removed now, and the cache was marked only once", 1, done)
    }

    @Test
    fun `an install after a reset keeps the marker for its settle`() {
        val store = TokenStore(opened(InMemorySharedPreferences(), "t1") {})
        val id = store.installSession("access", "refresh", "user")
        assertEquals(id, store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
    }

    @Test
    fun `a store opened with no reset has no marker`() {
        var done = 0
        val store = TokenStore(opened(InMemorySharedPreferences(), null) { done++ })
        assertNull(store.teardownPending)
        assertEquals(0, done)
    }

    // ── Wiring ───────────────────────────────────────────────────────────

    private fun source(name: String): String {
        val relative = "src/main/java/com/clipulse/android/data/remote/$name"
        val file = listOf(File(relative), File("android/app/$relative")).firstOrNull { it.isFile }
            ?: throw AssertionError("source not found: $relative")
        return file.readText()
    }

    @Test
    fun `the app's TokenStore opens its preferences through SecurePrefs`() {
        val tokenStore = source("TokenStore.kt")
        assertTrue("TokenStore(context) must use SecurePrefs.open(context)", tokenStore.contains("this(SecurePrefs.open(context))"))
        assertFalse("TokenStore must not open EncryptedSharedPreferences itself", tokenStore.contains("EncryptedSharedPreferences.create("))
        assertTrue(source("SecurePrefs.kt").contains("EncryptedSharedPreferences.create("))
    }
}
