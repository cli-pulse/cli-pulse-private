package com.clipulse.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStoreOwner
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionViewModelStoresTest {

    class Probe : ViewModel() {
        var cleared = false
        override fun onCleared() {
            cleared = true
        }
    }

    private fun probeIn(owner: ViewModelStoreOwner): Probe =
        ViewModelProvider(owner, object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>): T = Probe() as T
        })[Probe::class.java]

    @Test
    fun `the same session keeps its view models, as across a rotation`() {
        val stores = SessionViewModelStores()
        val first = probeIn(stores.ownerFor(0))
        val again = probeIn(stores.ownerFor(0))
        assertSame(first, again)
        assertFalse(first.cleared)
    }

    @Test
    fun `a new session clears the previous session's view models`() {
        val stores = SessionViewModelStores()
        val old = probeIn(stores.ownerFor(0))
        val fresh = probeIn(stores.ownerFor(1))
        assertTrue(old.cleared)
        assertNotSame(old, fresh)
        assertFalse(fresh.cleared)
    }
}
