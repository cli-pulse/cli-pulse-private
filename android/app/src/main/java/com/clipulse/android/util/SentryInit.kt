package com.clipulse.android.util

import android.app.Application
import com.clipulse.android.BuildConfig
import io.sentry.Breadcrumb
import io.sentry.SentryEvent
import io.sentry.SentryOptions
import io.sentry.android.core.SentryAndroid
import java.util.Collections
import kotlin.concurrent.thread

object SentryInit {

    fun install(app: Application) {
        val dsn = BuildConfig.SENTRY_DSN
        if (dsn.isBlank() || !dsn.startsWith("https://")) return

        // v1.21 M1: defer the actual SentryAndroid.init off the main thread
        // so cold-start latency stays bounded even on slow-disk devices or
        // when the SDK's anr-handler / file-read setup is sluggish. Sentry
        // documents init as thread-safe; the daemon thread runs at default
        // priority so the work completes well within the first second.
        // Crashes in the ~50ms window between Application.onCreate and the
        // background thread picking up the init are not captured — that's
        // an accepted trade-off versus blocking launch.
        thread(start = true, isDaemon = true, name = "sentry-init") {
            installSync(app, dsn)
        }
    }

    private fun installSync(app: Application, dsn: String) {
        SentryAndroid.init(app) { options ->
            options.dsn = dsn
            options.release = "cli-pulse@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            options.environment = if (BuildConfig.DEBUG) "debug" else "release"
            options.tracesSampleRate = 0.0
            options.isSendDefaultPii = false
            options.isAttachStacktrace = true
            options.maxBreadcrumbs = 50
            options.isEnableAutoSessionTracking = true
            options.isEnableUserInteractionBreadcrumbs = false
            options.isEnableUserInteractionTracing = false
            options.setTag("platform_family", "android")
            configure(options)
        }
    }

    /** Installs the scrubbing callbacks. Separate from [installSync] so tests run the real ones. */
    internal fun configure(options: SentryOptions) {
        options.setBeforeSend { event, _ -> scrub(event) }
        options.setBeforeBreadcrumb { crumb, _ -> scrubBreadcrumb(crumb) }
    }

    internal fun scrubBreadcrumb(crumb: Breadcrumb): Breadcrumb {
        crumb.message = crumb.message?.let(SentryScrub::redact)
        for (key in crumb.data.keys.toList()) {
            val scrubbed = SentryScrub.scrubValue(key, crumb.data[key]) ?: continue
            crumb.setData(key, scrubbed)
        }
        return crumb
    }

    // event.transaction and event.request are not scrubbed: the app never sets them (tracing is off,
    // no HTTP integration is installed). Scrub them here if that ever changes.
    internal fun scrub(event: SentryEvent): SentryEvent {
        event.user?.apply {
            email = null
            ipAddress = null
            username = null
        }
        event.tags?.keys?.toList()?.forEach { key ->
            val value = event.tags?.get(key) ?: return@forEach
            val scrubbed = if (SentryScrub.shouldScrub(key)) SentryScrub.SCRUBBED else SentryScrub.redact(value)
            event.setTag(key, scrubbed)
        }
        event.extras?.keys?.toList()?.forEach { key ->
            val scrubbed = SentryScrub.scrubValue(key, event.extras?.get(key)) ?: return@forEach
            event.setExtra(key, scrubbed)
        }
        // Contexts is not a Kotlin Map: it exposes keys() as an Enumeration plus get/put.
        val contexts = event.contexts
        for (key in Collections.list(contexts.keys())) {
            val old = contexts.get(key) ?: continue
            val scrubbed = SentryScrub.scrubValue(key, old) ?: continue
            if (scrubbed !== old) contexts.put(key, scrubbed)
        }
        event.exceptions?.forEach { ex ->
            ex.value = ex.value?.let(SentryScrub::redact)
        }
        event.message?.let { msg ->
            msg.formatted = msg.formatted?.let(SentryScrub::redact)
            msg.message = msg.message?.let(SentryScrub::redact)
            msg.params = msg.params?.map(SentryScrub::redact)
        }
        event.breadcrumbs?.forEach { scrubBreadcrumb(it) }
        return event
    }
}
