package com.clipulse.android.data.remote

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TokenStoreDemoModeTest {

    private val store = TokenStore(InMemorySharedPreferences())

    @Test
    fun `demo mode is logged in but has no session`() {
        store.isDemoMode = true
        assertTrue(store.isLoggedIn)
        assertFalse(store.hasSession)
    }

    @Test
    fun `an access token is a session`() {
        store.accessToken = "access-1"
        assertTrue(store.hasSession)
    }

    @Test
    fun `writing an access token ends demo mode`() {
        store.isDemoMode = true
        store.accessToken = "access-1"
        assertFalse(store.isDemoMode)
        assertTrue(store.hasSession)
    }

    @Test
    fun `updateAuthState with a token ends demo mode`() {
        store.isDemoMode = true
        store.updateAuthState("access-1", "refresh-1", "user-1")
        assertFalse(store.isDemoMode)
        assertTrue(store.hasSession)
    }

    @Test
    fun `clearing the token does not touch demo mode`() {
        store.isDemoMode = true
        store.accessToken = null
        store.updateAuthState(null, null, null)
        assertTrue(store.isDemoMode)
        assertFalse(store.hasSession)
    }
}
