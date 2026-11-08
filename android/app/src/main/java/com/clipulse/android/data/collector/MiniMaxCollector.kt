package com.clipulse.android.data.collector

import com.clipulse.android.data.model.ProviderKind
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.roundToLong

/**
 * MiniMax coding / token plan quota — port of the macOS `MiniMaxCollector.swift`
 * (itself derived from steipete/CodexBar, MIT).
 *
 * `GET https://api.minimax.io/v1/token_plan/remains`, then
 * `/v1/api/openplatform/coding_plan/remains`; when the global host REJECTS the
 * key (401/403, `base_resp` 1004, "invalid api key"), the same two on
 * `api.minimaxi.com` (China mainland keys only work there). An outage is never
 * a rejection and never sends the key to the other region.
 *
 * Until this port the collector read a guessed `data.remaining` / `data.quota`
 * (defaults 0 / 100) from `platform.minimax.io`, so every real account showed
 * 0 % left. MiniMax actually sends per-model lanes:
 *
 * ```json
 * {"model_remains": [{"model_name": "general",
 *   "start_time": 1780279200000, "end_time": 1780297200000, "remains_time": 14859830,
 *   "current_interval_total_count": 1500, "current_interval_usage_count": 1200,
 *   "current_interval_remaining_percent": 96, "current_interval_status": 1,
 *   "current_weekly_remaining_percent": 99, "weekly_end_time": 1780848000000}]}
 * ```
 *
 * at the top level or under `data`, numbers sometimes as strings, times in
 * epoch seconds or milliseconds, and `*_usage_count` meaning what is LEFT.
 * Only the text lane (`general`, else a MiniMax-M / M2.x model) is read;
 * placeholder lanes (status 3, zero counts, 100 % left) are skipped and an
 * unlimited weekly window is dropped. Tiers are percentages: "5-hour",
 * "Daily" or "Coding Plan" for the interval, plus "Weekly".
 *
 * Divergences from the Mac collector: no cookie path and no env overrides
 * (Android has neither), and every redirect is refused, not only one to
 * another host.
 */
class MiniMaxCollector(
    internal val globalBaseUrl: String = "https://api.minimax.io",
    internal val chinaBaseUrl: String = "https://api.minimaxi.com",
    private val now: () -> Instant = { Instant.now() },
) : ProviderCollector {
    override val kind = ProviderKind.MiniMax

    // No redirects at all: the Authorization header must not reach a host we
    // did not choose. A refused redirect is the 3xx itself, read as an outage.
    private val client by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    override fun isAvailable(apiKey: String?): Boolean = !apiKey.isNullOrBlank()

    override suspend fun collect(apiKey: String): CollectorResult =
        buildResult(fetchWithApiKey(apiKey.trim()))

    // ── Regions ─────────────────────────────────────────────────────

    internal enum class Region {
        GLOBAL, CHINA_MAINLAND;

        val other: Region get() = if (this == GLOBAL) CHINA_MAINLAND else GLOBAL
    }

    private fun baseUrl(region: Region) = when (region) {
        Region.GLOBAL -> globalBaseUrl
        Region.CHINA_MAINLAND -> chinaBaseUrl
    }

    // ── Errors ──────────────────────────────────────────────────────

    /** Both regions refused the key (or the only one asked did). */
    class KeyRejectedException : Exception("MiniMax rejected the API key")

    class HttpStatusException(val status: Int) : Exception("MiniMax API error: $status")

    /** The detail never carries MiniMax's own message: only a code. */
    class ParseException(detail: String) : Exception("MiniMax: $detail")

    /** The answer refused the credential (`base_resp` 1004, "invalid api key"). */
    internal class CredentialRejection : Exception()

    // ── Fetch ───────────────────────────────────────────────────────

    /** How one request ended. */
    internal sealed class Attempt {
        data class Ok(val parsed: Parsed) : Attempt()
        /** 401/403, `base_resp` 1004, "invalid api key". */
        object Rejected : Attempt()
        /** 404/405: this host does not serve this path. */
        data class Missing(val status: Int) : Attempt()
        /** Anything else: we do not know what the key is worth. */
        data class Unavailable(val error: Exception) : Attempt()
    }

    internal sealed class Verdict {
        data class Ok(val parsed: Parsed) : Verdict()
        object Rejected : Verdict()
        data class Unavailable(val error: Exception) : Verdict()
    }

    internal fun fetchWithApiKey(token: String): Parsed {
        val first = rememberedRegion.region(token)
        return when (val firstVerdict = verdict(first, token)) {
            is Verdict.Ok -> firstVerdict.parsed
            is Verdict.Unavailable -> throw firstVerdict.error
            Verdict.Rejected -> {
                // A key from the other region is rejected here: ask there, once.
                val second = first.other
                val secondVerdict = verdict(second, token)
                if (secondVerdict is Verdict.Ok) rememberedRegion.remember(second, token)
                settle(secondVerdict)
            }
        }
    }

    private fun settle(verdict: Verdict): Parsed = when (verdict) {
        is Verdict.Ok -> verdict.parsed
        Verdict.Rejected -> throw KeyRejectedException()
        is Verdict.Unavailable -> throw verdict.error
    }

    private fun verdict(region: Region, token: String): Verdict {
        val attempts = mutableListOf<Attempt>()
        for (path in API_PATHS) {
            val result = attempt(baseUrl(region) + path, token)
            if (result is Attempt.Ok) return Verdict.Ok(result.parsed)
            attempts.add(result)
        }
        return regionVerdict(attempts)
    }

    private fun attempt(url: String, token: String): Attempt {
        val req = Request.Builder()
            .url(url)
            .get()
            .addHeader("Authorization", "Bearer $token")
            .addHeader("Accept", "application/json")
            .addHeader("MM-API-Source", "CLIPulseBar")
            .build()
        val (status, body) = try {
            client.newCall(req).execute().use { r -> r.code to (r.body?.string() ?: "") }
        } catch (e: IOException) {
            return Attempt.Unavailable(e)
        }
        when (status) {
            401, 403 -> return Attempt.Rejected
            404, 405 -> return Attempt.Missing(status)
            in 200..299 -> Unit
            else -> return Attempt.Unavailable(HttpStatusException(status))
        }
        return try {
            Attempt.Ok(parseRemainsResponse(body, now()))
        } catch (e: CredentialRejection) {
            Attempt.Rejected
        } catch (e: Exception) {
            Attempt.Unavailable(e)
        }
    }

    // ── Parsing ─────────────────────────────────────────────────────

    /** One quota window, as a percentage left. */
    data class Window(
        val name: String,
        val remainingPercent: Int,
        val resetsAt: Instant?,
        val windowMinutes: Int?,
    )

    sealed class Parsed {
        data class Windows(val plan: String?, val interval: Window?, val weekly: Window?) : Parsed()

        /** The flat shape the Mac collector used to expect. Never observed. */
        data class Legacy(val modelRemains: Int, val total: Int, val endTime: String?) : Parsed()
    }

    companion object {
        /** Newest first: the token plan, then the coding plan it replaced. */
        internal val API_PATHS = listOf("/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains")

        /**
         * The region whose host last accepted the key, for that key only (a
         * SHA-256 of it, in memory): a key not seen answering starts on the
         * global host, so a global key is never sent to China because the
         * previous key lived there.
         */
        private val rememberedRegion = RegionMemory()

        /** Forgets the remembered region (tests). */
        internal fun resetRememberedRegion() = rememberedRegion.reset()

        /**
         * A region rejected the key only if some path rejected it and every
         * other path rejected it too or does not exist there. One outage or
         * unreadable answer makes the region unavailable: a key must never be
         * called rejected because a server was down.
         */
        internal fun regionVerdict(attempts: List<Attempt>): Verdict {
            attempts.firstOrNull { it is Attempt.Ok }?.let { return Verdict.Ok((it as Attempt.Ok).parsed) }
            attempts.firstOrNull { it is Attempt.Unavailable }
                ?.let { return Verdict.Unavailable((it as Attempt.Unavailable).error) }
            if (attempts.any { it is Attempt.Rejected }) return Verdict.Rejected
            val lastMissing = attempts.lastOrNull { it is Attempt.Missing } as Attempt.Missing?
            return Verdict.Unavailable(HttpStatusException(lastMissing?.status ?: 0))
        }

        internal fun parseRemainsResponse(text: String, now: Instant = Instant.now()): Parsed {
            val json = try {
                JSONObject(text)
            } catch (e: JSONException) {
                throw ParseException("invalid JSON")
            }
            val body = json.optJSONObject("data") ?: json

            val base = body.optJSONObject("base_resp") ?: json.optJSONObject("base_resp")
            val code = number(base?.opt("status_code"))
            if (base != null && code != null && code != 0.0) {
                val message = base.optString("status_msg", "").lowercase()
                // Only an explicit refusal. A message that merely mentions
                // logging in ("login service unavailable") is an outage.
                if (code == 1004.0 || message.contains("invalid api key")) throw CredentialRejection()
                throw ParseException("status ${toInt(code)?.toString() ?: "?"}")
            }

            val legacyRemains = number(json.opt("model_remains"))
            if (legacyRemains != null) {
                val remaining = toInt(legacyRemains)
                val total = toInt(number(json.opt("total")) ?: 0.0)
                if (remaining == null || total == null) throw ParseException("count out of range")
                val endTime = (json.opt("end_time") as? String) ?: (json.opt("remains_time") as? String)
                return Parsed.Legacy(remaining, total, endTime)
            }

            val lanes = (body.optJSONArray("model_remains") ?: json.optJSONArray("model_remains"))
                ?.objects() ?: throw ParseException("no coding plan quota")
            // `general` first, then any text model in the order MiniMax sent them.
            val text = lanes.filter { isTextLane(it.opt("model_name") as? String) }
            val ordered = text.filter { laneName(it) == "general" } + text.filter { laneName(it) != "general" }
            for (lane in ordered) {
                val interval = intervalWindow(lane, now)
                val weekly = weeklyWindow(lane, now)
                if (interval != null || weekly != null) return Parsed.Windows(planName(body), interval, weekly)
            }
            throw ParseException("no coding plan quota")
        }

        private fun JSONArray.objects(): List<JSONObject> = (0 until length()).mapNotNull { optJSONObject(it) }

        private fun laneName(lane: JSONObject) = (lane.opt("model_name") as? String)?.lowercase()

        /** `general` (the token plan's text bucket) or a text model by name. */
        internal fun isTextLane(name: String?): Boolean {
            val lower = name?.trim()?.lowercase() ?: return false
            return lower == "general" || lower.contains("minimax-m") || lower.startsWith("m2.")
        }

        private fun intervalWindow(lane: JSONObject, now: Instant): Window? {
            val start = date(lane.opt("start_time"))
            val end = date(lane.opt("end_time"))
            val remaining = remainingPercent(
                percent = lane.opt("current_interval_remaining_percent"),
                total = lane.opt("current_interval_total_count"),
                remaining = lane.opt("current_interval_usage_count"),
                status = lane.opt("current_interval_status"),
            ) ?: return null
            val minutes = windowMinutes(start, end)
            val name = when {
                minutes == null -> "Coding Plan"
                minutes in 240..360 -> "5-hour"
                minutes in 1380..1500 -> "Daily"
                else -> "Coding Plan"
            }
            return Window(name, remaining, resetsAt(end, lane.opt("remains_time"), now), minutes)
        }

        private fun weeklyWindow(lane: JSONObject, now: Instant): Window? {
            val status = number(lane.opt("current_weekly_status"))
            val percent = number(lane.opt("current_weekly_remaining_percent"))
            // Upstream's "no weekly limit" signature.
            if (status == 3.0 && percent != null && percent >= 100) return null
            val remaining = remainingPercent(
                percent = lane.opt("current_weekly_remaining_percent"),
                total = lane.opt("current_weekly_total_count"),
                remaining = lane.opt("current_weekly_usage_count"),
                status = lane.opt("current_weekly_status"),
            ) ?: return null
            val end = date(lane.opt("weekly_end_time"))
            return Window("Weekly", remaining, resetsAt(end, lane.opt("weekly_remains_time"), now), 10080)
        }

        /**
         * Percent left, 0…100: the percent MiniMax sends, else remaining /
         * total. Null for a window this plan does not have (status 3, zero
         * counts, 100 % left) or one with nothing to measure.
         */
        internal fun remainingPercent(percent: Any?, total: Any?, remaining: Any?, status: Any?): Int? {
            val p = number(percent)
            val t = number(total)
            val r = number(remaining)
            if (number(status) == 3.0 && (t ?: 0.0) == 0.0 && (r ?: 0.0) == 0.0 && (p ?: 0.0) >= 100) return null
            val value = when {
                p != null -> p
                t != null && t > 0 && r != null -> 100 * r / t
                else -> return null
            }
            return value.coerceIn(0.0, 100.0).roundToInt()
        }

        private fun planName(body: JSONObject): String? =
            listOf(
                body.opt("current_subscribe_title"), body.opt("plan_name"), body.opt("combo_title"),
                body.opt("current_plan_title"), body.optJSONObject("current_combo_card")?.opt("title"),
            ).firstNotNullOfOrNull { (it as? String)?.trim()?.takeIf(String::isNotEmpty) }

        /** A finite number from a JSON number or a numeric string (never a boolean). */
        internal fun number(value: Any?): Double? {
            val result = when (value) {
                is Number -> value.toDouble()
                is String -> value.trim().toDoubleOrNull()
                else -> null
            }
            return result?.takeIf { it.isFinite() }
        }

        /** `value` as an Int when an Int can hold it (`"1e100"` is finite). */
        internal fun toInt(value: Double): Int? =
            if (value.isFinite() && abs(value) <= Int.MAX_VALUE) value.toInt() else null

        /** Epoch milliseconds or seconds before 2100; anything else is not a time. */
        internal fun date(value: Any?): Instant? {
            val raw = number(value) ?: return null
            val seconds = when {
                raw > 1_000_000_000_000 -> raw / 1000
                raw > 1_000_000_000 -> raw
                else -> return null
            }
            if (seconds >= 4_102_444_800) return null
            return Instant.ofEpochMilli((seconds * 1000).roundToLong())
        }

        private fun windowMinutes(start: Instant?, end: Instant?): Int? {
            if (start == null || end == null) return null
            val minutes = ((end.toEpochMilli() - start.toEpochMilli()) / 60_000.0).roundToInt()
            return minutes.takeIf { it > 0 }
        }

        /**
         * The window's end if it is still ahead, else now plus the time MiniMax
         * says is left (milliseconds above a million, else seconds).
         */
        internal fun resetsAt(end: Instant?, remains: Any?, now: Instant): Instant? {
            if (end != null && end.isAfter(now)) return end
            val left = number(remains)?.takeIf { it > 0 } ?: return null
            val seconds = if (left > 1_000_000) left / 1000 else left
            // A century ahead is not a reset; it would also overflow Instant.
            if (seconds > 3_155_760_000) return null
            return now.plusMillis((seconds * 1000).roundToLong())
        }

        // ── Result ──────────────────────────────────────────────────

        internal fun buildResult(parsed: Parsed): CollectorResult = when (parsed) {
            is Parsed.Legacy -> {
                val tiers = if (parsed.total > 0) {
                    listOf(CollectorTier("Coding Plan", parsed.total, parsed.modelRemains, parsed.endTime))
                } else {
                    emptyList()
                }
                CollectorResult(
                    provider = ProviderKind.MiniMax,
                    remaining = parsed.modelRemains,
                    quota = parsed.total.takeIf { it > 0 },
                    planType = "Coding Plan",
                    resetTime = parsed.endTime,
                    tiers = tiers,
                    confidence = "medium",
                )
            }
            is Parsed.Windows -> {
                val tiers = listOfNotNull(parsed.interval, parsed.weekly).map { w ->
                    CollectorTier(w.name, 100, w.remainingPercent, w.resetsAt?.let(::iso))
                }
                val headline = tiers.firstOrNull()
                CollectorResult(
                    provider = ProviderKind.MiniMax,
                    remaining = headline?.remaining ?: 0,
                    quota = 100,
                    planType = parsed.plan ?: "Coding Plan",
                    resetTime = headline?.resetTime,
                    tiers = tiers,
                    confidence = "high",
                )
            }
        }

        private fun iso(instant: Instant) = instant.truncatedTo(ChronoUnit.SECONDS).toString()
    }
}

/** The remembered region and the hash of the key it belongs to (collectors run concurrently). */
private class RegionMemory {
    private var keyHash: ByteArray? = null
    private var region = MiniMaxCollector.Region.GLOBAL

    @Synchronized
    fun region(key: String): MiniMaxCollector.Region =
        if (keyHash?.contentEquals(hash(key)) == true) region else MiniMaxCollector.Region.GLOBAL

    @Synchronized
    fun remember(value: MiniMaxCollector.Region, key: String) {
        keyHash = hash(key)
        region = value
    }

    @Synchronized
    fun reset() {
        keyHash = null
        region = MiniMaxCollector.Region.GLOBAL
    }

    private fun hash(key: String): ByteArray = MessageDigest.getInstance("SHA-256").digest(key.toByteArray())
}
