package com.clipulse.android.worker

import android.content.Context
import android.util.Log
import androidx.work.ListenableWorker
import androidx.work.WorkerParameters
import com.clipulse.android.data.collector.CollectorManager
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import io.mockk.coVerify
import io.mockk.Called
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import io.mockk.verify
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/** doWork() itself, not a copy of its gate: demo mode and signed-out must not sync. */
class SyncWorkerTest {

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val collectorManager = mockk<CollectorManager>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)

    private fun worker() = SyncWorker(
        mockk<Context>(relaxed = true),
        mockk<WorkerParameters>(relaxed = true),
        supabase,
        tokenStore,
        collectorManager,
    )

    @Before
    fun setUp() {
        mockkStatic(Log::class)
        every { Log.d(any(), any()) } returns 0
        every { Log.w(any(), any<String>(), any()) } returns 0
        every { Log.e(any(), any(), any()) } returns 0
    }

    @After
    fun tearDown() {
        unmockkStatic(Log::class)
    }

    @Test
    fun `demo mode does no work`() = runTest {
        every { tokenStore.isDemoMode } returns true
        every { tokenStore.isLoggedIn } returns true
        every { tokenStore.hasSession } returns false
        every { tokenStore.accessToken } returns null

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { supabase wasNot Called }
        verify { collectorManager wasNot Called }
    }

    @Test
    fun `signed out does no work`() = runTest {
        every { tokenStore.isDemoMode } returns false
        every { tokenStore.isLoggedIn } returns false
        every { tokenStore.hasSession } returns false

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { supabase wasNot Called }
        verify { collectorManager wasNot Called }
    }

    @Test
    fun `a signed-in account syncs`() = runTest {
        every { tokenStore.isDemoMode } returns false
        every { tokenStore.isLoggedIn } returns true
        every { tokenStore.hasSession } returns true
        every { tokenStore.accessToken } returns "access-1"
        every { tokenStore.snapshot() } returns SessionContext("session-1", "access-1", "refresh-1", "user-1", false)
        every { tokenStore.deviceId } returns "device-1"
        every { collectorManager.availableCollectors() } returns emptyList()

        assertEquals(ListenableWorker.Result.success(), worker().doWork())
        verify { collectorManager.availableCollectors() }
        coVerify { supabase.dashboard() }
    }
}
