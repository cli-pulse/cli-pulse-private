package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.ProviderException
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
 * What this deletes, and when. Nothing on the first failure: it opens once more, because a
 * Keystore that was briefly busy answers the second time. Only when that second open fails
 * with a cause that names permanent damage does it delete, and only what that cause names:
 * - the keyset no longer authenticates under the current key (`AEADBadTagException` anywhere
 *   in the chain): the file;
 * - Android says the key itself is permanently invalid (`KeyPermanentlyInvalidatedException`):
 *   the key, then the file (a new key cannot read a keyset made for the old one).
 * Nothing else counts, `UnrecoverableKeyException` included: Android also wraps passing
 * Keystore failures in it.
 *
 * Before deleting anything it records a reset intent in `noBackupFilesDir` (never backed up
 * or transferred). [Opened.resetPending] reports that intent; TokenStore then marks the usage
 * cache restored with the old file for deletion and calls [Opened.resetDone] once that mark is
 * on disk. So a process that dies between the deletion and the mark finishes the job on the
 * next start, instead of opening an empty store and keeping the old cache.
 *
 * Any other failure, an intent or a deletion that could not be made, or a failure of the open
 * after the deletion is thrown, as before 1.63. Out of scope: a readable keyset whose
 * individual values are damaged (`create` succeeds then; a later read fails).
 *
 * The master key alias ([MasterKey.DEFAULT_MASTER_KEY_ALIAS]) is used only by this file: no
 * other EncryptedSharedPreferences, EncryptedFile or MasterKey exists in the app.
 */
internal object SecurePrefs {
    const val FILE = "cli_pulse_secure_prefs"
    const val RESET_INTENT_FILE = "secure_prefs_reset_pending"
    private const val TAG = "SecurePrefs"

    /**
     * [resetPending]: a reset deleted the store, now or in an earlier start, and the cache mark
     * that must follow it is not on disk yet. [resetDone]: call once that mark reached disk.
     */
    class Opened(val prefs: SharedPreferences, val resetPending: Boolean, val resetDone: () -> Unit)

    enum class Cause { KEYSET_UNREADABLE, KEY_INVALIDATED, OTHER }

    /** A durable flag that outlives the deleted store. */
    interface ResetIntent {
        fun isPending(): Boolean

        /** True when the intent is on disk. */
        fun record(): Boolean
        fun clear()
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
        deleteFile = { context.deleteSharedPreferences(FILE) },
        deleteKey = { deleteKeystoreEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS) },
        intent = FileIntent(File(context.noBackupFilesDir, RESET_INTENT_FILE)),
    )

    /**
     * [create] builds the master key and opens the file, both inside each attempt. [deleteFile]
     * and [deleteKey] return whether the thing is gone afterwards; one that throws counts as
     * not done. [classify] is [cause] except in tests.
     */
    fun open(
        create: () -> SharedPreferences,
        deleteFile: () -> Boolean,
        deleteKey: () -> Boolean,
        intent: ResetIntent,
        classify: (Throwable) -> Cause = ::cause,
    ): Opened {
        attempt(create)?.let { return opened(it, intent) }
        val failure = try {
            return opened(create(), intent)
        } catch (e: Exception) {
            if (!isOpenFailure(e)) throw e
            e
        }
        val cause = classify(failure)
        if (cause == Cause.OTHER) throw failure
        if (!done { intent.record() }) throw failure
        when (cause) {
            Cause.KEYSET_UNREADABLE -> {
                if (!done(deleteFile)) throw failure
                runCatching { Log.w(TAG, "encrypted preferences could not be decrypted; deleted, starting signed out") }
            }
            Cause.KEY_INVALIDATED -> {
                if (!done(deleteKey)) throw failure
                if (!done(deleteFile)) throw failure
                runCatching { Log.w(TAG, "encryption key permanently invalid; key and preferences deleted, starting signed out") }
            }
            Cause.OTHER -> throw failure
        }
        return opened(create(), intent)
    }

    private fun opened(prefs: SharedPreferences, intent: ResetIntent) =
        Opened(prefs, resetPending = done { intent.isPending() }, resetDone = { runCatching { intent.clear() } })

    private inline fun done(step: () -> Boolean): Boolean = try {
        step()
    } catch (e: Exception) {
        false
    }

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

    /** The permanent cause in [e]'s chain, if there is one. */
    fun cause(e: Throwable): Cause {
        var t: Throwable? = e
        var depth = 0
        while (t != null && depth < 10) {
            when (t) {
                is AEADBadTagException -> return Cause.KEYSET_UNREADABLE
                is KeyPermanentlyInvalidatedException -> return Cause.KEY_INVALIDATED
            }
            t = t.cause
            depth++
        }
        return Cause.OTHER
    }

    private fun deleteKeystoreEntry(alias: String): Boolean {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        return !keyStore.containsAlias(alias)
    }

    /** The intent as a file written and synced to disk. */
    private class FileIntent(private val file: File) : ResetIntent {
        override fun isPending(): Boolean = file.exists()

        override fun record(): Boolean {
            if (!file.exists()) {
                FileOutputStream(file).use { out ->
                    out.write(1)
                    out.fd.sync()
                }
            }
            return file.exists()
        }

        override fun clear() {
            file.delete()
        }
    }
}
