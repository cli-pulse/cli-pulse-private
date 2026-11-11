package com.clipulse.android.ui.navigation

import androidx.lifecycle.HasDefaultViewModelProviderFactory
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.CreationExtras

/**
 * One [ViewModelStore] per signed-in session, a session being one value of the gate's epoch
 * ([SessionGateViewModel]: it moves on whenever the session on the tabs ends or changes).
 *
 * The tabs' NavHost keeps its back-stack view models in the store of whatever
 * ViewModelStoreOwner is current. That used to be the Activity, which outlives a sign-out:
 * after one, every tab came back with the previous session's view models — Settings with the
 * last account's name and email, or with demo mode's "Demo User" and its hidden sections for
 * a real account. Giving the signed-in UI this owner instead drops all of them when a new
 * epoch starts. The holder belongs to the Activity-scoped gate, so a rotation keeps the
 * session's view models exactly as before, and only the gate ends a session.
 */
internal class SessionViewModelStores {
    private var epoch: Int? = null
    private var store = ViewModelStore()
    private var ended = false

    /**
     * The owner for [sessionEpoch]. A different epoch than last time clears the old session's
     * view models first. View models created directly against it (outside the NavHost) use
     * [parent]'s factory and creation extras, as they would without this owner.
     */
    fun ownerFor(sessionEpoch: Int, parent: ViewModelStoreOwner): ViewModelStoreOwner {
        if (epoch != sessionEpoch) {
            clearStore()
            epoch = sessionEpoch
        }
        ended = false
        return SessionOwner(store, parent)
    }

    /** The session ended (sign-out, demo exit, account deletion); see [clearIfEnded]. */
    fun endSession() {
        ended = true
    }

    /**
     * Called when the signed-in UI leaves composition. After [endSession] it clears the
     * session's view models at once, so none of them (or their coroutines) waits on the
     * sign-in screen for the next account. A rotation also disposes that UI but has not
     * ended the session, and keeps them.
     */
    fun clearIfEnded() {
        if (!ended) return
        clearStore()
        epoch = null
        ended = false
    }

    private fun clearStore() {
        store.clear()
        store = ViewModelStore()
    }

    /** The owning view model is going away (the Activity finished). */
    fun clear() {
        store.clear()
    }

    private class SessionOwner(
        override val viewModelStore: ViewModelStore,
        private val parent: ViewModelStoreOwner,
    ) : ViewModelStoreOwner, HasDefaultViewModelProviderFactory {
        override val defaultViewModelProviderFactory: ViewModelProvider.Factory
            get() = (parent as? HasDefaultViewModelProviderFactory)?.defaultViewModelProviderFactory
                ?: ViewModelProvider.NewInstanceFactory()

        override val defaultViewModelCreationExtras: CreationExtras
            get() = (parent as? HasDefaultViewModelProviderFactory)?.defaultViewModelCreationExtras
                ?: CreationExtras.Empty
    }
}
