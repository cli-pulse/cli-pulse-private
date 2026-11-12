package com.clipulse.android.ui.navigation

import androidx.lifecycle.viewModelScope
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.OAuthCallbackResult
import com.clipulse.android.data.remote.OAuthDeepLinkNoticeReason
import com.clipulse.android.data.remote.TokenStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.job
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The owner of a browser round-trip's answer, against a real TokenStore. An "Activity" is a
 * scope of its own that dies with it (its lifecycle scope); the view model outlives it.
 * A recreated Activity hands nothing over (MainActivity.onCreate, pinned by
 * MainActivityDeepLinkWiringTest); a second `receive` of the same link here stands for a
 * second delivery of it, which must not deliver the callback twice either.
 */
class OAuthCallbackViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val prefs = InMemorySharedPreferences()
    private val store = TokenStore(prefs)

    private fun success(state: String) = OAuthCallbackResult.Success(code = "code-0123456789", state = state)

    /** One Activity instance's lifecycle scope. */
    private fun activityScope() = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** Waits for everything the view model and the given Activities have started. */
    private suspend fun settle(vm: OAuthCallbackViewModel, vararg activities: CoroutineScope) {
        val jobs = vm.viewModelScope.coroutineContext.job.children.toList() +
            activities.flatMap { it.coroutineContext.job.children.toList() }
        jobs.joinAll()
    }

    @Test
    fun `a callback whose claim is still out when the Activity is recreated is delivered, exactly once`() = runBlocking<Unit> {
        withTimeout(10_000) {
            val generation = store.beginOAuthLogin(
                TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
            )
            val vm = OAuthCallbackViewModel(store)
            // The claim removes the record, then stops there: its result is still on its way.
            val claimed = CountDownLatch(1)
            val release = CountDownLatch(1)
            prefs.applyHook = {
                prefs.applyHook = null
                claimed.countDown()
                release.await()
            }

            val first = activityScope()
            first.launch { vm.receive(success("state-1")) }
            assertTrue("the claim never ran", claimed.await(5, TimeUnit.SECONDS))
            assertNull("the record is gone from the store", prefs.getString("pending_oauth_state", null))

            // Rotation: the first Activity is destroyed before the claim's result is back,
            // and the same link reaches the view model again.
            first.cancel()
            release.countDown()
            val second = activityScope()
            second.launch { vm.receive(success("state-1")) }
            settle(vm, first, second)

            val delivered = vm.pendingCallback.value
            assertNotNull("the callback was lost with the first Activity", delivered)
            assertEquals("verifier-1", delivered!!.codeVerifier)
            assertEquals(generation, delivered.authGeneration)
            assertNull(vm.pendingNotice.value)

            // The screen takes it; a further replay delivers nothing.
            vm.consumeCallback()
            second.launch { vm.receive(success("state-1")) }
            settle(vm, second)
            assertNull("delivered twice", vm.pendingCallback.value)
            assertNull(vm.pendingNotice.value)

            second.cancel()
            vm.viewModelScope.cancel()
        }
    }

    @Test
    fun `a routed callback waits for the screen across a recreation`() = runBlocking<Unit> {
        withTimeout(10_000) {
            store.beginOAuthLogin(
                TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
            )
            val vm = OAuthCallbackViewModel(store)
            val first = activityScope()
            first.launch { vm.receive(success("state-1")) }
            settle(vm, first)
            first.cancel() // destroyed before its screen consumed the callback

            val second = activityScope()
            second.launch { vm.receive(success("state-1")) } // the same link again
            settle(vm, second)

            assertEquals("verifier-1", vm.pendingCallback.value?.codeVerifier)
            second.cancel()
            vm.viewModelScope.cancel()
        }
    }

    /**
     * Why a recreated Activity must not hand its old deep link over again: by then the user
     * may have started another sign-in, and the old link would claim THAT flow's record.
     */
    @Test
    fun `an old link handed over after a newer flow started costs that flow; without it the newer callback arrives`() = runBlocking<Unit> {
        withTimeout(10_000) {
            val vm = OAuthCallbackViewModel(store)
            val activity = activityScope()
            // Flow 1 completes: its link is routed, and the screen takes the callback.
            store.beginOAuthLogin(
                TokenStore.PendingOAuthFlow("login", "github", "verifier-1", "state-1", System.currentTimeMillis()),
            )
            activity.launch { vm.receive(success("state-1")) }
            settle(vm, activity)
            assertEquals("verifier-1", vm.pendingCallback.value?.codeVerifier)
            vm.consumeCallback()

            // Flow 2 starts; the browser is open.
            store.beginOAuthLogin(
                TokenStore.PendingOAuthFlow("login", "github", "verifier-2", "state-2", System.currentTimeMillis()),
            )

            // The hazard: flow 1's link handed over again (what onCreate did on a recreation).
            activity.launch { vm.receive(success("state-1")) }
            settle(vm, activity)
            assertEquals(OAuthDeepLinkNoticeReason.STATE_MISMATCH, vm.pendingNotice.value?.reason)
            vm.consumeNotice()
            // ... and flow 2's real callback then finds nothing.
            activity.launch { vm.receive(success("state-2")) }
            settle(vm, activity)
            assertNull(vm.pendingCallback.value)

            // Start over without the replay: a newer flow is still pending when its own
            // callback comes (through onNewIntent), and that callback is delivered.
            store.beginOAuthLogin(
                TokenStore.PendingOAuthFlow("login", "github", "verifier-3", "state-3", System.currentTimeMillis()),
            )
            activity.launch { vm.receive(success("state-3")) }
            settle(vm, activity)
            assertEquals("verifier-3", vm.pendingCallback.value?.codeVerifier)
            assertNull(vm.pendingNotice.value)

            activity.cancel()
            vm.viewModelScope.cancel()
        }
    }
}
