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
import java.security.KeyStoreException
import java.security.ProviderException
import java.security.UnrecoverableKeyException
import javax.crypto.AEADBadTagException

/**
 * 1.63 D7: SecurePrefs deletes only what can never be read again, and only after a second
 * failure. The fakes stand in for EncryptedSharedPreferences.create, Context.deleteSharedPreferences
 * and the Keystore deletion; nothing here touches a real Keystore.
 */
class SecurePrefsTest {

    private val healthy = InMemorySharedPreferences().also { it.edit().putString("k", "v").commit() }
    private val fresh = InMemorySharedPreferences()

    /** Each call to create() takes the next outcome: an exception to throw or prefs to return. */
    private class Script(vararg outcomes: Any) {
        private val queue = ArrayDeque(outcomes.toList())
        var creates = 0
        var fileDeletes = 0
        var keyDeletes = 0
        var fileDeleteResult = true
        var keyDeleteResult = true
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

        fun deleteFile(): Boolean { fileDeletes++; order += "file"; return fileDeleteResult }
        fun deleteKey(): Boolean { keyDeletes++; order += "key"; return keyDeleteResult }

        fun open() = SecurePrefs.open(::create, ::deleteFile, ::deleteKey)
    }

    /** What Tink throws when the keyset was encrypted under a key that is gone. */
    private fun badTag() = AEADBadTagException("message authentication failed")

    @Test
    fun `a healthy store opens once and nothing is deleted`() {
        val s = Script(healthy)
        val opened = s.open()
        assertSame(healthy, opened.prefs)
        assertFalse(opened.wasReset)
        assertEquals(1, s.creates)
        assertEquals(0, s.fileDeletes + s.keyDeletes)
        assertEquals("v", opened.prefs.getString("k", null))
    }

    @Test
    fun `a transient failure followed by success keeps the store and deletes nothing`() {
        for (transient in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"), badTag())) {
            val s = Script(transient, healthy)
            val opened = s.open()
            assertSame("after $transient", healthy, opened.prefs)
            assertFalse(opened.wasReset)
            assertEquals(2, s.creates)
            assertEquals("after $transient", 0, s.fileDeletes + s.keyDeletes)
        }
    }

    @Test
    fun `an unreadable keyset twice deletes the file only, then opens empty`() {
        val s = Script(badTag(), badTag(), fresh)
        val opened = s.open()
        assertSame(fresh, opened.prefs)
        assertTrue(opened.wasReset)
        assertEquals(listOf("create", "create", "file", "create"), s.order)
        assertEquals(0, s.keyDeletes)
    }

    @Test
    fun `the bad tag is found anywhere in the cause chain`() {
        val wrapped = java.security.GeneralSecurityException("keyset", IOException("read", badTag()))
        val s = Script(wrapped, wrapped, fresh)
        assertTrue(s.open().wasReset)
        assertEquals(1, s.fileDeletes)
    }

    @Test
    fun `an unusable key twice deletes the key, then the file, then opens empty`() {
        val s = Script(UnrecoverableKeyException("gone"), UnrecoverableKeyException("gone"), fresh)
        val opened = s.open()
        assertTrue(opened.wasReset)
        assertEquals(listOf("create", "create", "key", "file", "create"), s.order)
    }

    @Test
    fun `a failure with no permanent cause is thrown after the retry and nothing is deleted`() {
        for (other in listOf(KeyStoreException("busy"), ProviderException("keystore2"), IOException("io"))) {
            val s = Script(other, other)
            try {
                s.open()
                fail("expected $other")
            } catch (e: Exception) {
                assertSame(other, e)
            }
            assertEquals(2, s.creates)
            assertEquals("for $other", 0, s.fileDeletes + s.keyDeletes)
        }
    }

    @Test
    fun `a bug is thrown at once, on any attempt, and nothing is deleted`() {
        val bug = IllegalStateException("bug")
        listOf(Script(bug), Script(badTag(), bug)).forEach { s ->
            try {
                s.open()
                fail("expected the bug")
            } catch (e: IllegalStateException) {
                assertSame(bug, e)
            }
            assertEquals(0, s.fileDeletes + s.keyDeletes)
        }
    }

    @Test
    fun `a failure on the third open is thrown`() {
        val third = IOException("still broken")
        val s = Script(badTag(), badTag(), third)
        try {
            s.open()
            fail("expected the third failure")
        } catch (e: IOException) {
            assertSame(third, e)
        }
        assertEquals(3, s.creates)
    }

    @Test
    fun `a file that could not be deleted stops the recovery`() {
        val failure = badTag()
        val s = Script(badTag(), failure).apply { fileDeleteResult = false }
        try {
            s.open()
            fail("expected the original failure")
        } catch (e: AEADBadTagException) {
            assertSame(failure, e)
        }
        assertEquals(2, s.creates)
        assertEquals(0, s.keyDeletes)
    }

    @Test
    fun `a key that could not be deleted stops the recovery before the file`() {
        val failure = UnrecoverableKeyException("gone")
        val s = Script(UnrecoverableKeyException("gone"), failure).apply { keyDeleteResult = false }
        try {
            s.open()
            fail("expected the original failure")
        } catch (e: UnrecoverableKeyException) {
            assertSame(failure, e)
        }
        assertEquals(listOf("create", "create", "key"), s.order)
        assertEquals(0, s.fileDeletes)
    }

    @Test
    fun `cause classifies only the permanent failures`() {
        assertEquals(SecurePrefs.Cause.KEYSET_UNREADABLE, SecurePrefs.cause(badTag()))
        assertEquals(SecurePrefs.Cause.KEY_UNUSABLE, SecurePrefs.cause(UnrecoverableKeyException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(KeyStoreException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(java.security.InvalidKeyException("x")))
        assertEquals(SecurePrefs.Cause.OTHER, SecurePrefs.cause(IOException("x")))
    }

    // ── TokenStore after a reset ─────────────────────────────────────────

    @Test
    fun `a store opened after a reset marks the restored cache for teardown before any session`() {
        val store = TokenStore(InMemorySharedPreferences(), startsAfterReset = true)
        assertNull(store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.state.value.teardownPending)
        // The start-up check has nothing left to add, and does not mark twice.
        assertFalse(store.markLegacyCacheForTeardownIfNeeded())
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
    }

    @Test
    fun `an install after a reset keeps the marker for its settle`() {
        val store = TokenStore(InMemorySharedPreferences(), startsAfterReset = true)
        val id = store.installSession("access", "refresh", "user")
        assertEquals(id, store.sessionId)
        assertEquals(TokenStore.LEGACY_CACHE_MARKER, store.teardownPending)
    }

    @Test
    fun `a store opened normally has no marker`() {
        val store = TokenStore(InMemorySharedPreferences())
        assertNull(store.teardownPending)
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
