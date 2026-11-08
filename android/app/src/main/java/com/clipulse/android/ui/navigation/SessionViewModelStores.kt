package com.clipulse.android.ui.navigation

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner

/**
 * One [ViewModelStore] per signed-in session, a session being one value of AppNavigation's
 * login epoch (it moves on at every sign-out, demo exit and account deletion).
 *
 * The tabs' NavHost keeps its back-stack view models in the store of whatever
 * ViewModelStoreOwner is current. That used to be the Activity, which outlives a sign-out:
 * after one, every tab came back with the previous session's view models — Settings with the
 * last account's name and email, or with demo mode's "Demo User" and its hidden sections for
 * a real account. Giving the signed-in UI this owner instead drops all of them when a new
 * epoch starts. The holder itself is Activity-scoped, so a rotation keeps the session's view
 * models exactly as before.
 */
internal class SessionViewModelStores : ViewModel() {
    private var epoch: Int? = null
    private var store = ViewModelStore()

    /** The owner for [sessionEpoch]. A different epoch than last time clears the old session's view models first. */
    fun ownerFor(sessionEpoch: Int): ViewModelStoreOwner {
        if (epoch != sessionEpoch) {
            store.clear()
            store = ViewModelStore()
            epoch = sessionEpoch
        }
        val current = store
        return object : ViewModelStoreOwner {
            override val viewModelStore: ViewModelStore get() = current
        }
    }

    override fun onCleared() {
        store.clear()
    }
}
