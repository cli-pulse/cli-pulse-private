package com.clipulse.android.data.remote

import android.content.SharedPreferences
import java.util.concurrent.ConcurrentHashMap

/**
 * An in-memory [SharedPreferences] for JVM tests of [TokenStore], with the two layers the
 * real one has: what readers see ([values], updated by every edit at once) and what is on
 * disk ([durable]). `commit()` writes the whole map to disk, as SharedPreferencesImpl does;
 * `apply()` only queues it ([flushApplies] writes the queue). [restart] is a process death:
 * a new instance built from the disk layer only. [failCommits] makes commits report failure
 * without reaching disk (memory still changes, as on a device). [commits] counts
 * transactions, so a test can tell one atomic write from two.
 */
internal class InMemorySharedPreferences private constructor(initial: Map<String, Any>) : SharedPreferences {
    constructor() : this(emptyMap())

    // Concurrent: the client under test reads and writes from OkHttp/IO threads.
    private val values = ConcurrentHashMap<String, Any>(initial)
    private val durable = ConcurrentHashMap<String, Any>(initial)
    private var appliedButNotWritten = false

    @Volatile
    var commits: Int = 0
        private set

    @Volatile
    var failCommits: Boolean = false

    /** The process dies now: only what reached disk survives. */
    @Synchronized
    fun restart(): InMemorySharedPreferences = InMemorySharedPreferences(HashMap(durable))

    /** The queued apply() writes reach disk. */
    @Synchronized
    fun flushApplies() {
        if (appliedButNotWritten) writeDisk()
    }

    /** A copy of what is on disk. */
    @Synchronized
    fun durableSnapshot(): Map<String, Any> = HashMap(durable)

    private fun writeDisk() {
        durable.clear()
        durable.putAll(values)
        appliedButNotWritten = false
    }

    override fun getAll(): MutableMap<String, *> = HashMap(values)
    override fun getString(key: String, defValue: String?): String? =
        if (values.containsKey(key)) values[key] as String? else defValue
    @Suppress("UNCHECKED_CAST")
    override fun getStringSet(key: String, defValues: MutableSet<String>?): MutableSet<String>? =
        if (values.containsKey(key)) values[key] as MutableSet<String>? else defValues
    override fun getInt(key: String, defValue: Int): Int = values[key] as Int? ?: defValue
    override fun getLong(key: String, defValue: Long): Long = values[key] as Long? ?: defValue
    override fun getFloat(key: String, defValue: Float): Float = values[key] as Float? ?: defValue
    override fun getBoolean(key: String, defValue: Boolean): Boolean = values[key] as Boolean? ?: defValue
    override fun contains(key: String): Boolean = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) = Unit

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = HashMap<String, Any?>()
        private val removed = HashSet<String>()
        private var clearAll = false

        override fun putString(key: String, value: String?) = apply { pending[key] = value }
        override fun putStringSet(key: String, values: MutableSet<String>?) = apply { pending[key] = values }
        override fun putInt(key: String, value: Int) = apply { pending[key] = value }
        override fun putLong(key: String, value: Long) = apply { pending[key] = value }
        override fun putFloat(key: String, value: Float) = apply { pending[key] = value }
        override fun putBoolean(key: String, value: Boolean) = apply { pending[key] = value }
        override fun remove(key: String) = apply { removed += key }
        override fun clear() = apply { clearAll = true }

        private fun toMemory() {
            commits++
            if (clearAll) values.clear()
            removed.forEach { values.remove(it) }
            pending.forEach { (k, v) -> if (v == null) values.remove(k) else values[k] = v }
        }

        override fun commit(): Boolean = synchronized(this@InMemorySharedPreferences) {
            toMemory()
            if (failCommits) {
                appliedButNotWritten = true
                false
            } else {
                writeDisk()
                true
            }
        }

        override fun apply() {
            synchronized(this@InMemorySharedPreferences) {
                toMemory()
                appliedButNotWritten = true
            }
        }
    }
}
