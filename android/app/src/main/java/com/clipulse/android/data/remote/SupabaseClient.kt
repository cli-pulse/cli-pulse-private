package com.clipulse.android.data.remote

import com.clipulse.android.BuildConfig
import com.clipulse.android.data.DemoDataProvider
import com.clipulse.android.data.model.*
import com.clipulse.android.data.session.SessionLifecycle
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.URLEncoder
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * OAuth redirect URI handed to Supabase via `redirect_to`. We use the custom
 * scheme until `clipulse.app` DNS + `/.well-known/assetlinks.json` are deployed,
 * because an HTTPS App Link that does not autoVerify falls through to a browser
 * disambiguator and breaks the round-trip. The HTTPS intent-filter in
 * AndroidManifest is intentionally kept so that flipping back to the App Link
 * after the domain is live is a one-line change here.
 *
 * iOS already passes this same value, so the Supabase project's Auth ->
 * Redirect URLs allow-list does not need a new entry for Android.
 */
internal const val OAUTH_REDIRECT_TO: String = "clipulse://auth/callback"

/**
 * Demo mode ("Try Demo" on the sign-in screen) has no account and no token. Every read a
 * demo user's screens make answers from [DemoDataProvider] before any request is built, and
 * [DemoModeGuard] fails any other request locally, so demo mode never reaches the backend.
 * Before 1.62 each screen fetched for itself and demo mode got 401/400 ("Your session
 * expired") on every tab, while SyncWorker sent register_device + dashboard_summary every
 * 15 minutes without a token.
 *
 * Sessions: every public call works for ONE session, a [SessionContext] passed in or read
 * once at entry, and every request it makes goes through [sendAuthed] for that session. A
 * request is never sent, and a result never returned, for a session that is no longer the
 * current one ([ApiError.SessionSuperseded]); a renewal never hands one session's tokens to
 * another's request; and a session ends only through [TokenStore.endIfCurrent], for the
 * answers [classifyAuthRejection] and [classifyRefreshResponse] list.
 */
class SupabaseClient internal constructor(
    private val tokenStore: TokenStore,
    private val lifecycle: SessionLifecycle,
    private val supabaseUrl: String,
    private val supabaseAnonKey: String,
    httpClientBuilder: OkHttpClient.Builder,
) {
    constructor(tokenStore: TokenStore, lifecycle: SessionLifecycle) : this(
        tokenStore,
        lifecycle,
        BuildConfig.SUPABASE_URL,
        BuildConfig.SUPABASE_ANON_KEY,
        OkHttpClient.Builder(),
    )

    private val jsonMedia = "application/json; charset=utf-8".toMediaType()

    /** One renewal at a time; it guards the token writes, not the reads. */
    private val refreshMutex = Mutex()

    /** Test seam: runs after a request came back for a still-current session, before the caller sees it. */
    @Volatile
    internal var afterRequestHook: (path: String) -> Unit = {}

    /** Test seam: the clock the access-token expiry check reads. */
    @Volatile
    internal var nowMillis: () -> Long = { System.currentTimeMillis() }

    /** Demo mode's alerts, kept so acknowledge / resolve / snooze change what the Alerts tab shows. */
    private val demoAlerts = AtomicReference<List<AlertRecord>?>(null)

    private val client = httpClientBuilder
        .addInterceptor(DemoModeGuard(tokenStore))
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()

    /** The current session, read once. Hand it to every call of one operation. */
    fun session(): SessionContext? = tokenStore.snapshot()

    private fun sessionOrThrow(ctx: SessionContext?): SessionContext =
        ctx ?: tokenStore.snapshot() ?: throw ApiError.TokenExpired

    // ── Auth ──────────────────────────────────────────────

    suspend fun signInWithGoogle(idToken: String, name: String?, email: String?): AuthResponse =
        withContext(Dispatchers.IO) {
            val attempt = tokenStore.beginAuthAttempt()
            val body = JSONObject().apply {
                put("provider", "google")
                put("id_token", idToken)
                if (name != null) put("name", name)
            }
            val json = postUnauthenticated("$supabaseUrl/auth/v1/token?grant_type=id_token", body)
            handleAuthResponse(attempt, json, email, receivedAtMillis = nowMillis())
        }

    suspend fun sendOTP(email: String): Unit = withContext(Dispatchers.IO) {
        val body = JSONObject().apply {
            put("email", email)
            put("create_user", true)
        }
        postUnauthenticated("$supabaseUrl/auth/v1/otp", body)
    }

    suspend fun verifyOTP(email: String, code: String): AuthResponse =
        withContext(Dispatchers.IO) {
            val attempt = tokenStore.beginAuthAttempt()
            val body = JSONObject().apply {
                put("email", email)
                put("token", code)
                put("type", "email")
            }
            val json = postUnauthenticated("$supabaseUrl/auth/v1/verify", body)
            handleAuthResponse(attempt, json, email, receivedAtMillis = nowMillis())
        }

    suspend fun signInWithPassword(email: String, password: String): AuthResponse =
        withContext(Dispatchers.IO) {
            val attempt = tokenStore.beginAuthAttempt()
            val body = JSONObject().apply {
                put("email", email)
                put("password", password)
            }
            val json = postUnauthenticated("$supabaseUrl/auth/v1/token?grant_type=password", body)
            handleAuthResponse(attempt, json, email, receivedAtMillis = nowMillis())
        }

    /**
     * Validates [ctx]'s session with the server and refreshes its profile. Both requests run
     * for that one session; the profile is stored only if it is still current.
     */
    suspend fun me(ctx: SessionContext? = null): AuthResponse = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        val json = get(session, "$supabaseUrl/auth/v1/user")
        val userId = json.optString("id")
        val metadata = json.optJSONObject("user_metadata") ?: JSONObject()

        val profile = restGetArray(session, "/rest/v1/profiles?id=eq.${enc(userId)}&select=paired,name,email")
        val p = profile.optJSONObject(0) ?: JSONObject()
        val name = p.optString("name", metadata.optString("name", ""))
        val email = p.optString("email", json.optString("email", ""))

        if (!tokenStore.setProfileIfCurrent(session.sessionId, userId, name, email)) {
            throw ApiError.SessionSuperseded
        }
        val now = tokenStore.snapshotIfCurrent(session.sessionId) ?: throw ApiError.SessionSuperseded
        AuthResponse(
            access_token = now.accessToken ?: "",
            refresh_token = now.refreshToken,
            user = UserDTO(id = userId, name = name, email = email),
            paired = p.optBoolean("paired", false),
            sessionId = session.sessionId,
        )
    }

    /**
     * Ends the current session on this device, then asks the server to revoke it with the
     * token captured in the same step.
     */
    suspend fun signOut(): Unit = withContext(Dispatchers.IO) {
        val ended = lifecycle.endCurrent(EndReason.UserSignedOut) ?: return@withContext
        revoke(ended.accessToken)
    }

    /**
     * Asks the server to revoke [token] and touches nothing on this device, so it can still be
     * running after the next account has signed in (see SettingsViewModel.signOut, which ends
     * the local session itself before the screen changes).
     */
    suspend fun revokeSession(token: String?): Unit = withContext(Dispatchers.IO) {
        revoke(token)
    }

    private fun revoke(token: String?) {
        if (token != null) {
            try {
                val req = Request.Builder()
                    .url("$supabaseUrl/auth/v1/logout")
                    .post("{}".toRequestBody(jsonMedia))
                    .addHeader("apikey", supabaseAnonKey)
                    .addHeader("Authorization", "Bearer $token")
                    .build()
                client.newCall(req).execute().close()
            } catch (_: Exception) { }
        }
    }

    // ── Dashboard ────────────────────────────────────────

    suspend fun dashboard(ctx: SessionContext? = null): DashboardSummary = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext DemoDataProvider.dashboard()
        // v0.42 (2026-05-08): pass the device's local-TZ today so the server
        // computes today/30-day windows against the user's wall clock instead
        // of UTC. Server falls back to current_date if param absent (default
        // NULL via PostgREST), so callers on older servers still work.
        val json = rpc(session, "dashboard_summary", JSONObject().apply {
            put("p_user_today", localTodayKey())
        })
        DashboardSummary(
            totalUsageToday = json.optInt("today_usage"),
            totalEstimatedCostToday = json.optDouble("today_cost", 0.0),
            costStatus = "Estimated",
            totalRequestsToday = json.optInt("today_sessions"),
            activeSessions = json.optInt("active_sessions"),
            onlineDevices = json.optInt("online_devices"),
            unresolvedAlerts = json.optInt("unresolved_alerts"),
            alertSummary = AlertSummaryDTO(info = json.optInt("unresolved_alerts")),
        )
    }

    // ── Providers ────────────────────────────────────────

    suspend fun providers(ctx: SessionContext? = null): List<ProviderUsage> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext DemoDataProvider.providers()
        // v0.42: same local-TZ today fix as dashboard().
        val arr = rpcArray(session, "provider_summary", JSONObject().apply {
            put("p_user_today", localTodayKey())
        })
        (0 until arr.length()).map { i ->
            val p = arr.getJSONObject(i)
            val tiersArr = p.optJSONArray("tiers")
            val tiers = if (tiersArr != null) {
                (0 until tiersArr.length()).map { j ->
                    val t = tiersArr.getJSONObject(j)
                    TierDTO(
                        // optStringOrNull, not optString(key, fallback): on a device a JSON
                        // null comes back as the string "null" (the JVM org.json in unit
                        // tests returns the fallback), and the tier bar would read "null".
                        name = t.optStringOrNull("name") ?: "Default",
                        quota = t.optInt("quota"),
                        remaining = t.optInt("remaining"),
                        resetTime = t.optString("reset_time").takeIf { it.isNotBlank() },
                    )
                }
            } else emptyList()

            ProviderUsage(
                provider = p.optString("provider"),
                todayUsage = p.optInt("today_usage"),
                weekUsage = p.optInt("total_usage"),
                estimatedCostWeek = p.optDouble("estimated_cost", 0.0),
                quota = p.optIntOrNull("quota"),
                remaining = p.optIntOrNull("remaining"),
                planType = p.optString("plan_type").takeIf { it.isNotBlank() },
                resetTime = p.optString("reset_time").takeIf { it.isNotBlank() },
                tiers = tiers,
            )
        }
    }

    // ── Sessions ─────────────────────────────────────────

    suspend fun sessions(ctx: SessionContext? = null): List<SessionRecord> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext DemoDataProvider.sessions()
        val userId = enc(session.userId ?: "")
        val arr = restGetArray(
            session,
            "/rest/v1/sessions?user_id=eq.$userId&select=*,devices(name)&order=last_active_at.desc&limit=50",
        )
        (0 until arr.length()).map { i ->
            val r = arr.getJSONObject(i)
            val device = r.optJSONObject("devices")
            SessionRecord(
                id = r.optString("id"),
                name = r.optString("name"),
                provider = r.optString("provider"),
                project = r.optString("project"),
                deviceName = device?.optString("name") ?: "",
                startedAt = r.optString("started_at"),
                lastActiveAt = r.optString("last_active_at"),
                status = r.optString("status", "Running"),
                totalUsage = r.optInt("total_usage"),
                estimatedCost = r.optDouble("estimated_cost", 0.0),
                costStatus = "Estimated",
                requests = r.optInt("requests"),
                errorCount = r.optInt("error_count"),
                collectionConfidence = r.optString("collection_confidence").takeIf { it.isNotBlank() },
            )
        }
    }

    // ── Daily Usage ──────────────────────────────────────

    suspend fun dailyUsage(days: Int = 30, ctx: SessionContext? = null): List<DailyUsage> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext DemoDataProvider.dailyUsage(days)
        val params = JSONObject().put("days", days)
        val arr = rpcArray(session, "get_daily_usage", params)
        (0 until arr.length()).mapNotNull { i ->
            val r = arr.getJSONObject(i)
            val date = r.optString("metric_date").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val provider = r.optString("provider").takeIf { it.isNotBlank() } ?: return@mapNotNull null
            val model = r.optString("model").takeIf { it.isNotBlank() } ?: ""
            DailyUsage(
                date = date,
                provider = provider,
                model = model,
                inputTokens = r.optInt("input_tokens"),
                cachedTokens = r.optInt("cached_tokens"),
                outputTokens = r.optInt("output_tokens"),
                cost = r.optDouble("cost", 0.0),
            )
        }
    }

    // ── Devices ──────────────────────────────────────────

    suspend fun devices(ctx: SessionContext? = null): List<DeviceRecord> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext DemoDataProvider.devices()
        val userId = enc(session.userId ?: "")
        val arr = restGetArray(
            session,
            "/rest/v1/devices?user_id=eq.$userId&select=*&order=last_seen_at.desc",
        )
        (0 until arr.length()).map { i ->
            val r = arr.getJSONObject(i)
            DeviceRecord(
                id = r.optString("id"),
                name = r.optString("name"),
                type = r.optString("type", "macOS"),
                system = r.optString("system"),
                status = r.optString("status", "Offline"),
                lastSyncAt = r.optString("last_seen_at").takeIf { it.isNotBlank() },
                helperVersion = r.optString("helper_version"),
                currentSessionCount = 0,
                cpuUsage = r.optIntOrNull("cpu_usage"),
                memoryUsage = r.optIntOrNull("memory_usage"),
                providerPlanStatus = parseProviderPlanStatus(r.optJSONObject("provider_plan_status")),
                cpuTempC = r.optDoubleOrNull("cpu_temp_c"),
                gpuTempC = r.optDoubleOrNull("gpu_temp_c"),
                cpuPowerW = r.optDoubleOrNull("cpu_power_w"),
                systemPowerW = r.optDoubleOrNull("system_power_w"),
                fanRpm = r.optIntOrNull("fan_rpm"),
                fanMaxRpm = r.optIntOrNull("fan_max_rpm"),
                thermalState = r.optIntOrNull("thermal_state"),
                batteryChargePct = r.optIntOrNull("battery_charge_pct"),
                batteryState = r.optStringOrNull("battery_state"),
                batteryCycleCount = r.optIntOrNull("battery_cycle_count"),
                batteryHealthPct = r.optDoubleOrNull("battery_health_pct"),
                adapterWatts = r.optDoubleOrNull("adapter_watts"),
                sensorsCapability = parseSensorsCapability(r.optJSONObject("sensors_capability")),
                sensorsUpdatedAt = r.optStringOrNull("sensors_updated_at"),
            )
        }
    }

    // v0.60: defensively parse the provider_plan_status jsonb into a map, keeping
    // ONLY string values in on_plan/off_plan (ignore arrays/scalars/bad values).
    private fun parseProviderPlanStatus(obj: org.json.JSONObject?): Map<String, String> {
        if (obj == null) return emptyMap()
        val out = LinkedHashMap<String, String>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = obj.optString(k)
            if (v == "on_plan" || v == "off_plan") out[k] = v
        }
        return out
    }


    // ── Alerts ───────────────────────────────────────────

    suspend fun alerts(ctx: SessionContext? = null): List<AlertRecord> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext currentDemoAlerts()
        val userId = enc(session.userId ?: "")
        val arr = restGetArray(
            session,
            "/rest/v1/alerts?user_id=eq.$userId&select=*&order=created_at.desc&limit=50",
        )
        (0 until arr.length()).map { i ->
            val r = arr.getJSONObject(i)
            AlertRecord(
                id = r.optString("id"),
                type = r.optString("type"),
                severity = r.optString("severity", "Info"),
                title = r.optString("title"),
                message = r.optString("message"),
                createdAt = r.optString("created_at"),
                isRead = r.optBoolean("is_read"),
                isResolved = r.optBoolean("is_resolved"),
                acknowledgedAt = r.optString("acknowledged_at").takeIf { it.isNotBlank() },
                snoozedUntil = r.optString("snoozed_until").takeIf { it.isNotBlank() },
                relatedProjectId = r.optString("related_project_id").takeIf { it.isNotBlank() },
                relatedProjectName = r.optString("related_project_name").takeIf { it.isNotBlank() },
                relatedSessionId = r.optString("related_session_id").takeIf { it.isNotBlank() },
                relatedSessionName = r.optString("related_session_name").takeIf { it.isNotBlank() },
                relatedProvider = r.optString("related_provider").takeIf { it.isNotBlank() },
                relatedDeviceName = r.optString("related_device_name").takeIf { it.isNotBlank() },
                sourceKind = r.optString("source_kind").takeIf { it.isNotBlank() },
                sourceId = r.optString("source_id").takeIf { it.isNotBlank() },
                groupingKey = r.optString("grouping_key").takeIf { it.isNotBlank() },
                suppressionKey = r.optString("suppression_key").takeIf { it.isNotBlank() },
            )
        }
    }

    suspend fun acknowledgeAlert(id: String, ctx: SessionContext? = null) = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) {
            updateDemoAlert(id) { it.copy(isRead = true, acknowledgedAt = isoNow()) }
            return@withContext
        }
        val userId = enc(session.userId ?: "")
        restPatch(
            session,
            "/rest/v1/alerts?id=eq.${enc(id)}&user_id=eq.$userId",
            JSONObject().apply {
                put("acknowledged_at", isoNow())
                put("is_read", true)
            },
        )
    }

    suspend fun resolveAlert(id: String, ctx: SessionContext? = null) = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) {
            updateDemoAlert(id) { it.copy(isResolved = true) }
            return@withContext
        }
        val userId = enc(session.userId ?: "")
        restPatch(
            session,
            "/rest/v1/alerts?id=eq.${enc(id)}&user_id=eq.$userId",
            JSONObject().apply { put("is_resolved", true) },
        )
    }

    suspend fun snoozeAlert(id: String, minutes: Int, ctx: SessionContext? = null) = withContext(Dispatchers.IO) {
        val until = isoAt(System.currentTimeMillis() + minutes * 60_000L)
        val session = sessionOrThrow(ctx)
        if (session.isDemo) {
            updateDemoAlert(id) { it.copy(snoozedUntil = until) }
            return@withContext
        }
        val userId = enc(session.userId ?: "")
        restPatch(
            session,
            "/rest/v1/alerts?id=eq.${enc(id)}&user_id=eq.$userId",
            JSONObject().apply { put("snoozed_until", until) },
        )
    }

    // ── Settings ─────────────────────────────────────────

    suspend fun settings(ctx: SessionContext? = null): SettingsSnapshot = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext SettingsSnapshot()
        val userId = enc(session.userId ?: "")
        val arr = restGetArray(session, "/rest/v1/user_settings?user_id=eq.$userId&select=*")
        val s = arr.optJSONObject(0) ?: JSONObject()
        SettingsSnapshot(
            notificationsEnabled = s.optBoolean("notifications_enabled", true),
            pushPolicy = s.optString("push_policy", "Warnings + Critical"),
            digestEnabled = s.optBoolean("digest_notifications_enabled", true),
            digestIntervalHours = maxOf(1, s.optInt("digest_interval_minutes", 60) / 60),
            usageSpikeThreshold = s.optInt("usage_spike_threshold", 500),
            projectBudgetThresholdUsd = s.optDouble("project_budget_threshold_usd", 0.25),
            sessionTooLongThresholdMinutes = s.optInt("session_too_long_threshold_minutes", 180),
            offlineGracePeriodMinutes = s.optInt("offline_grace_period_minutes", 5),
            repeatedFailureThreshold = s.optInt("repeated_failure_threshold", 3),
            alertCooldownMinutes = s.optInt("alert_cooldown_minutes", 30),
            dataRetentionDays = s.optInt("data_retention_days", 7),
            webhookUrl = s.optString("webhook_url").takeIf { it.isNotBlank() },
            webhookEnabled = s.optBoolean("webhook_enabled", false),
            webhookEventFilter = s.optJSONObject("webhook_event_filter")?.let { f ->
                WebhookEventFilter(
                    severities = f.optJSONArray("severities")?.let { a -> (0 until a.length()).map { a.getString(it) } },
                    types = f.optJSONArray("types")?.let { a -> (0 until a.length()).map { a.getString(it) } },
                    providers = f.optJSONArray("providers")?.let { a -> (0 until a.length()).map { a.getString(it) } },
                )
            },
        )
    }

    suspend fun updateSettings(patch: JSONObject, ctx: SessionContext? = null): Unit = withContext(Dispatchers.IO) {
        val session = ctx ?: tokenStore.snapshot() ?: return@withContext
        val userId = enc(session.userId ?: return@withContext)
        restPatch(session, "/rest/v1/user_settings?user_id=eq.$userId", patch)
    }

    /**
     * Iter2 fix: Swift clients trigger this RPC every refresh cycle so cron-
     * generated alerts (cost spike etc.) land in the user's feed; Android
     * never did, so Android-only users got no budget/spike alerts at all.
     * Best-effort + caller-throttled (see DashboardRepository) so we don't
     * hammer the DB on every 30s polling cycle.
     */
    suspend fun evaluateBudgetAlerts(ctx: SessionContext? = null): Int = withContext(Dispatchers.IO) {
        try {
            val session = sessionOrThrow(ctx)
            if (session.isDemo) return@withContext 0
            val json = rpc(session, "evaluate_budget_alerts")
            json.optInt("alerts_created", 0)
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            0
        }
    }

    suspend fun testWebhook(ctx: SessionContext? = null): Unit = withContext(Dispatchers.IO) {
        val session = ctx ?: tokenStore.snapshot() ?: return@withContext
        val userId = session.userId ?: return@withContext
        val body = JSONObject().apply {
            put("user_id", userId)
            put("alert", JSONObject().apply {
                put("type", "Test")
                put("severity", "Info")
                put("title", "CLI Pulse webhook test")
                put("message", "If you see this, your webhook integration is working correctly.")
            })
        }
        post(session, "$supabaseUrl/functions/v1/send-webhook", body)
    }

    // ── Server Tier ──────────────────────────────────────

    suspend fun serverTier(ctx: SessionContext? = null): String = withContext(Dispatchers.IO) {
        try {
            val session = sessionOrThrow(ctx)
            if (session.isDemo) return@withContext "free"
            val json = rpc(session, "get_user_tier")
            json.optString("tier", "free")
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            "free"
        }
    }

    // ── Receipt Validation ─────────────────────────────────

    data class ReceiptResult(val verified: Boolean, val tier: String, val isNetworkError: Boolean = false)

    suspend fun validateReceipt(
        purchaseToken: String,
        productId: String,
        ctx: SessionContext? = null,
    ): ReceiptResult = withContext(Dispatchers.IO) {
        try {
            val session = sessionOrThrow(ctx)
            val body = JSONObject().apply {
                put("platform", "google")
                put("purchaseToken", purchaseToken)
                put("productId", productId)
                put("packageName", "com.clipulse.android")
            }
            sendAuthed(session, "$supabaseUrl/functions/v1/validate-receipt") {
                post(body.toString().toRequestBody(jsonMedia))
                header("Content-Type", "application/json")
            }.use { r ->
                if (r.code >= 500) {
                    // Server error (transient) — treat like network error for retry
                    return@withContext ReceiptResult(false, "free", isNetworkError = true)
                }
                if (!r.isSuccessful) return@withContext ReceiptResult(false, "free")
                val json = JSONObject(r.body?.string() ?: "{}")
                ReceiptResult(
                    verified = json.optBoolean("verified", false),
                    tier = json.optString("tier", "free"),
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (_: java.io.IOException) {
            // Network error — distinguishable from server rejection
            ReceiptResult(false, "free", isNetworkError = true)
        } catch (_: ApiError.Http) {
            // The receipt endpoint's own answers are read above and never thrown: an Http error
            // here is the session renewal failing (5xx, 429, offline proxy). Not a rejection of
            // the purchase, so the caller keeps the current tier and retries.
            ReceiptResult(false, "free", isNetworkError = true)
        } catch (_: ApiError.SessionSuperseded) {
            // The account changed during the check: nothing was decided about this purchase.
            ReceiptResult(false, "free", isNetworkError = true)
        } catch (_: Exception) {
            ReceiptResult(false, "free")
        }
    }

    // ── Device Registration ──────────────────────────────

    suspend fun registerDevice(
        ctx: SessionContext,
        name: String,
        type: String = "Android",
        system: String,
    ): String = withContext(Dispatchers.IO) {
        val userId = ctx.userId ?: throw ApiError.TokenExpired
        val body = JSONObject().apply {
            put("user_id", userId)
            put("name", name)
            put("type", type)
            put("system", system)
            put("status", "Online")
            put("helper_version", "1.0.0")
        }
        sendAuthed(ctx, "$supabaseUrl/rest/v1/devices") {
            post(body.toString().toRequestBody(jsonMedia))
            header("Content-Type", "application/json")
            header("Prefer", "return=representation")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            val arr = JSONArray(r.body?.string() ?: "[]")
            arr.getJSONObject(0).optString("id")
        }
    }

    suspend fun updatePushToken(ctx: SessionContext, deviceId: String, token: String): Unit =
        withContext(Dispatchers.IO) {
            val body = JSONObject().apply {
                put("push_token", token)
                put("push_platform", "fcm")
            }
            sendAuthed(ctx, "$supabaseUrl/rest/v1/devices?id=eq.${enc(deviceId)}") {
                patch(body.toString().toRequestBody(jsonMedia))
                header("Content-Type", "application/json")
            }.use { r ->
                if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            }
        }

    suspend fun syncProviderQuotas(ctx: SessionContext, results: List<ProviderQuotaPayload>): Unit =
        withContext(Dispatchers.IO) {
            val userId = ctx.userId ?: return@withContext
            if (results.isEmpty()) return@withContext

            val arr = JSONArray()
            for (r in results) {
                arr.put(JSONObject().apply {
                    put("user_id", userId)
                    put("provider", r.provider)
                    put("remaining", r.remaining)
                    put("quota", r.quota)
                    if (r.planType != null) put("plan_type", r.planType)
                    if (r.resetTime != null) put("reset_time", r.resetTime)
                    put("tiers", JSONArray(r.tiersJson))
                    put("updated_at", isoNow())
                })
            }
            sendAuthed(ctx, "$supabaseUrl/rest/v1/provider_quotas") {
                post(arr.toString().toRequestBody(jsonMedia))
                header("Content-Type", "application/json")
                header("Prefer", "resolution=merge-duplicates")
            }.use { r ->
                if (!r.isSuccessful) {
                    // Log but don't throw — quota sync is non-critical
                    android.util.Log.w("SupabaseClient", "syncProviderQuotas failed: ${r.code}")
                }
            }
        }

    data class ProviderQuotaPayload(
        val provider: String,
        val remaining: Int,
        val quota: Int,
        val planType: String? = null,
        val resetTime: String? = null,
        val tiersJson: String = "[]",
    )

    // ── OAuth PKCE (GitHub / Google via Supabase) ─────────

    /** Build a Supabase OAuth authorize URL with PKCE challenge. Returns (url, codeVerifier, state). */
    fun oauthAuthorizeUrl(provider: String): Triple<String, String, String> {
        val verifier = generateCodeVerifier()
        val challenge = sha256Base64Url(verifier)
        val state = generateCodeVerifier().take(32) // random state for CSRF protection
        // Custom scheme until clipulse.app DNS / assetlinks.json is restored. The
        // HTTPS App Link intent-filter in AndroidManifest stays in place so we can
        // flip back to `https://clipulse.app/auth/callback` once the domain is live
        // -- no Supabase allow-list change needed (iOS already uses this scheme).
        val redirectTo = URLEncoder.encode(OAUTH_REDIRECT_TO, "UTF-8")
        val url = "$supabaseUrl/auth/v1/authorize" +
            "?provider=$provider" +
            "&redirect_to=$redirectTo" +
            "&code_challenge=$challenge" +
            "&code_challenge_method=S256" +
            "&state=$state"
        return Triple(url, verifier, state)
    }

    /**
     * Exchange an OAuth authorization code for a Supabase session (PKCE). Returns the id of
     * the session it installed.
     *
     * [authGeneration] is the sign-in generation saved with the pending flow when the user
     * left for the browser (TokenStore.beginOAuthLogin), carried through the claim and the
     * delivery. A callback does not become the newest attempt by arriving late: if any
     * sign-in or demo entry happened since the flow started, it installs
     * nothing ([ApiError.SessionSuperseded]). A flow without a generation (saved by 1.62)
     * cannot prove it is still the latest and is dropped the same way.
     */
    suspend fun exchangeOAuthCode(code: String, codeVerifier: String, authGeneration: Long?): String =
        withContext(Dispatchers.IO) {
            if (authGeneration == null || authGeneration != tokenStore.authGeneration) {
                throw ApiError.SessionSuperseded
            }
            val body = JSONObject().apply {
                put("auth_code", code)
                put("code_verifier", codeVerifier)
            }
            val req = Request.Builder()
                .url("$supabaseUrl/auth/v1/token?grant_type=pkce")
                .post(body.toString().toRequestBody(jsonMedia))
                .addHeader("Content-Type", "application/json")
                .addHeader("apikey", supabaseAnonKey)
                .build()
            val parsed = client.newCall(req).execute().use { r ->
                val receivedAt = nowMillis()
                val responseBody = r.body?.string() ?: ""
                if (!r.isSuccessful) throw ApiError.Http(r.code, responseBody)
                val json = JSONObject(responseBody)
                // Use optString + explicit guard (not throwing getString) so a
                // partial/non-conforming token response surfaces as a typed
                // ApiError instead of an uncaught JSONException crashing the
                // auth flow.
                val at = json.optString("access_token")
                val rt = json.optString("refresh_token")
                if (at.isBlank() || rt.isBlank()) {
                    throw ApiError.Http(r.code, "OAuth code exchange: missing access/refresh token in response")
                }
                val user = json.optJSONObject("user")
                val meta = user?.optJSONObject("user_metadata")
                OAuthSession(
                    accessToken = at,
                    refreshToken = rt,
                    userId = user?.optString("id") ?: "",
                    name = meta?.optString("name") ?: meta?.optString("full_name") ?: "",
                    email = user?.optString("email") ?: "",
                    receivedAtMillis = receivedAt,
                )
            }
            // A caller cancelled while the exchange was out installs nothing.
            currentCoroutineContext().ensureActive()
            lifecycle.install(
                accessToken = parsed.accessToken,
                refreshToken = parsed.refreshToken,
                userId = parsed.userId,
                userName = parsed.name,
                userEmail = parsed.email,
                attempt = authGeneration,
                receivedAtMillis = parsed.receivedAtMillis,
            ) ?: throw ApiError.SessionSuperseded
        }

    private class OAuthSession(
        val accessToken: String,
        val refreshToken: String,
        val userId: String,
        val name: String,
        val email: String,
        /** When the answer arrived ([nowMillis]): the token's lifetime runs from then. */
        val receivedAtMillis: Long,
    )

    // ── Identity Linking ──────────────────────────────────

    /** List OAuth identities linked to the current user. */
    suspend fun userIdentities(ctx: SessionContext? = null): List<UserIdentity> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        if (session.isDemo) return@withContext emptyList()
        val json = get(session, "$supabaseUrl/auth/v1/user")
        val arr = json.optJSONArray("identities") ?: JSONArray()
        (0 until arr.length()).mapNotNull { i ->
            val row = arr.optJSONObject(i) ?: return@mapNotNull null
            val identityId = row.optString("identity_id", null) ?: row.optString("id", null)
                ?: return@mapNotNull null
            val provider = row.optString("provider", "") ?: ""
            val data = row.optJSONObject("identity_data")
            val email = data?.optString("email", null) ?: row.optString("email", null)
            val createdAt = row.optString("created_at", null)
            UserIdentity(id = identityId, provider = provider, email = email, createdAt = createdAt)
        }
    }

    /**
     * Build a Supabase link-identity authorization URL (PKCE) for Google/GitHub.
     * Requires a valid current session. Returns (authorizationURL, codeVerifier, state).
     * The `state` is a CSRF token that Supabase propagates through the OAuth roundtrip
     * and echoes back in the redirect — callers must verify it matches before exchanging.
     */
    suspend fun linkIdentityAuthorizeUrl(
        provider: String,
        ctx: SessionContext? = null,
    ): Triple<String, String, String> = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        val verifier = generateCodeVerifier()
        val challenge = sha256Base64Url(verifier)
        val state = generateCodeVerifier().take(32)
        // See `OAUTH_REDIRECT_TO` -- same custom-scheme rationale as login.
        val redirectTo = URLEncoder.encode(OAUTH_REDIRECT_TO, "UTF-8")
        val url = "$supabaseUrl/auth/v1/user/identities/authorize" +
            "?provider=$provider" +
            "&redirect_to=$redirectTo" +
            "&code_challenge=$challenge" +
            "&code_challenge_method=S256" +
            "&state=$state" +
            "&skip_http_redirect=true"
        sendAuthed(session, url) { get() }.use { r ->
            val responseBody = r.body?.string() ?: ""
            if (!r.isSuccessful) throw ApiError.Http(r.code, responseBody)
            val json = JSONObject(responseBody)
            val authUrl = json.optString("url")
            if (authUrl.isNullOrEmpty()) throw ApiError.Http(500, "No url in authorize response")
            Triple(authUrl, verifier, state)
        }
    }

    /**
     * Exchange a link-identity PKCE code for the session the link was started from
     * ([sessionId], from the pending flow MainActivity claimed; TokenStore binds a 1.62 flow
     * to its session at the claim). The rotated tokens are stored only for that session and
     * only while it is current: a callback that arrives after a sign-out, or after the next
     * account signed in, changes nothing.
     *
     * The whole exchange, request and commit, holds the refresh mutex: it produces tokens
     * like a renewal does, and a renewal must not land between this request and its commit
     * (or the reverse), so neither can overwrite the other's newer pair.
     */
    suspend fun exchangeOAuthCodeForLink(code: String, codeVerifier: String, sessionId: String): Unit =
        withContext(Dispatchers.IO) {
            refreshMutex.withLock {
                val session = tokenStore.snapshotIfCurrent(sessionId) ?: throw ApiError.SessionSuperseded
                if (session.isDemo) throw DemoModeRequestBlocked("$supabaseUrl/auth/v1/token")
                val body = JSONObject().apply {
                    put("auth_code", code)
                    put("code_verifier", codeVerifier)
                }
                val req = Request.Builder()
                    .url("$supabaseUrl/auth/v1/token?grant_type=pkce")
                    .post(body.toString().toRequestBody(jsonMedia))
                    .addHeader("Content-Type", "application/json")
                    .addHeader("apikey", supabaseAnonKey)
                    .build()
                val (at, rt, receivedAt) = client.newCall(req).execute().use { r ->
                    val arrivedAt = nowMillis()
                    val responseBody = r.body?.string() ?: ""
                    if (!r.isSuccessful) throw ApiError.Http(r.code, responseBody)
                    val json = JSONObject(responseBody)
                    Triple(json.optString("access_token", ""), json.optString("refresh_token", ""), arrivedAt)
                }
                currentCoroutineContext().ensureActive()
                if (at.isBlank() || rt.isBlank()) {
                    if (tokenStore.snapshotIfCurrent(sessionId) == null) throw ApiError.SessionSuperseded
                } else if (!tokenStore.rotateIfCurrent(sessionId, at, rt, receivedAt)) {
                    throw ApiError.SessionSuperseded
                }
                Unit
            }
        }

    /** Unlink a given identity from the current user. */
    suspend fun unlinkIdentity(identityId: String, ctx: SessionContext? = null): Unit = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        val encodedId = URLEncoder.encode(identityId, "UTF-8")
        sendAuthed(session, "$supabaseUrl/auth/v1/user/identities/$encodedId") { delete() }.use { r ->
            val responseBody = r.body?.string() ?: ""
            if (!r.isSuccessful) throw ApiError.Http(r.code, responseBody)
        }
    }

    // java.util.Base64 (API 26 = minSdk), not android.util.Base64: the same bytes, and it
    // runs in JVM unit tests.
    private fun generateCodeVerifier(): String {
        val bytes = ByteArray(32)
        java.security.SecureRandom().nextBytes(bytes)
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    private fun sha256Base64Url(input: String): String {
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(input.toByteArray())
        return java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(digest)
    }

    // ── Health ────────────────────────────────────────────

    suspend fun health(): Boolean = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url("$supabaseUrl/auth/v1/health")
                .get()
                .addHeader("apikey", supabaseAnonKey)
                .build()
            val resp = client.newCall(req).execute()
            resp.use { it.isSuccessful }
        } catch (_: Exception) {
            false
        }
    }

    // ── Teams ─────────────────────────────────────────────

    suspend fun rpcPublic(function: String, params: JSONObject = JSONObject(), ctx: SessionContext? = null): JSONObject =
        withContext(Dispatchers.IO) { rpc(sessionOrThrow(ctx), function, params) }

    data class TeamInfo(val id: String, val name: String, val role: String)

    suspend fun fetchTeamsForUser(userId: String, ctx: SessionContext? = null): List<TeamInfo> = withContext(Dispatchers.IO) {
        val arr = restGetArray(
            sessionOrThrow(ctx),
            "/rest/v1/team_members?user_id=eq.${enc(userId)}&select=role,teams(id,name)",
        )
        (0 until arr.length()).mapNotNull { i ->
            val row = arr.getJSONObject(i)
            val team = row.optJSONObject("teams") ?: return@mapNotNull null
            TeamInfo(
                id = team.optString("id"),
                name = team.optString("name"),
                role = row.optString("role", "member"),
            )
        }
    }

    data class TeamMemberInfo(val userId: String, val name: String, val email: String, val role: String)

    suspend fun fetchTeamMembers(teamId: String, ctx: SessionContext? = null): List<TeamMemberInfo> = withContext(Dispatchers.IO) {
        val arr = restGetArray(
            sessionOrThrow(ctx),
            "/rest/v1/team_members?team_id=eq.${enc(teamId)}&select=role,user_id,profiles(name,email)",
        )
        (0 until arr.length()).mapNotNull { i ->
            val row = arr.getJSONObject(i)
            val profile = row.optJSONObject("profiles") ?: return@mapNotNull null
            TeamMemberInfo(
                userId = row.optString("user_id"),
                name = profile.optString("name"),
                email = profile.optString("email"),
                role = row.optString("role", "member"),
            )
        }
    }

    data class TeamInviteInfo(val id: String, val email: String, val role: String, val createdAt: String)

    suspend fun fetchTeamDetails(
        teamId: String,
        ctx: SessionContext? = null,
    ): Pair<List<TeamMemberInfo>, List<TeamInviteInfo>> = withContext(Dispatchers.IO) {
        val result = rpc(sessionOrThrow(ctx), "team_details", JSONObject().apply { put("p_team_id", teamId) })
        val membersArr = result.optJSONArray("members") ?: JSONArray()
        val invitesArr = result.optJSONArray("invites") ?: JSONArray()
        val members = (0 until membersArr.length()).mapNotNull { i ->
            val row = membersArr.getJSONObject(i)
            TeamMemberInfo(
                userId = row.optString("user_id"),
                name = row.optString("name"),
                email = row.optString("email"),
                role = row.optString("role", "member"),
            )
        }
        val invites = (0 until invitesArr.length()).map { i ->
            val row = invitesArr.getJSONObject(i)
            TeamInviteInfo(
                id = row.optString("id"),
                email = row.optString("email"),
                role = row.optString("role", "member"),
                createdAt = row.optString("created_at"),
            )
        }
        members to invites
    }

    suspend fun updateMemberRole(teamId: String, userId: String, role: String, ctx: SessionContext? = null) =
        withContext(Dispatchers.IO) {
            rpc(sessionOrThrow(ctx), "update_member_role", JSONObject().apply {
                put("p_team_id", teamId)
                put("p_user_id", userId)
                put("p_role", role)
            })
        }

    // ── Account Deletion ─────────────────────────────────

    /**
     * Deletes the account of [ctx]'s session, then ends exactly that session on this device
     * (never one that signed in while the request was out) and revokes it.
     */
    suspend fun deleteAccount(ctx: SessionContext? = null): Unit = withContext(Dispatchers.IO) {
        val session = sessionOrThrow(ctx)
        rpc(session, "delete_user_account")
        val ended = lifecycle.endIfCurrent(session.sessionId, EndReason.AccountDeleted)
        if (ended != null) revoke(ended.accessToken)
    }

    /** Forget demo mode's alert changes, so the next demo session starts from the sample data. */
    fun clearDemoState() {
        demoAlerts.set(null)
    }

    private fun currentDemoAlerts(): List<AlertRecord> {
        demoAlerts.get()?.let { return it }
        demoAlerts.compareAndSet(null, DemoDataProvider.alerts())
        return demoAlerts.get()!!
    }

    private fun updateDemoAlert(id: String, change: (AlertRecord) -> AlertRecord) {
        while (true) {
            val before = currentDemoAlerts()
            val after = before.map { if (it.id == id) change(it) else it }
            if (demoAlerts.compareAndSet(before, after)) return
        }
    }

    // ── Session-bound requests ───────────────────────────

    /**
     * Sends one authenticated request for [ctx]'s session and returns the response, which the
     * caller reads and closes. In order:
     *
     *  - demo mode fails locally; a session that is no longer current is never sent for
     *    ([ApiError.SessionSuperseded]); no token at all is [ApiError.TokenExpired];
     *  - an access token that has expired (by its lifetime from when this device received it)
     *    is renewed first;
     *  - the answer is checked against the current session again before anything else;
     *  - a 401/403 is classified ([classifyAuthRejection]) from a peek at the body: an expiry
     *    or an ambiguous 401 renews once and retries once (a renewal before sending counts);
     *    "session gone" ends the session at once. A rejection of the RENEWED token is returned
     *    as it is with the credentials kept: the server just issued that token, so a rejection
     *    says something about the server (a signing-key rotation, a proxy), not about this
     *    session. Sessions end only for "session gone" or a refused renewal. Everything else
     *    is returned untouched.
     *
     * Cancellation is never turned into an error: after the blocking call returns, a cancelled
     * caller gets its CancellationException and nothing else happens.
     */
    private suspend fun sendAuthed(
        ctx: SessionContext,
        url: String,
        configure: Request.Builder.() -> Unit,
    ): Response {
        if (ctx.isDemo) throw DemoModeRequestBlocked(url)
        val start = tokenStore.snapshotIfCurrent(ctx.sessionId) ?: throw ApiError.SessionSuperseded
        if (start.accessToken.isNullOrBlank() && start.refreshToken.isNullOrBlank()) throw ApiError.TokenExpired
        var access: String? = start.accessToken
        var renewed = false
        if (!start.refreshToken.isNullOrBlank() &&
            (access.isNullOrBlank() || isAccessTokenExpired(access, nowMillis(), start.accessReceivedAt))
        ) {
            access = renew(ctx, access)
            renewed = true
        }
        while (true) {
            val builder = Request.Builder().url(url).header("apikey", supabaseAnonKey)
            if (!access.isNullOrBlank()) builder.header("Authorization", "Bearer $access")
            builder.configure()
            val request = builder.build()
            if (tokenStore.snapshotIfCurrent(ctx.sessionId) == null) throw ApiError.SessionSuperseded

            val response = client.newCall(request).execute()
            try {
                currentCoroutineContext().ensureActive()
            } catch (e: CancellationException) {
                response.close()
                throw e
            }
            if (tokenStore.snapshotIfCurrent(ctx.sessionId) == null) {
                response.close()
                throw ApiError.SessionSuperseded
            }

            val path = request.url.encodedPath
            val rejection = if (response.code == 401 || response.code == 403) {
                classifyAuthRejection(path, response.code, response.peekBody(PEEK_BYTES).string())
            } else {
                AuthRejection.None
            }
            when (rejection) {
                AuthRejection.None -> {
                    afterRequestHook(path)
                    return response
                }
                AuthRejection.SessionGone -> {
                    response.close()
                    lifecycle.endIfCurrent(ctx.sessionId, EndReason.SessionGone)
                    throw ApiError.TokenExpired
                }
                AuthRejection.Expiry, AuthRejection.Ambiguous -> {
                    if (renewed) {
                        // Rejected with a token the server has just issued: an error to report,
                        // not a verdict on the session. Nothing ends.
                        afterRequestHook(path)
                        return response
                    }
                    val canRenew = !tokenStore.snapshotIfCurrent(ctx.sessionId)?.refreshToken.isNullOrBlank()
                    if (!canRenew) {
                        if (rejection == AuthRejection.Ambiguous) {
                            afterRequestHook(path)
                            return response
                        }
                        // An expired token and no way to renew it, ever: renew() ends it.
                    }
                    response.close()
                    access = renew(ctx, access)
                    renewed = true
                }
            }
        }
    }

    /**
     * Renews [ctx]'s session and returns the access token to use now. Under [refreshMutex]:
     * the session must still be current (a renewal for an ended session never runs, and never
     * picks up the next account's tokens); if another request of this same session renewed
     * while this one waited, its token is used without a second request. A refused renewal
     * ends the session; any other failure is thrown as it is and keeps the credentials.
     * Internal for tests only.
     */
    internal suspend fun renew(ctx: SessionContext, staleAccess: String?): String = refreshMutex.withLock {
        val current = tokenStore.snapshotIfCurrent(ctx.sessionId) ?: throw ApiError.SessionSuperseded
        val currentAccess = current.accessToken
        if (!currentAccess.isNullOrBlank() && currentAccess != staleAccess &&
            !isAccessTokenExpired(currentAccess, nowMillis(), current.accessReceivedAt)
        ) {
            return@withLock currentAccess
        }
        val refreshToken = current.refreshToken
        if (refreshToken.isNullOrBlank()) {
            lifecycle.endIfCurrent(ctx.sessionId, EndReason.SessionRefused)
            throw ApiError.TokenExpired
        }
        val (outcome, receivedAt) = performRefreshRequest(refreshToken)
        when (outcome) {
            is RefreshOutcome.Renewed -> {
                if (!tokenStore.rotateIfCurrent(ctx.sessionId, outcome.accessToken, outcome.refreshToken, receivedAt)) {
                    throw ApiError.SessionSuperseded
                }
                outcome.accessToken
            }
            is RefreshOutcome.Refused -> {
                lifecycle.endIfCurrent(ctx.sessionId, EndReason.SessionRefused)
                throw ApiError.TokenExpired
            }
            is RefreshOutcome.Failed -> throw outcome.error
        }
    }

    /**
     * One `grant_type=refresh_token` request, classified ([classifyRefreshResponse]), with the
     * moment its answer arrived ([nowMillis]; a renewed token's lifetime runs from then, not
     * from whenever the store's lock was free). Reads and writes nothing on this device; the
     * caller decides what to store.
     */
    internal suspend fun performRefreshRequest(refreshToken: String): Pair<RefreshOutcome, Long> = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url("$supabaseUrl/auth/v1/token?grant_type=refresh_token")
            .post(JSONObject().put("refresh_token", refreshToken).toString().toRequestBody(jsonMedia))
            .header("Content-Type", "application/json")
            .header("apikey", supabaseAnonKey)
            .build()
        val answer = try {
            client.newCall(request).execute().use { r ->
                val receivedAt = nowMillis()
                classifyRefreshResponse(r.code, r.body?.string() ?: "") to receivedAt
            }
        } catch (e: IOException) {
            RefreshOutcome.Failed(e) to nowMillis()
        }
        currentCoroutineContext().ensureActive()
        answer
    }

    // ── HTTP Helpers (all suspend, no runBlocking) ─────
    // NOTE: All callers must be on Dispatchers.IO (public methods enforce this via withContext)

    private suspend fun get(ctx: SessionContext, url: String): JSONObject =
        sendAuthed(ctx, url) { get() }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            JSONObject(r.body?.string() ?: "{}")
        }

    private suspend fun post(ctx: SessionContext, url: String, body: JSONObject): JSONObject =
        sendAuthed(ctx, url) {
            post(body.toString().toRequestBody(jsonMedia))
            header("Content-Type", "application/json")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            val text = r.body?.string() ?: "{}"
            if (text.isBlank() || text == "null") JSONObject() else JSONObject(text)
        }

    /** Sign-in requests: no session yet, so no bearer and no renewal. */
    private fun postUnauthenticated(url: String, body: JSONObject): JSONObject {
        val req = Request.Builder().url(url)
            .post(body.toString().toRequestBody(jsonMedia))
            .addHeader("Content-Type", "application/json")
            .addHeader("apikey", supabaseAnonKey)
            .build()
        return client.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            val text = r.body?.string() ?: "{}"
            if (text.isBlank() || text == "null") JSONObject() else JSONObject(text)
        }
    }

    private suspend fun restGetArray(ctx: SessionContext, path: String): JSONArray =
        sendAuthed(ctx, "$supabaseUrl$path") {
            get()
            header("Content-Type", "application/json")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            JSONArray(r.body?.string() ?: "[]")
        }

    private suspend fun restPatch(ctx: SessionContext, path: String, body: JSONObject) {
        sendAuthed(ctx, "$supabaseUrl$path") {
            patch(body.toString().toRequestBody(jsonMedia))
            header("Content-Type", "application/json")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
        }
    }

    private suspend fun rpc(ctx: SessionContext, function: String, params: JSONObject = JSONObject()): JSONObject =
        sendAuthed(ctx, "$supabaseUrl/rest/v1/rpc/$function") {
            post(params.toString().toRequestBody(jsonMedia))
            header("Content-Type", "application/json")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            val text = r.body?.string() ?: "{}"
            if (text.isBlank() || text == "null") JSONObject()
            else if (text.trimStart().startsWith("[")) {
                JSONObject().put("_array", JSONArray(text))
            } else JSONObject(text)
        }

    private suspend fun rpcArray(ctx: SessionContext, function: String, params: JSONObject = JSONObject()): JSONArray =
        sendAuthed(ctx, "$supabaseUrl/rest/v1/rpc/$function") {
            post(params.toString().toRequestBody(jsonMedia))
            header("Content-Type", "application/json")
        }.use { r ->
            if (!r.isSuccessful) throw ApiError.Http(r.code, r.body?.string() ?: "")
            JSONArray(r.body?.string() ?: "[]")
        }

    /**
     * Installs the session a sign-in answered with, if [attempt] is still the current sign-in
     * generation (an older attempt that answers last must not replace the newer session), then
     * fetches its profile for that session only. [receivedAtMillis]: when the answer arrived.
     */
    private suspend fun handleAuthResponse(
        attempt: Long,
        json: JSONObject,
        fallbackEmail: String?,
        receivedAtMillis: Long,
    ): AuthResponse {
        val token = json.optString("access_token")
        if (token.isBlank()) throw ApiError.Http(200, "sign-in answer without an access token")
        val refresh = json.optString("refresh_token").takeIf { it.isNotBlank() }
        val user = json.optJSONObject("user") ?: JSONObject()
        val userId = user.optString("id")

        // A caller cancelled while the sign-in request was out installs nothing; neither does an
        // attempt that a newer sign-in or demo mode overtook (checked under the
        // store's lock together with the install).
        currentCoroutineContext().ensureActive()
        val sessionId = lifecycle.install(
            accessToken = token,
            refreshToken = refresh,
            userId = userId,
            attempt = attempt,
            receivedAtMillis = receivedAtMillis,
        ) ?: throw ApiError.SessionSuperseded
        val session = tokenStore.snapshotIfCurrent(sessionId) ?: throw ApiError.SessionSuperseded

        val profile = try {
            restGetArray(session, "/rest/v1/profiles?id=eq.${enc(userId)}&select=paired,name,email")
        } catch (e: CancellationException) {
            throw e
        } catch (e: ApiError.SessionSuperseded) {
            throw e
        } catch (e: ApiError.TokenExpired) {
            throw e
        } catch (_: Exception) {
            JSONArray()
        }
        val p = profile.optJSONObject(0) ?: JSONObject()
        val metadata = user.optJSONObject("user_metadata") ?: JSONObject()

        val name = p.optString("name").ifBlank { metadata.optString("name", "") }
        val email = p.optString("email").ifBlank { user.optString("email", fallbackEmail ?: "") }
        if (!tokenStore.setProfileIfCurrent(sessionId, null, name, email)) throw ApiError.SessionSuperseded

        return AuthResponse(
            access_token = token,
            refresh_token = refresh,
            user = UserDTO(id = userId, name = name, email = email),
            paired = p.optBoolean("paired", false),
            sessionId = sessionId,
        )
    }

    // ── Utilities ────────────────────────────────────────

    private fun enc(value: String): String =
        URLEncoder.encode(value, "UTF-8")

    private fun isoNow(): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.now())

    /**
     * v0.42: today as `YYYY-MM-DD` in the device's default timezone.
     * Sent to dashboard_summary / provider_summary so the server's
     * `metric_date = current_date` comparison aligns with the user's
     * wall clock instead of UTC. Same convention as the iOS/macOS
     * `APIClient.localTodayKey()` helper.
     */
    internal fun localTodayKey(zone: ZoneId = ZoneId.systemDefault()): String =
        LocalDate.now(zone).toString()

    private fun isoAt(millis: Long): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(millis))

    private fun JSONObject.optIntOrNull(key: String): Int? =
        if (has(key) && !isNull(key)) optInt(key) else null

    private fun JSONObject.optDoubleOrNull(key: String): Double? =
        if (has(key) && !isNull(key)) optDouble(key).takeIf { !it.isNaN() } else null

    private fun JSONObject.optStringOrNull(key: String): String? =
        if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotBlank() } else null

    // v0.63: defensively parse the sensors_capability jsonb into a bool map,
    // keeping ONLY boolean values (ignore arrays/scalars/bad values).
    private fun parseSensorsCapability(obj: org.json.JSONObject?): Map<String, Boolean> {
        if (obj == null) return emptyMap()
        val out = LinkedHashMap<String, Boolean>()
        val keys = obj.keys()
        while (keys.hasNext()) {
            val k = keys.next()
            val v = obj.opt(k)
            if (v is Boolean) out[k] = v
        }
        return out
    }

    private companion object {
        /** Enough of an error body to read GoTrue's or PostgREST's error code. */
        const val PEEK_BYTES = 64L * 1024L
    }
}

/**
 * Demo mode has no account, so no request is ever sent while it is on. Thrown instead of
 * sending; an [IOException] so OkHttp's synchronous `execute()` passes it to the caller and
 * error handling treats it like a request that could not be made.
 */
class DemoModeRequestBlocked(target: String) :
    IOException("Demo mode: request not sent (${target.substringBefore('?')})")

/** Fails every request while demo mode is on: the backstop for call sites without a demo answer. */
internal class DemoModeGuard(private val tokenStore: TokenStore) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        if (tokenStore.isDemoMode) throw DemoModeRequestBlocked(chain.request().url.encodedPath)
        return chain.proceed(chain.request())
    }
}

sealed class ApiError : Exception() {
    data class Http(val code: Int, val body: String) : ApiError() {
        override val message: String get() = "HTTP $code: $body"
    }

    data object TokenExpired : ApiError() {
        override val message: String get() = "Session expired. Please sign in again."
    }

    /**
     * The operation belonged to a session that is no longer the current one: it was signed
     * out, or the next account signed in, while the operation was running. Not an expiry:
     * nothing ends because of it, and no screen shows it (UiError.from maps it to nothing).
     */
    data object SessionSuperseded : ApiError() {
        override val message: String get() = "The session this operation belonged to has ended."
    }

    /**
     * The previous session's on-device data could not be deleted in time, so this write was
     * skipped. Retryable: the next start or sign-out runs the deletion again.
     */
    data object TeardownPending : ApiError() {
        override val message: String get() = "Previous session data is still being removed."
    }
}
