package com.clipulse.android.data.remote

import android.content.SharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.InvalidKeyException
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException

/**
 * 1.63 D7: SecurePrefs deletes only what can never be read again, only after a second failure,
 * and only after recording a reset intent that outlives the deletion. The fakes stand in for
 * EncryptedSharedPreferences.create, Context.deleteSharedPreferences, the Keystore deletion and
 * the intent file; nothing here touches a real Keystore. KeyPermanentlyInvalidatedException
 * cannot be built on the JVM (an android.jar stub), so the key path is driven through the
 * injected classifier; [SecurePrefs.cause] is tested on its own.
 */
class SecurePrefsTest {

    private val healthy = InMemorySharedPreferences().also { it.edit().putString("k", "v").commit() }
    private val fresh = InMemorySharedPreferences()

    /** Each call to create() takes the next outcome: an exception to throw or prefs to return. */
    private class Script(vararg outcomes: Any) {
        private val queue = ArrayDeque(outcomes.toList())
        var creates = 0
        var fileDeleteResult = true
        var keyDeleteResult = true
        var intentRecordResult = true
        var fileDeleteThrows = false
        var intentPending = false
        val order = mutableListOf<String>()

        fun create(): SharedPreferences {
            creates++
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

        fun deleteKey(): Boolean { order += "key"; return keyDeleteResult }

        val intent = object : SecurePrefs.ResetIntent {
            override fun isPending() = intentPending
            override fun record(): Boolean {
                order += "intent"
                if (intentRecordResult) intentPending = true
                return intentRecordResult
            }
            override fun clear() { order += "clear"; intentPending = false }
        }

        fun deletions() = order.count { it == "file" || it == "key" }

        fun open(classify: (Throwable) -> SecurePrefs.Cause = SecurePrefs::cause) =
            SecurePrefs.open(::create, ::deleteFile, ::deleteKey, intent, classify)
    }

    /** What Tink throws when the keyset was encrypted under a key that is gone. */
    private fun badTag() = AEADBadTagException("message authentication failed")

    /** Stands in for KeyPermanentlyInvalidatedException through the injected classifier. */
    private class Invalidated : InvalidKeyException("permanently invalidated")

    private val classifyInvalidated: (Throwable) -> SecurePrefs.Cause = {
        if (it is Invalidated) SecurePrefs.Cause.KEY_INVALIDATED else SecurePrefs.cause(it)
    }

    private inline fun <reified T : Throwable> assertThrowsSame(expected: Throwable, block: () -> Unit) {
        try {
            block()
            fail("expected $expected")
        } catch (e: Throwable) {
            assertTrue("got $e", e is T)
            assertSame(expected, e)
        }
    }

    @Test
    fun `a healthy store opens once and nothing is deleted`() {
        val s = Script(healthy)
        val opened = s.open()
        assertSame(healthy, opened.prefs)
        assertFalse(opened.resetPending)
        assertEquals(listOf("create"), s.order)
        assertEquals("v", opened.prefs.getString("k", null))
    }

    @Test
    fun `a transient failure followed by success keeps the store and deletes nothing`() {
        for (transient in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"), badTag())) {
            val s = Script(transient, healthy)
            val opened = s.open()
            assertSame("after $transient", healthy, opened.prefs)
            assertFalse(opened.resetPending)
            assertEquals("after $transient", listOf("create", "create"), s.order)
        }
    }

    @Test
    fun `an unreadable keyset twice records the intent, deletes the file only, then opens empty`() {
        val s = Script(badTag(), badTag(), fresh)
        val opened = s.open()
        assertSame(fresh, opened.prefs)
        assertTrue(opened.resetPending)
        assertEquals(listOf("create", "create", "intent", "file", "create"), s.order)
        opened.resetDone()
        assertFalse(s.intentPending)
    }

    @Test
    fun `the bad tag is found anywhere in the cause chain`() {
        val wrapped = GeneralSecurityException("keyset", IOException("read", badTag()))
        val s = Script(wrapped, wrapped, fresh)
        assertTrue(s.open().resetPending)
        assertEquals(1, s.order.count { it == "file" })
    }

    @Test
    fun `a permanently invalidated key twice deletes the key, then the file, then opens empty`() {
        val s = Script(Invalidated(), Invalidated(), fresh)
        val opened = s.open(classifyInvalidated)
        assertTrue(opened.resetPending)
        assertEquals(listOf("create", "create", "intent", "key", "file", "create"), s.order)
    }

    @Test
    fun `an UnrecoverableKeyException is not permanent and deletes nothing`() {
        // Android also wraps passing Keystore failures in it (Codex code review, MUST 1).
        val wrapped = UnrecoverableKeyException("key info").apply { initCause(KeyStoreException("busy")) }
        val s = Script(wrapped, wrapped)
        assertThrowsSame<UnrecoverableKeyException>(wrapped) { s.open() }
        assertEquals(0, s.deletions())
        assertFalse(s.order.contains("intent"))
    }

    @Test
    fun `a failure with no permanent cause is thrown after the retry and nothing is deleted`() {
        for (other in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"), InvalidKeyException("x"))) {
            val s = Script(other, other)
            assertThrowsSame<Exception>(other) { s.open() }
            assertEquals("for $other", listOf("create", "create"), s.order)
        }
    }

    @Test
    fun `a bug is thrown at once, on any attempt, and nothing is deleted`() {
        val bug = IllegalStateException("bug")
        listOf(Script(bug), Script(badTag(), bug)).forEach { s ->
            assertThrowsSame<IllegalStateException>(bug) { s.open() }
            assertEquals(0, s.deletions())
            assertFalse(s.order.contains("intent"))
        }
    }

    @Test
    fun `a failure on the open after the deletion is thrown and the intent stays for the next start`() {
        val third = IOException("still broken")
        val s = Script(badTag(), badTag(), third)
        assertThrowsSame<IOException>(third) { s.open() }
        assertEquals(3, s.creates)
        assertTrue("the next start must still mark the cache", s.intentPending)
    }

    @Test
    fun `an intent that could not be recorded stops the recovery before any deletion`() {
        val failure = badTag()
        val s = Script(badTag(), failure).apply { intentRecordResult = false }
        assertThrowsSame<AEADBadTagException>(failure) { s.open() }
        assertEquals(listOf("create", "create", "intent"), s.order)
    }

    @Test
    fun `a file that could not be deleted stops the recovery`() {
        val failure = badTag()
        val s = Script(badTag(), failure).apply { fileDeleteResult = false }
        assertThrowsSame<AEADBadTagException>(failure) { s.open() }
        assertEquals(listOf("create", "create", "intent", "file"), s.order)
    }

    @Test
    fun `a file deletion that throws counts as not done`() {
        val failure = badTag()
        val s = Script(badTag(), failure).apply { fileDeleteThrows = true }
        assertThrowsSame<AEADBadTagException>(failure) { s.open() }
        assertEquals(2, s.creates)
    }

    @Test
    fun `a key that could not be deleted stops the recovery before the file`() {
        val failure = Invalidated()
        val s = Script(Invalidated(), failure).apply { keyDeleteResult = false }
        assertThrowsSame<Invalidated>(failure) { s.open(classifyInvalidated) }
        assertEquals(listOf("create", "create", "intent", "key"), s.order)
    }

    @Test
    fun `a deleted key followed by a file that could not be deleted is thrown`() {
        val failure = Invalidated()
        val s = Script(Invalidated(), failure).apply { fileDeleteResult = false }
        assertThrowsSame<Invalidated>(failure) { s.open(classifyInvalidated) }
        assertEquals(listOf("create", "create", "intent", "key", "file"), s.order)
    }

    @Test
    fun `a reset left pending by a start that died is reported on a healthy open`() {
        val s = Script(fresh).apply { intentPending = true }
        val opened = s.open()
        assertTrue(opened.resetPending)
        assertEquals(listOf("create"), s.order)
    }

    @Test
    fun `cause classifies only the permanent failures`() {
        assertEquals(SecurePrefs.Cause.KEYSET_UNREADABLE, SecurePrefs.cause(badTag()))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(UnrecoverableKeyException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(KeyStoreException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(InvalidKeyException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(IOException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(ProviderException("x")))
    }

    // ── TokenStore after a reset ─────────────────────────────────────────

    @Test
    fun `a store opened after a reset marks the restored cache before any session, then clears the intent`() {
        var cleared = 0
        val store = TokenStore(InMemorySharedPreferences(), resetPending = true, onResetMarked = { cleared++ })
        assertNull(store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.state.value.teardownPending)
        assertEquals(1, cleared)
        // The start-up check has nothing left to add, and does not mark twice.
        assertFalse(store.markLegacyCacheForTeardownIfNeeded())
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
    }

    @Test
    fun `a mark that did not reach disk keeps the intent for the next start`() {
        var cleared = 0
        val prefs = InMemorySharedPreferences().apply { failCommits = true }
        TokenStore(prefs, resetPending = true, onResetMarked = { cleared++ })
        assertEquals(0, cleared)
        assertNull("nothing reached disk", TokenStore(prefs.restart()).teardownPending)
    }

    @Test
    fun `an install after a reset keeps the marker for its settle`() {
        val store = TokenStore(InMemorySharedPreferences(), resetPending = true)
        val id = store.installSession("access", "refresh", "user")
        assertEquals(id, store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
    }

    @Test
    fun `a store opened normally has no marker`() {
        var cleared = 0
        val store = TokenStore(InMemorySharedPreferences(), onResetMarked = { cleared++ })
        assertNull(store.teardownPending)
        assertEquals(0, cleared)
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
        val securePrefs = source("SecurePrefs.kt")
        assertTrue(securePrefs.contains("EncryptedSharedPreferences.create("))
        assertTrue("the intent must live where backups never reach", securePrefs.contains("context.noBackupFilesDir"))
    }
}
