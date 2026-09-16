package com.clipulse.android.ui.common

import com.clipulse.android.R
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The tier-name mapper against the decision record every platform shares,
 * scripts/quota_tier_names.json. Reads the manifest itself rather than a copy, and
 * fails (never skips) if it cannot find it: a skipped guard reads as a passing one.
 */
class QuotaTierDisplayTest {

    private val entries by lazy {
        // Gradle runs unit tests from android/app.
        val file = File("../../scripts/quota_tier_names.json")
        assertTrue("manifest not found at ${file.absolutePath}", file.isFile)
        val array = JSONObject(file.readText()).getJSONArray("entries")
        (0 until array.length()).map { array.getJSONObject(it) }
    }

    @Test
    fun `every TRANSLATE name maps to its resource, whatever its case`() {
        val translate = entries.filter { it.getString("display") == "TRANSLATE" }
        assertTrue("expected dozens of TRANSLATE names, found ${translate.size}", translate.size > 30)
        for (entry in translate) {
            val name = entry.getString("name")
            val key = entry.getString("l10n_key").replace('.', '_')
            val expected = R.string::class.java.getField(key).getInt(null)
            assertEquals(name, expected, QuotaTierDisplay.label(name))
            assertEquals(name.uppercase(), expected, QuotaTierDisplay.label(name.uppercase()))
        }
    }

    @Test
    fun `vendor terms pass through untranslated`() {
        val passthrough = entries.filter { it.getString("display") == "PASSTHROUGH" }
        assertTrue(passthrough.isNotEmpty())
        for (entry in passthrough) {
            assertNull(entry.getString("name"), QuotaTierDisplay.label(entry.getString("name")))
        }
    }

    @Test
    fun `an unknown name passes through`() {
        assertNull(QuotaTierDisplay.label("Some New Bucket"))
    }
}
