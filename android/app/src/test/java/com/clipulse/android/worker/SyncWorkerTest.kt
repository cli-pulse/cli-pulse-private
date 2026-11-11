package com.clipulse.android.worker

import android.content.Context
import android.util.Log
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.clipulse.android.data.collector.CollectorManager
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import io.mockk.Called
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * doWork() itself, with a real TokenStore: demo mode and signed-out do not sync, a run works for
 * the one session it started with, and an ended or replaced session is not retried.
 */
class SyncWorkerTest {

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val collectorManager = mockk<CollectorManager>(relaxed = true)
    private val store = TokenStore(InMemorySharedPreferences())

    private fun worker() = SyncWorker(
        mockk<Context>(relaxed = true),
        mockk<WorkerParameters>(relaxed = true),
        supabase,
        store,
        collectorManager,
    )

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { Log.w(any(), any<String>()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0
        every { Log.e(any(), any()) } returns 0
        every { Log.e(any(), any(), any()) } returns 0
        every { collectorManager.availableCollectors() } returns emptyList()
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    @Test
    fun `demo mode does no work`() = runTest {
        store.enterDemoMode()

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { supabase wasNot Called }
        verify { collectorManager wasNot Called }
    }

    @Test
    fun `signed out does no work`() = runTest {
        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { supabase wasNot Called }
        verify { collectorManager wasNot Called }
    }

    @Test
    fun `a signed-in account syncs`() = runTest {
        val a = store.installSession("access-1", "refresh-1", "user-1")!!
        store.setDeviceIdIfCurrent(a, "device-1")

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { collectorManager.availableCollectors() }
        coVerify(exactly = 0) { supabase.registerDevice(any(), any(), any(), any()) }
        coVerify { supabase.dashboard(match { it.sessionId == a }) }
    }

    @Test
    fun `a new device is recorded for the session the run started with`() = runTest {
        val a = store.installSession("access-1", "refresh-1", "user-1")!!
        coEvery { supabase.registerDevice(any(), any(), any(), any()) } returns "device-A"

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        assertEquals("device-A", store.deviceIdFor(a))
    }

    @Test
    fun `an account change during registration does not give the next account the old device`() = runTest {
        val a = store.installSession("access-A", "refresh-A", "user-A")!!
        var b: String? = null
        coEvery { supabase.registerDevice(any(), any(), any(), any()) } coAnswers {
            // A signs out and B signs in while A's registration is out.
            store.endIfCurrent(a, EndReason.UserSignedOut)
            b = store.installSession("access-B", "refresh-B", "user-B")
            "device-A"
        }

        assertEquals(ListenableWorker.Result.success(), worker().doWork())

        assertNull("B's device id stays unset", store.deviceIdFor(b!!))
        coVerify(exactly = 0) { supabase.syncProviderQuotas(any(), any()) }
        coVerify(exactly = 0) { supabase.dashboard(any()) }
    }

    @Test
    fun `an ended session is not retried`() = runTest {
        store.installSession("access-1", "refresh-1", "user-1")
        coEvery { supabase.registerDevice(any(), any(), any(), any()) } throws ApiError.TokenExpired

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        coVerify(exactly = 0) { supabase.dashboard(any()) }
    }

    @Test
    fun `an ended session found by the prefetch is not retried either`() = runTest {
        val a = store.installSession("access-1", "refresh-1", "user-1")!!
        store.setDeviceIdIfCurrent(a, "device-1")
        coEvery { supabase.dashboard(any()) } throws ApiError.TokenExpired

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
    }

    @Test
    fun `a network failure is still retried`() = runTest {
        val a = store.installSession("access-1", "refresh-1", "user-1")!!
        store.setDeviceIdIfCurrent(a, "device-1")
        every { collectorManager.availableCollectors() } throws IllegalStateException("collector broke")

        assertEquals(ListenableWorker.Result.retry(), worker().doWork())
    }
}
