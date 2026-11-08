package com.clipulse.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionViewModelStoresTest {

    private val parent = object : ViewModelStoreOwner {
        override val viewModelStore = ViewModelStore()
    }

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
        val first = probeIn(stores.ownerFor(0, parent))
        val again = probeIn(stores.ownerFor(0, parent))
        assertSame(first, again)
        assertFalse(first.cleared)
    }

    @Test
    fun `a new session clears the previous session's view models`() {
        val stores = SessionViewModelStores()
        val old = probeIn(stores.ownerFor(0, parent))
        val fresh = probeIn(stores.ownerFor(1, parent))
        assertTrue(old.cleared)
        assertNotSame(old, fresh)
        assertFalse(fresh.cleared)
    }

    @Test
    fun `ending the session clears its view models when its UI goes`() {
        val stores = SessionViewModelStores()
        val probe = probeIn(stores.ownerFor(0, parent))
        stores.endSession()
        stores.clearIfEnded()
        assertTrue(probe.cleared)
    }

    @Test
    fun `a rotation disposes the UI without ending the session`() {
        val stores = SessionViewModelStores()
        val probe = probeIn(stores.ownerFor(0, parent))
        stores.clearIfEnded()
        assertFalse(probe.cleared)
        assertSame(probe, probeIn(stores.ownerFor(0, parent)))
    }
}
