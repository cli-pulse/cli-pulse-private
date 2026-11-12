package com.clipulse.android.data.local

import java.util.Collections

/**
 * An in-memory [CacheDao] that records which method wrote or deleted what. A test can make a
 * table's delete fail ([failingClears]) or hold it at a barrier ([beforeClear]).
 */
internal class FakeCacheDao : CacheDao {
    @Volatile
    private var dashboardRow: CachedDashboard? = null
    private val providerRows = Collections.synchronizedMap(LinkedHashMap<String, CachedProvider>())
    private val sessionRows = Collections.synchronizedMap(LinkedHashMap<String, CachedSession>())
    private val alertRows = Collections.synchronizedMap(LinkedHashMap<String, CachedAlert>())
    private val deviceRows = Collections.synchronizedMap(LinkedHashMap<String, CachedDevice>())
    private val dailyUsageRows = Collections.synchronizedMap(LinkedHashMap<String, CachedDailyUsage>())

    /** Every call by method name, in order. */
    val calls: MutableList<String> = Collections.synchronizedList(mutableListOf())

    /** Table names ("dashboard", "providers", …) whose delete throws. */
    val failingClears: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    /** Runs at the start of every delete, with the table name; may suspend. */
    var beforeClear: suspend (String) -> Unit = {}

    /** Runs at the start of every read, with the table name; may suspend (a slow hydration). */
    var beforeRead: suspend (String) -> Unit = {}

    /** One row in every table, all belonging to [owner]. */
    fun fill(owner: String) {
        dashboardRow = CachedDashboard(json = "{\"owner\":\"$owner\"}")
        providerRows["p-$owner"] = CachedProvider(provider = "p-$owner", json = owner)
        sessionRows["s-$owner"] = CachedSession(id = "s-$owner", json = owner)
        alertRows["a-$owner"] = CachedAlert(id = "a-$owner", json = owner)
        deviceRows["d-$owner"] = CachedDevice(id = "d-$owner", json = owner)
        dailyUsageRows["u-$owner"] = CachedDailyUsage(id = "u-$owner", json = owner)
    }

    /** Every row's json across the six tables. */
    fun allRows(): List<String> {
        val out = mutableListOf<String>()
        dashboardRow?.let { out += it.json }
        synchronized(providerRows) { providerRows.values.forEach { out += it.json } }
        synchronized(sessionRows) { sessionRows.values.forEach { out += it.json } }
        synchronized(alertRows) { alertRows.values.forEach { out += it.json } }
        synchronized(deviceRows) { deviceRows.values.forEach { out += it.json } }
        synchronized(dailyUsageRows) { dailyUsageRows.values.forEach { out += it.json } }
        return out
    }

    fun rowCount(table: String): Int = when (table) {
        "dashboard" -> if (dashboardRow == null) 0 else 1
        "providers" -> providerRows.size
        "sessions" -> sessionRows.size
        "alerts" -> alertRows.size
        "devices" -> deviceRows.size
        "daily_usage" -> dailyUsageRows.size
        else -> error("unknown table $table")
    }

    private suspend fun clear(table: String, delete: () -> Unit) {
        calls += "clear:$table"
        beforeClear(table)
        if (table in failingClears) throw IllegalStateException("delete failed: $table")
        delete()
    }

    override suspend fun getDashboard(): CachedDashboard? {
        // The row is read first, then the call suspends: a read whose result is on its way back.
        val row = dashboardRow
        beforeRead("dashboard")
        return row
    }
    override suspend fun saveDashboard(dashboard: CachedDashboard) {
        calls += "saveDashboard"
        dashboardRow = dashboard
    }
    override suspend fun clearDashboard() = clear("dashboard") { dashboardRow = null }

    override suspend fun getProviders(): List<CachedProvider> = synchronized(providerRows) { providerRows.values.toList() }
    override suspend fun saveProviders(providers: List<CachedProvider>) {
        calls += "saveProviders"
        providers.forEach { providerRows[it.provider] = it }
    }
    override suspend fun clearProviders() = clear("providers") { providerRows.clear() }

    override suspend fun getSessions(): List<CachedSession> = synchronized(sessionRows) { sessionRows.values.toList() }
    override suspend fun saveSessions(sessions: List<CachedSession>) {
        calls += "saveSessions"
        sessions.forEach { sessionRows[it.id] = it }
    }
    override suspend fun clearSessions() = clear("sessions") { sessionRows.clear() }

    override suspend fun getAlerts(): List<CachedAlert> = synchronized(alertRows) { alertRows.values.toList() }
    override suspend fun saveAlerts(alerts: List<CachedAlert>) {
        calls += "saveAlerts"
        alerts.forEach { alertRows[it.id] = it }
    }
    override suspend fun clearAlerts() = clear("alerts") { alertRows.clear() }

    override suspend fun getDevices(): List<CachedDevice> = synchronized(deviceRows) { deviceRows.values.toList() }
    override suspend fun saveDevices(devices: List<CachedDevice>) {
        calls += "saveDevices"
        devices.forEach { deviceRows[it.id] = it }
    }
    override suspend fun clearDevices() = clear("devices") { deviceRows.clear() }

    override suspend fun getDailyUsage(): List<CachedDailyUsage> = synchronized(dailyUsageRows) { dailyUsageRows.values.toList() }
    override suspend fun saveDailyUsage(items: List<CachedDailyUsage>) {
        calls += "saveDailyUsage"
        items.forEach { dailyUsageRows[it.id] = it }
    }
    override suspend fun clearDailyUsage() = clear("daily_usage") { dailyUsageRows.clear() }

    // The real replace methods are @Transaction defaults (clear + save); here each is one
    // recorded call that does not go through the delete hooks above.
    override suspend fun replaceProviders(providers: List<CachedProvider>) {
        calls += "replaceProviders"
        synchronized(providerRows) { providerRows.clear(); providers.forEach { providerRows[it.provider] = it } }
    }
    override suspend fun replaceSessions(sessions: List<CachedSession>) {
        calls += "replaceSessions"
        synchronized(sessionRows) { sessionRows.clear(); sessions.forEach { sessionRows[it.id] = it } }
    }
    override suspend fun replaceAlerts(alerts: List<CachedAlert>) {
        calls += "replaceAlerts"
        synchronized(alertRows) { alertRows.clear(); alerts.forEach { alertRows[it.id] = it } }
    }
    override suspend fun replaceDevices(devices: List<CachedDevice>) {
        calls += "replaceDevices"
        synchronized(deviceRows) { deviceRows.clear(); devices.forEach { deviceRows[it.id] = it } }
    }
    override suspend fun replaceDailyUsage(items: List<CachedDailyUsage>) {
        calls += "replaceDailyUsage"
        synchronized(dailyUsageRows) { dailyUsageRows.clear(); items.forEach { dailyUsageRows[it.id] = it } }
    }

    companion object {
        val TABLES = listOf("dashboard", "providers", "sessions", "alerts", "devices", "daily_usage")
    }
}
