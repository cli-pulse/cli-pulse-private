package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.ProviderException
import java.security.UnrecoverableKeyException
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
 * with a cause that cannot go away by itself does it delete, and only what that cause names:
 * - the keyset no longer authenticates under the current key (`AEADBadTagException`): the file;
 * - the key itself is unusable (`UnrecoverableKeyException`, `KeyPermanentlyInvalidatedException`):
 *   the key, then the file (a new key cannot read a keyset made for the old one).
 * It then opens a third time, on an empty file. Any other failure, a deletion that did not
 * happen, or a third failure is thrown, as before 1.63.
 *
 * Out of scope: a readable keyset whose individual values are damaged. `create` succeeds then,
 * and the failure would come from a later read, not from here.
 *
 * The master key alias ([MasterKey.DEFAULT_MASTER_KEY_ALIAS]) is used only by this file: no
 * other EncryptedSharedPreferences, EncryptedFile or MasterKey exists in the app.
 */
internal object SecurePrefs {
    const val FILE = "cli_pulse_secure_prefs"
    private const val TAG = "SecurePrefs"

    class Opened(val prefs: SharedPreferences, val wasReset: Boolean)

    enum class Cause { KEYSET_UNREADABLE, KEY_UNUSABLE, OTHER }

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
    )

    /**
     * [create] builds the master key and opens the file, both inside each attempt. [deleteFile]
     * and [deleteKey] return whether the thing is gone afterwards.
     */
    fun open(
        create: () -> SharedPreferences,
        deleteFile: () -> Boolean,
        deleteKey: () -> Boolean,
    ): Opened {
        attempt(create)?.let { return Opened(it, wasReset = false) }
        val failure = try {
            return Opened(create(), wasReset = false)
        } catch (e: Exception) {
            if (!isOpenFailure(e)) throw e
            e
        }
        when (cause(failure)) {
            Cause.KEYSET_UNREADABLE -> {
                if (!deleteFile()) throw failure
                runCatching { Log.w(TAG, "encrypted preferences could not be decrypted; deleted, starting signed out") }
            }
            Cause.KEY_UNUSABLE -> {
                if (!deleteKey()) throw failure
                if (!deleteFile()) throw failure
                runCatching { Log.w(TAG, "encryption key unusable; key and preferences deleted, starting signed out") }
            }
            Cause.OTHER -> throw failure
        }
        return Opened(create(), wasReset = true)
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
                is UnrecoverableKeyException, is KeyPermanentlyInvalidatedException -> return Cause.KEY_UNUSABLE
            }
            t = t.cause
            depth++
        }
        return Cause.OTHER
    }

    private fun deleteKeystoreEntry(alias: String): Boolean = try {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(alias)) keyStore.deleteEntry(alias)
        !keyStore.containsAlias(alias)
    } catch (e: GeneralSecurityException) {
        false
    } catch (e: IOException) {
        false
    }
}
