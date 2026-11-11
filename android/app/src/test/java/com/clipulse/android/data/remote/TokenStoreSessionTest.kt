package com.clipulse.android.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The session identity and the one atomic end transition, against a real TokenStore. */
class TokenStoreSessionTest {

    private val prefs = InMemorySharedPreferences()
    private val store = TokenStore(prefs)

    private fun installA(): String = store.installSession("access-A", "refresh-A", "user-A")!!

    @Test
    fun `a sign-in installs the credentials with a fresh session id in one transaction`() {
        val before = prefs.commits
        val id = installA()

        assertEquals(before + 1, prefs.commits)
        val s = store.snapshot()!!
        assertEquals(id, s.sessionId)
        assertEquals("access-A", s.accessToken)
        assertEquals("refresh-A", s.refreshToken)
        assertEquals("user-A", s.userId)
        assertFalse(s.isDemo)
        assertEquals(id, store.state.value.sessionId)
        assertNull(store.state.value.teardownPending)
    }

    @Test
    fun `every sign-in gets its own id`() {
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = store.installSession("access-B", "refresh-B", "user-B")!!
        assertNotEquals(a, b)
    }

    @Test
    fun `a renewal keeps the session id`() {
        val id = installA()
        assertTrue(store.rotateIfCurrent(id, "access-A2", "refresh-A2"))
        val s = store.snapshot()!!
        assertEquals(id, s.sessionId)
        assertEquals("access-A2", s.accessToken)
        assertEquals("refresh-A2", s.refreshToken)
    }

    @Test
    fun `ending the current session removes it and writes the marker in ONE commit`() {
        val id = installA()
        val before = prefs.commits

        val ended = store.endIfCurrent(id, EndReason.UserSignedOut)

        assertEquals("one transaction for the wipe and the marker", before + 1, prefs.commits)
        assertNotNull(ended)
        assertEquals(id, ended!!.sessionId)
        assertEquals("access-A", ended.accessToken)
        assertEquals("refresh-A", ended.refreshToken)
        assertEquals(EndReason.UserSignedOut, ended.reason)
        assertNull(store.snapshot())
        assertNull(store.accessToken)
        assertNull(store.refreshToken)
        assertNull(store.userId)
        assertEquals(id, store.teardownPending)
        val state = store.state.value
        assertNull(state.sessionId)
        assertEquals(EndReason.UserSignedOut, state.endedReason)
        assertEquals(id, state.teardownPending)
    }

    @Test
    fun `ending the same session twice ends it once`() {
        val id = installA()
        assertNotNull(store.endIfCurrent(id, EndReason.SessionRefused))
        val before = prefs.commits

        assertNull(store.endIfCurrent(id, EndReason.SessionRefused))
        assertEquals("a second end writes nothing", before, prefs.commits)
    }

    @Test
    fun `a stale id ends nothing`() {
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = store.installSession("access-B", "refresh-B", "user-B")!!
        val before = prefs.commits

        assertNull(store.endIfCurrent(a, EndReason.SessionRefused))

        assertEquals(before, prefs.commits)
        assertEquals(b, store.sessionId)
        assertEquals("access-B", store.accessToken)
        assertEquals("refresh-B", store.refreshToken)
    }

    @Test
    fun `a renewal for an ended or replaced session is dropped`() {
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        assertFalse(store.rotateIfCurrent(a, "late-access", "late-refresh"))
        assertNull(store.accessToken)

        val b = store.installSession("access-B", "refresh-B", "user-B")!!
        assertFalse(store.rotateIfCurrent(a, "late-access", "late-refresh"))
        assertEquals("access-B", store.accessToken)
        assertEquals("refresh-B", store.refreshToken)
        assertEquals(b, store.sessionId)
    }

    @Test
    fun `profile and device writes only land on their own session`() {
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        val b = store.installSession("access-B", "refresh-B", "user-B", userName = "B")!!

        assertFalse(store.setProfileIfCurrent(a, "user-A", "Name A", "a@example.test"))
        assertFalse(store.setDeviceIdIfCurrent(a, "device-A"))
        assertEquals("user-B", store.userId)
        assertEquals("B", store.userName)
        assertNull(store.deviceIdFor(b))
        assertNull(store.deviceIdFor(a))

        assertTrue(store.setDeviceIdIfCurrent(b, "device-B"))
        assertEquals("device-B", store.deviceIdFor(b))
        assertTrue(store.setProfileIfCurrent(b, null, "Name B", ""))
        assertEquals("Name B", store.userName)
        assertEquals("user-B", store.userId)
    }

    @Test
    fun `a refused sign-in attempt writes nothing`() {
        val before = prefs.commits
        assertNull(store.installSession("access-X", "refresh-X", "user-X", attemptOk = { false }))
        assertEquals(before, prefs.commits)
        assertNull(store.snapshot())
    }

    @Test
    fun `installing over a live session marks the old one for teardown`() {
        val a = installA()
        val b = store.installSession("access-B", "refresh-B", "user-B")!!
        assertEquals(b, store.sessionId)
        assertEquals(a, store.teardownPending)
    }

    @Test
    fun `the teardown marker is cleared only for the id it names`() {
        val a = installA()
        store.endIfCurrent(a, EndReason.UserSignedOut)
        assertFalse(store.clearPendingIfEquals("some-other-id"))
        assertEquals(a, store.teardownPending)
        assertTrue(store.clearPendingIfEquals(a))
        assertNull(store.teardownPending)
        assertNull(store.state.value.teardownPending)
    }

    @Test
    fun `demo mode is a session with a synthetic id and no tokens`() {
        val before = prefs.commits
        val demo = store.enterDemoMode()

        assertEquals("flag and id in one transaction", before + 1, prefs.commits)
        assertTrue(demo.startsWith(TokenStore.DEMO_ID_PREFIX))
        assertTrue(store.isDemoMode)
        val s = store.snapshot()!!
        assertTrue(s.isDemo)
        assertEquals(demo, s.sessionId)
        assertNull(s.accessToken)
        assertNull(s.refreshToken)
        assertTrue(store.state.value.isDemo)
    }

    @Test
    fun `leaving demo mode is the same atomic end, and a stale demo id ends nothing`() {
        val demo = store.enterDemoMode()
        assertNull(store.endIfCurrent("demo-stale", EndReason.DemoExit))
        assertTrue(store.isDemoMode)

        val ended = store.endIfCurrent(demo, EndReason.DemoExit)
        assertNotNull(ended)
        assertFalse(store.isDemoMode)
        assertNull(store.sessionId)
        assertEquals(demo, store.teardownPending)
        assertEquals(EndReason.DemoExit, store.state.value.endedReason)
    }

    @Test
    fun `a real sign-in replaces the demo id`() {
        val demo = store.enterDemoMode()
        val real = store.installSession("access-A", "refresh-A", "user-A")!!
        assertNotEquals(demo, real)
        assertFalse(store.isDemoMode)
        assertFalse(store.snapshot()!!.isDemo)
        assertEquals(demo, store.teardownPending)
    }

    @Test
    fun `a session saved before session ids gets one, once`() {
        val legacy = InMemorySharedPreferences()
        legacy.edit()
            .putString("access_token", "access-old")
            .putString("refresh_token", "refresh-old")
            .putString("user_id", "user-old")
            .apply()

        val first = TokenStore(legacy)
        val id = first.sessionId
        assertNotNull(id)
        assertFalse(id!!.startsWith(TokenStore.DEMO_ID_PREFIX))
        assertEquals(id, first.sessionId)
        assertEquals(id, first.state.value.sessionId)
        assertEquals("the minted id is stored, not minted again", id, TokenStore(legacy).sessionId)
        assertEquals("access-old", first.snapshot()!!.accessToken)
    }

    @Test
    fun `a demo flag saved before session ids gets a demo id`() {
        val legacy = InMemorySharedPreferences()
        legacy.edit().putBoolean("demo_mode", true).apply()

        val demoStore = TokenStore(legacy)
        val id = demoStore.sessionId!!
        assertTrue(id.startsWith(TokenStore.DEMO_ID_PREFIX))
        assertNotNull(demoStore.endIfCurrent(id, EndReason.DemoExit))
        assertFalse(demoStore.isDemoMode)
    }

    @Test
    fun `a sign-in drops every pending OAuth flow`() {
        store.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
        )
        installA()
        assertNull("an abandoned browser sign-in cannot complete later", store.claimPendingOAuthFlow())
    }

    @Test
    fun `a pending flow is claimed exactly once and keeps its session id`() {
        val a = installA()
        store.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow("link", "github", "verifier-1", "state-1", System.currentTimeMillis(), sessionId = a),
        )
        val claimed = store.claimPendingOAuthFlow()
        assertEquals(a, claimed!!.sessionId)
        assertEquals("link", claimed.kind)
        assertNull(store.claimPendingOAuthFlow())
    }

    @Test
    fun `ending a session drops a pending link flow started under it`() {
        val a = installA()
        store.savePendingOAuthFlow(
            TokenStore.PendingOAuthFlow("link", "github", "verifier-1", "state-1", System.currentTimeMillis(), sessionId = a),
        )
        store.endIfCurrent(a, EndReason.UserSignedOut)
        assertNull(store.claimPendingOAuthFlow())
    }

    @Test
    fun `tokens never reach toString`() {
        installA()
        val text = store.snapshot().toString() + store.endCurrent(EndReason.UserSignedOut).toString()
        assertFalse(text, text.contains("access-A") || text.contains("refresh-A"))
    }
}
