package com.clipulse.android.data.repository

import com.clipulse.android.data.local.CacheDao
import com.clipulse.android.data.remote.EndReason
import com.clipulse.android.data.remote.InMemorySharedPreferences
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import io.mockk.Called
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DashboardRepositoryDemoModeTest {

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val cache = mockk<CacheDao>(relaxed = true)
    private val tokenStore = TokenStore(InMemorySharedPreferences())
    private val demoId = tokenStore.enterDemoMode()
    private val lifecycle = SessionLifecycle(tokenStore, cache, CoroutineScope(SupervisorJob() + Dispatchers.Unconfined))
    private val repository = DashboardRepository(supabase, cache, tokenStore, lifecycle)

    @Test
    fun `every refresh loads demo data and touches neither the backend nor Room`() = runTest {
        repository.refreshDashboard()
        repository.refreshProviders()
        repository.refreshSessions()
        repository.refreshDevices()
        repository.refreshAlerts()
        repository.refreshDailyUsage(7)
        repository.loadFromCache()
        repository.maybeEvaluateBudgetAlerts()

        verify { supabase wasNot Called }
        verify { cache wasNot Called }
    }

    @Test
    fun `a demo refresh fills every flow, export data included`() = runTest {
        repository.refreshDashboard()

        assertNotNull(repository.dashboard.value)
        assertTrue(repository.providers.value.isNotEmpty())
        assertTrue(repository.sessions.value.isNotEmpty())
        assertTrue(repository.devices.value.isNotEmpty())
        assertTrue(repository.alerts.value.isNotEmpty())
        assertTrue(repository.dailyUsage.value.isNotEmpty())
    }

    @Test
    fun `daily usage refresh honours the requested range`() = runTest {
        repository.refreshDailyUsage(7)
        assertEquals(7, repository.dailyUsage.value.map { it.date }.toSet().size)
    }

    @Test
    fun `leaving demo mode empties every flow`() = runTest {
        repository.refreshDashboard()
        lifecycle.endIfCurrent(demoId, EndReason.DemoExit)

        assertEquals(null, repository.dashboard.value)
        assertTrue(repository.providers.value.isEmpty())
        assertTrue(repository.sessions.value.isEmpty())
        assertTrue(repository.devices.value.isEmpty())
        assertTrue(repository.alerts.value.isEmpty())
        assertTrue(repository.dailyUsage.value.isEmpty())
    }
}
