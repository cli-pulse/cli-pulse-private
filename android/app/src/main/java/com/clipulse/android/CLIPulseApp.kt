package com.clipulse.android

import android.app.Application
import androidx.hilt.work.HiltWorkerFactory
import androidx.work.Configuration
import com.clipulse.android.data.remote.SupabaseConfig
import com.clipulse.android.data.session.SessionLifecycle
import com.clipulse.android.util.SentryInit
import com.clipulse.android.worker.SyncWorker
import dagger.hilt.android.HiltAndroidApp
import javax.inject.Inject

@HiltAndroidApp
class CLIPulseApp : Application(), Configuration.Provider {

    @Inject
    lateinit var workerFactory: HiltWorkerFactory

    @Inject
    lateinit var sessionLifecycle: SessionLifecycle

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder()
            .setWorkerFactory(workerFactory)
            .build()

    override fun onCreate() {
        super.onCreate()
        SentryInit.install(this)
        // Finishes a sign-out (or a refused session) whose on-device data deletion the last
        // process did not live to complete, then keeps doing so for every later end.
        sessionLifecycle.start()
        // Don't enqueue periodic sync on a mis-configured release build.
        // Without SUPABASE_URL/SUPABASE_ANON_KEY the worker would loop on
        // 401s and burn battery; MainActivity surfaces a blocking diagnostics
        // screen instead.
        if (SupabaseConfig.isConfigured) {
            SyncWorker.enqueue(this)
        } else {
            // Defensive: if a previous (configured) install scheduled work,
            // cancel it now so we don't keep firing against stale credentials.
            SyncWorker.cancel(this)
        }
    }
}
