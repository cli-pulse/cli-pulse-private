package com.clipulse.android.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenStoreDemoModeTest {

    private val store = TokenStore(InMemorySharedPreferences())

    @Test
    fun `demo mode is a session without tokens`() {
        store.enterDemoMode()
        val s = store.snapshot()
        assertNotNull(s)
        assertTrue(s!!.isDemo)
        assertTrue(store.isDemoMode)
        assertNull(s.accessToken)
        assertNull(s.refreshToken)
    }

    @Test
    fun `an access token is a session`() {
        store.installSession("access-1", "refresh-1", "user-1")
        assertFalse(store.snapshot()!!.isDemo)
        assertNotNull(store.snapshot()!!.accessToken)
    }

    @Test
    fun `a real sign-in ends demo mode`() {
        store.enterDemoMode()
        store.installSession("access-1", "refresh-1", "user-1")
        assertFalse(store.isDemoMode)
        assertNotNull(store.snapshot()!!.accessToken)
    }

    @Test
    fun `ending a real session does not turn demo mode on`() {
        val id = store.installSession("access-1", "refresh-1", "user-1")!!
        store.endIfCurrent(id, EndReason.UserSignedOut)
        assertFalse(store.isDemoMode)
        assertNull(store.snapshot())
    }
}
