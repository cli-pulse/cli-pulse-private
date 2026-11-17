package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.security.GeneralSecurityException
import java.security.ProviderException
import java.util.UUID
import javax.crypto.AEADBadTagException

/**
 * Opens [TokenStore]'s encrypted preferences, and recovers when they can never be read again.
 *
 * WHY (1.63, D7): the file's keyset is encrypted with an Android Keystore key that stays on
 * the phone. When the file arrives without that key (a device transfer or a restore from
 * Android 1.62.0 or earlier, which had no data-extraction rules; or a Keystore that lost the
 * key), `EncryptedSharedPreferences.create` throws `AEADBadTagException` on every launch, and
 * the app crashed in `TokenStore`'s constructor on every start (measured on an emulator,
 * 2026-11-16). 1.63.0's rules stop new transfers from carrying the file; a phone restored
 * earlier still has it.
 *
 * What this deletes, and when. Nothing on the first failure: it waits [RETRY_PAUSE_MS] and
 * opens once more, because a Keystore that was briefly unavailable answers the second time.
 * (The wait matters: during such an outage the library's own `containsAlias` check can fail
 * and make it generate a new key over the old one; a retry inside the same outage invites
 * that.) Only when the second open fails because the keyset no longer authenticates under
 * the current key (`AEADBadTagException` anywhere in the chain; Android raises it only for a
 * failed authentication) does it delete the file. Nothing else counts: `UnrecoverableKeyException`,
 * `KeyStoreException` and the rest are thrown, as before 1.63, with nothing deleted. The key is
 * never deleted: with the file gone the library makes a fresh keyset under whatever key exists.
 *
 * Before deleting, it records a reset intent, a random token in `noBackupFilesDir` (never
 * backed up or transferred), written and synced. [Opened.resetToken] reports it, on this start
 * and on any later one. TokenStore marks the usage cache restored with the old file for
 * deletion and stores the token as handled in the same commit; only then is the intent
 * removed ([Opened.resetDone]). A start that finds the intent already handled (its commit
 * reached disk late, or the file could not be removed) only removes it again: the cache of a
 * later session is never marked twice for one reset. This covers a process that dies between
 * the deletion and the mark. It does not sync the directory entry, so a power loss in that
 * window is not covered.
 *
 * A token that cannot be read, an intent that cannot be recorded, a deletion that did not
 * happen, or a failure of the open after the deletion is thrown. Out of scope: a readable
 * keyset whose individual values are damaged, or a keyset that decrypts but does not parse.
 */
internal object SecurePrefs {
    const val FILE = "cli_pulse_secure_prefs"
    const val RESET_INTENT_FILE = "secure_prefs_reset_pending"
    const val RETRY_PAUSE_MS = 750L
    private const val TAG = "SecurePrefs"

    /**
     * [resetToken]: the pending reset's token, or null. [resetDone]: removes the intent; call
     * it once the token is stored as handled on disk.
     */
    class Opened(val prefs: SharedPreferences, val resetToken: String?, val resetDone: () -> Unit)

    /** A durable record that outlives the deleted store. */
    interface ResetIntent {
        /** The recorded token, or null when there is none. Throws when it cannot tell. */
        fun token(): String?

        /** Records the intent (or syncs the one already there) and returns its token. Throws on failure. */
        fun record(): String

        /** Removes it; true when it is gone. */
        fun clear(): Boolean
    }

    fun open(context: Context): Opened = open(
        create = {
            EncryptedSharedPreferences.create(
                context,
                FILE,
                MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        },
        deleteFile = deleteFileStep(context),
        intent = intentFor(context),
        pause = { Thread.sleep(RETRY_PAUSE_MS) },
    )

    /** The real deletion: this file, its backup, and the process's cached instance of it. */
    fun deleteFileStep(context: Context): () -> Boolean = { context.deleteSharedPreferences(FILE) }

    fun intentFor(context: Context): ResetIntent = FileIntent(File(context.noBackupFilesDir, RESET_INTENT_FILE))

    /**
     * [create] builds the master key and opens the file, both inside each attempt. [deleteFile]
     * returns whether the file is gone; one that throws counts as not done.
     */
    fun open(
        create: () -> SharedPreferences,
        deleteFile: () -> Boolean,
        intent: ResetIntent,
        pause: () -> Unit = {},
    ): Opened {
        attempt(create)?.let { return opened(it, intent) }
        pause()
        val failure = try {
            return opened(create(), intent)
        } catch (e: Exception) {
            if (!isOpenFailure(e)) throw e
            e
        }
        if (!isUndecryptable(failure)) throw failure
        try {
            intent.record()
        } catch (e: Exception) {
            failure.addSuppressed(e)
            throw failure
        }
        val deleted = try {
            deleteFile()
        } catch (e: Exception) {
            failure.addSuppressed(e)
            false
        }
        if (!deleted) throw failure
        runCatching { Log.w(TAG, "encrypted preferences could not be decrypted; deleted, starting signed out") }
        return opened(create(), intent)
    }

    private fun opened(prefs: SharedPreferences, intent: ResetIntent) =
        Opened(prefs, resetToken = intent.token(), resetDone = { runCatching { intent.clear() } })

    /** The first open: its result, or null after a failure worth one more try. */
    private fun attempt(create: () -> SharedPreferences): SharedPreferences? = try {
        create()
    } catch (e: Exception) {
        if (!isOpenFailure(e)) throw e
        null
    }

    /** What a Keystore or Tink failure to open looks like; anything else is a bug and is thrown. */
    fun isOpenFailure(e: Throwable): Boolean =
        e is GeneralSecurityException || e is IOException || e is ProviderException

    /** True when [e]'s chain says the keyset failed authentication under the current key. */
    fun isUndecryptable(e: Throwable): Boolean {
        var t: Throwable? = e
        var depth = 0
        while (t != null && depth < 10) {
            if (t is AEADBadTagException) return true
            t = t.cause
            depth++
        }
        return false
    }

    /** The intent as a small file holding its token, written and synced to disk. */
    class FileIntent(private val file: File) : ResetIntent {
        override fun token(): String? {
            if (!file.exists()) return null
            return file.readText().trim().takeIf { it.isNotEmpty() }
        }

        override fun record(): String {
            token()?.let { existing ->
                // Already recorded: sync it again (an earlier write whose sync failed must not
                // count), without truncating it, so an interruption cannot erase it.
                RandomAccessFile(file, "rw").use { it.fd.sync() }
                return existing
            }
            // A new token is written to a temporary file, synced, then renamed over the target:
            // the intent file only ever holds a whole token.
            val token = UUID.randomUUID().toString()
            val temp = File(file.parentFile, file.name + ".tmp")
            FileOutputStream(temp).use { out ->
                out.write(token.toByteArray())
                out.fd.sync()
            }
            if (!temp.renameTo(file)) {
                temp.delete()
                throw IOException("reset intent could not be placed")
            }
            check(token() == token) { "reset intent not readable after writing" }
            return token
        }

        override fun clear(): Boolean = !file.exists() || file.delete() || !file.exists()
    }
}
