package com.clipulse.android.data.repository

import com.clipulse.android.data.DemoDataProvider
import com.clipulse.android.data.local.*
import com.clipulse.android.data.model.*
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.SessionContext
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.data.session.SessionScopedState
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

/**
 * The signed-in session's rows, in memory (the flows) and in Room. Every write goes through
 * [SessionLifecycle.write] for the session the fetch was made for: it waits for a previous
 * session's teardown and is dropped if that session is no longer current, so a response that
 * comes back after a sign-out, or after the next account signed in, is never shown or cached.
 */
class DashboardRepository(
    private val supabase: SupabaseClient,
    private val cache: CacheDao,
    private val tokenStore: TokenStore,
    private val lifecycle: SessionLifecycle,
) : SessionScopedState {
    init {
        lifecycle.register(this)
    }

    val isDemoMode: Boolean get() = tokenStore.isDemoMode
    private val _dashboard = MutableStateFlow<DashboardSummary?>(null)
    val dashboard: StateFlow<DashboardSummary?> = _dashboard

    private val _providers = MutableStateFlow<List<ProviderUsage>>(emptyList())
    val providers: StateFlow<List<ProviderUsage>> = _providers

    private val _sessions = MutableStateFlow<List<SessionRecord>>(emptyList())
    val sessions: StateFlow<List<SessionRecord>> = _sessions

    private val _devices = MutableStateFlow<List<DeviceRecord>>(emptyList())
    val devices: StateFlow<List<DeviceRecord>> = _devices

    private val _alerts = MutableStateFlow<List<AlertRecord>>(emptyList())
    val alerts: StateFlow<List<AlertRecord>> = _alerts

    private val _dailyUsage = MutableStateFlow<List<DailyUsage>>(emptyList())
    val dailyUsage: StateFlow<List<DailyUsage>> = _dailyUsage

    /**
     * Iter2 follow-up (Gemini caught): the budget-RPC throttle was originally
     * placed on `AlertsViewModel`, but ViewModels are scoped to NavBackStackEntry
     * and get destroyed on tab navigation, dropping the throttle. Repository
     * is `@Singleton` (see AppModule.provideDashboardRepository), so this
     * lastBudgetEvalAtMs survives across all tabs and the entire app session.
     */
    @Volatile
    private var lastBudgetEvalAtMs: Long = 0L
    private val budgetEvalCooldownMs = 5 * 60 * 1000L

    /**
     * Best-effort. Trigger `evaluate_budget_alerts` server-side at most once
     * per 5 minutes. Failures are swallowed because alert delivery is not on
     * the critical path of the alerts list rendering.
     */
    suspend fun maybeEvaluateBudgetAlerts() {
        // Demo mode has no account to evaluate, and must not use up the next account's turn.
        if (isDemoMode) return
        val now = System.currentTimeMillis()
        if (now - lastBudgetEvalAtMs < budgetEvalCooldownMs) return
        lastBudgetEvalAtMs = now
        runCatching { supabase.evaluateBudgetAlerts() }
    }

    /** The session a refresh runs for, read once; none means there is nothing to fetch. */
    private fun currentSession(): SessionContext = tokenStore.snapshot() ?: throw ApiError.TokenExpired

    /** Load cached data into StateFlows, for the current session only. */
    suspend fun loadFromCache() {
        val ctx = tokenStore.snapshot() ?: return
        lifecycle.write(ctx) {
            // Demo mode never shows an account's cached rows.
            if (ctx.isDemo) {
                loadDemoData()
                return@write
            }
            cache.getDashboard()?.let { cached ->
                parseDashboard(cached.json)?.let { _dashboard.value = it }
            }
            val cachedProviders = cache.getProviders().mapNotNull { parseProvider(it.json) }
            if (cachedProviders.isNotEmpty()) _providers.value = cachedProviders

            val cachedSessions = cache.getSessions().mapNotNull { parseSession(it.json) }
            if (cachedSessions.isNotEmpty()) _sessions.value = cachedSessions

            val cachedAlerts = cache.getAlerts().mapNotNull { parseAlert(it.json) }
            if (cachedAlerts.isNotEmpty()) _alerts.value = cachedAlerts

            val cachedDevices = cache.getDevices().mapNotNull { parseDevice(it.json) }
            if (cachedDevices.isNotEmpty()) _devices.value = cachedDevices

            val cachedDailyUsage = cache.getDailyUsage().mapNotNull { parseDailyUsage(it.json) }
            if (cachedDailyUsage.isNotEmpty()) _dailyUsage.value = cachedDailyUsage
            Unit
        }
    }

    /**
     * Demo data into every StateFlow, for demo mode. Every refresh below does this instead of
     * fetching, and never writes Room, so demo rows cannot outlive demo mode and Overview's
     * export menu (which reads these flows) has the same data the tabs show. Called inside
     * [SessionLifecycle.write] only.
     */
    private fun loadDemoData(days: Int = 30) {
        _dashboard.value = DemoDataProvider.dashboard()
        _providers.value = DemoDataProvider.providers()
        _sessions.value = DemoDataProvider.sessions()
        _devices.value = DemoDataProvider.devices()
        _alerts.value = DemoDataProvider.alerts()
        _dailyUsage.value = DemoDataProvider.dailyUsage(days)
    }

    /**
     * Forget everything this singleton holds for the session that ended (sign-out, account
     * deletion, demo exit, a refusal): Overview's export menu reads these flows, and the next
     * account must not export the last one's rows while its own first fetch is still out.
     * Called by [SessionLifecycle] at the end and again by the teardown.
     */
    override fun reset() {
        lastBudgetEvalAtMs = 0L
        _dashboard.value = null
        _providers.value = emptyList()
        _sessions.value = emptyList()
        _devices.value = emptyList()
        _alerts.value = emptyList()
        _dailyUsage.value = emptyList()
    }

    suspend fun refreshAll() = coroutineScope {
        val ctx = currentSession()
        if (ctx.isDemo) {
            lifecycle.write(ctx) { loadDemoData() }
            return@coroutineScope
        }
        // Run all fetches in parallel (like iOS async let pattern)
        launch { refreshDashboard() }
        launch { refreshProviders() }
        launch { refreshSessions() }
        launch { refreshAlerts() }
        launch { refreshDevices() }
        launch { refreshDailyUsage() }
    }

    suspend fun refreshDashboard() {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData() }
        val data = supabase.dashboard(ctx)
        lifecycle.write(ctx) {
            _dashboard.value = data
            cache.saveDashboard(CachedDashboard(json = serializeDashboard(data)))
        }
    }

    suspend fun refreshProviders() {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData() }
        val data = supabase.providers(ctx)
        lifecycle.write(ctx) {
            _providers.value = data
            cache.replaceProviders(data.map { CachedProvider(provider = it.provider, json = serializeProvider(it)) })
        }
    }

    suspend fun refreshSessions() {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData() }
        val data = supabase.sessions(ctx)
        lifecycle.write(ctx) {
            _sessions.value = data
            cache.replaceSessions(data.map { CachedSession(id = it.id, json = serializeSession(it)) })
        }
    }

    suspend fun refreshDevices() {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData() }
        val data = supabase.devices(ctx)
        lifecycle.write(ctx) {
            _devices.value = data
            cache.replaceDevices(data.map { CachedDevice(id = it.id, json = serializeDevice(it)) })
        }
    }

    suspend fun refreshAlerts() {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData() }
        val data = supabase.alerts(ctx)
        lifecycle.write(ctx) {
            _alerts.value = data
            cache.replaceAlerts(data.map { CachedAlert(id = it.id, json = serializeAlert(it)) })
        }
    }

    suspend fun refreshDailyUsage(days: Int = 30) {
        val ctx = currentSession()
        if (ctx.isDemo) return lifecycle.write(ctx) { loadDemoData(days) }
        val data = supabase.dailyUsage(days, ctx)
        lifecycle.write(ctx) {
            _dailyUsage.value = data
            cache.replaceDailyUsage(data.map {
                CachedDailyUsage(id = "${it.date}-${it.provider}-${it.model}", json = serializeDailyUsage(it))
            })
        }
    }

    suspend fun acknowledgeAlert(id: String) {
        supabase.acknowledgeAlert(id)
        refreshAlerts()
    }

    suspend fun resolveAlert(id: String) {
        supabase.resolveAlert(id)
        refreshAlerts()
    }

    suspend fun snoozeAlert(id: String, minutes: Int) {
        supabase.snoozeAlert(id, minutes)
        refreshAlerts()
    }

    // ── Serialization (lightweight JSON) ──

    private fun serializeDashboard(d: DashboardSummary): String = JSONObject().apply {
        put("totalUsageToday", d.totalUsageToday)
        put("totalEstimatedCostToday", d.totalEstimatedCostToday)
        put("totalRequestsToday", d.totalRequestsToday)
        put("activeSessions", d.activeSessions)
        put("onlineDevices", d.onlineDevices)
        put("unresolvedAlerts", d.unresolvedAlerts)
    }.toString()

    private fun parseDashboard(json: String): DashboardSummary? = try {
        val j = JSONObject(json)
        DashboardSummary(
            totalUsageToday = j.optInt("totalUsageToday"),
            totalEstimatedCostToday = j.optDouble("totalEstimatedCostToday", 0.0),
            totalRequestsToday = j.optInt("totalRequestsToday"),
            activeSessions = j.optInt("activeSessions"),
            onlineDevices = j.optInt("onlineDevices"),
            unresolvedAlerts = j.optInt("unresolvedAlerts"),
            alertSummary = AlertSummaryDTO(info = j.optInt("unresolvedAlerts")),
        )
    } catch (_: Exception) { null }

    private fun serializeProvider(p: ProviderUsage): String = JSONObject().apply {
        put("provider", p.provider)
        put("todayUsage", p.todayUsage)
        put("weekUsage", p.weekUsage)
        put("estimatedCostWeek", p.estimatedCostWeek)
        if (p.quota != null) put("quota", p.quota)
        if (p.remaining != null) put("remaining", p.remaining)
        if (p.planType != null) put("planType", p.planType)
        if (p.resetTime != null) put("resetTime", p.resetTime)
        put("statusText", p.statusText)
        put("tiers", JSONArray().apply {
            p.tiers.forEach { t ->
                put(JSONObject().apply {
                    put("name", t.name)
                    put("quota", t.quota)
                    put("remaining", t.remaining)
                    if (t.resetTime != null) put("resetTime", t.resetTime)
                })
            }
        })
    }.toString()

    private fun parseProvider(json: String): ProviderUsage? = try {
        val j = JSONObject(json)
        val tiersArr = j.optJSONArray("tiers")
        val tiers = if (tiersArr != null) (0 until tiersArr.length()).map { i ->
            val t = tiersArr.getJSONObject(i)
            TierDTO(t.optString("name"), t.optInt("quota"), t.optInt("remaining"),
                t.optString("resetTime").takeIf { it.isNotBlank() })
        } else emptyList()
        ProviderUsage(
            provider = j.optString("provider"),
            todayUsage = j.optInt("todayUsage"),
            weekUsage = j.optInt("weekUsage"),
            estimatedCostWeek = j.optDouble("estimatedCostWeek", 0.0),
            quota = if (j.has("quota")) j.optInt("quota") else null,
            remaining = if (j.has("remaining")) j.optInt("remaining") else null,
            planType = j.optString("planType").takeIf { it.isNotBlank() },
            resetTime = j.optString("resetTime").takeIf { it.isNotBlank() },
            statusText = j.optString("statusText", "Operational"),
            tiers = tiers,
        )
    } catch (_: Exception) { null }

    private fun serializeSession(s: SessionRecord): String = JSONObject().apply {
        put("id", s.id); put("name", s.name); put("provider", s.provider)
        put("project", s.project); put("deviceName", s.deviceName)
        put("startedAt", s.startedAt); put("lastActiveAt", s.lastActiveAt)
        put("status", s.status); put("totalUsage", s.totalUsage)
        put("estimatedCost", s.estimatedCost); put("requests", s.requests)
        put("errorCount", s.errorCount)
    }.toString()

    private fun parseSession(json: String): SessionRecord? = try {
        val j = JSONObject(json)
        SessionRecord(
            id = j.optString("id"), name = j.optString("name"),
            provider = j.optString("provider"), project = j.optString("project"),
            deviceName = j.optString("deviceName"), startedAt = j.optString("startedAt"),
            lastActiveAt = j.optString("lastActiveAt"), status = j.optString("status", "Running"),
            totalUsage = j.optInt("totalUsage"), estimatedCost = j.optDouble("estimatedCost", 0.0),
            costStatus = "Estimated", requests = j.optInt("requests"),
            errorCount = j.optInt("errorCount"),
        )
    } catch (_: Exception) { null }

    private fun serializeAlert(a: AlertRecord): String = JSONObject().apply {
        put("id", a.id); put("type", a.type); put("severity", a.severity)
        put("title", a.title); put("message", a.message)
        put("createdAt", a.createdAt); put("isRead", a.isRead)
        put("isResolved", a.isResolved)
    }.toString()

    private fun parseAlert(json: String): AlertRecord? = try {
        val j = JSONObject(json)
        AlertRecord(
            id = j.optString("id"), type = j.optString("type"),
            severity = j.optString("severity", "Info"), title = j.optString("title"),
            message = j.optString("message"), createdAt = j.optString("createdAt"),
            isRead = j.optBoolean("isRead"), isResolved = j.optBoolean("isResolved"),
        )
    } catch (_: Exception) { null }

    private fun serializeDevice(d: DeviceRecord): String = JSONObject().apply {
        put("id", d.id); put("name", d.name); put("type", d.type)
        put("system", d.system); put("status", d.status)
        if (d.lastSyncAt != null) put("lastSyncAt", d.lastSyncAt)
        put("helperVersion", d.helperVersion)
        // v0.60: round-trip the plan map through the existing JSON blob cache
        // (no Room schema/version bump needed).
        if (d.providerPlanStatus.isNotEmpty()) {
            put("providerPlanStatus", JSONObject(d.providerPlanStatus as Map<*, *>))
        }
    }.toString()

    private fun parseDevice(json: String): DeviceRecord? = try {
        val j = JSONObject(json)
        val plan = j.optJSONObject("providerPlanStatus")?.let { obj ->
            val out = LinkedHashMap<String, String>()
            val keys = obj.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                val v = obj.optString(k)
                if (v == "on_plan" || v == "off_plan") out[k] = v
            }
            out
        } ?: emptyMap()
        DeviceRecord(
            id = j.optString("id"), name = j.optString("name"),
            type = j.optString("type", "macOS"), system = j.optString("system"),
            status = j.optString("status", "Offline"),
            lastSyncAt = j.optString("lastSyncAt").takeIf { it.isNotBlank() },
            helperVersion = j.optString("helperVersion"),
            currentSessionCount = 0,
            providerPlanStatus = plan,
        )
    } catch (_: Exception) { null }

    private fun serializeDailyUsage(d: DailyUsage): String = JSONObject().apply {
        put("date", d.date); put("provider", d.provider); put("model", d.model)
        put("inputTokens", d.inputTokens); put("cachedTokens", d.cachedTokens)
        put("outputTokens", d.outputTokens); put("cost", d.cost)
    }.toString()

    private fun parseDailyUsage(json: String): DailyUsage? = try {
        val j = JSONObject(json)
        DailyUsage(
            date = j.optString("date"),
            provider = j.optString("provider"),
            model = j.optString("model"),
            inputTokens = j.optInt("inputTokens"),
            cachedTokens = j.optInt("cachedTokens"),
            outputTokens = j.optInt("outputTokens"),
            cost = j.optDouble("cost", 0.0),
        )
    } catch (_: Exception) { null }
}
