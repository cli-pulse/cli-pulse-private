package com.clipulse.android.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenStoreDemoModeTest {

    private val store = TokenStore(InMemorySharedPreferences())

    @Test
    fun `demo mode is logged in but has no session`() {
        store.enterDemoMode()
        assertTrue(store.isLoggedIn)
        assertFalse(store.hasSession)
    }

    @Test
    fun `an access token is a session`() {
        store.installSession("access-1", "refresh-1", "user-1")
        assertTrue(store.hasSession)
    }

    @Test
    fun `a real sign-in ends demo mode`() {
        store.enterDemoMode()
        store.installSession("access-1", "refresh-1", "user-1")
        assertFalse(store.isDemoMode)
        assertTrue(store.hasSession)
    }

    @Test
    fun `ending a real session does not turn demo mode on`() {
        val id = store.installSession("access-1", "refresh-1", "user-1")!!
        store.endIfCurrent(id, EndReason.UserSignedOut)
        assertFalse(store.isDemoMode)
        assertFalse(store.hasSession)
        assertFalse(store.isLoggedIn)
    }
}
