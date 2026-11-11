package com.clipulse.android.data

import com.clipulse.android.repoFile
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import org.w3c.dom.Node

/**
 * The app opts out of cloud backup and device-to-device transfer. A mode with no rules transfers
 * everything, so BOTH sections must exclude ALL nine documented domains with path ".".
 */
class BackupRulesTest {
    private val androidNs = "http://schemas.android.com/apk/res/android"

    private val nineDomains = setOf(
        "root", "file", "database", "sharedpref", "external",
        "device_root", "device_file", "device_database", "device_sharedpref",
    )

    private fun parse(path: String): Element {
        val factory = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        return factory.newDocumentBuilder().parse(repoFile(path)).documentElement
    }

    private fun elementChildren(e: Element): List<Element> =
        (0 until e.childNodes.length).map { e.childNodes.item(it) }
            .filter { it.nodeType == Node.ELEMENT_NODE }
            .map { it as Element }

    private fun application(): Element =
        parse("src/main/AndroidManifest.xml").getElementsByTagName("application").item(0) as Element

    @Test
    fun `manifest points at the rules and keeps allowBackup false`() {
        val app = application()
        assertEquals(
            "manifest must declare android:dataExtractionRules",
            "@xml/data_extraction_rules",
            app.getAttributeNS(androidNs, "dataExtractionRules"),
        )
        assertEquals("false", app.getAttributeNS(androidNs, "allowBackup"))
    }

    private fun rules() = parse("src/main/res/xml/data_extraction_rules.xml")

    private fun section(name: String): Element {
        val matches = elementChildren(rules()).filter { it.tagName == name }
        assertEquals("exactly one <$name> section is required", 1, matches.size)
        return matches[0]
    }

    private fun excludes(name: String): List<Pair<String, String>> =
        elementChildren(section(name)).filter { it.tagName == "exclude" }
            .map { it.getAttribute("domain") to it.getAttribute("path") }

    @Test
    fun `rules file root has only the two sections`() {
        assertEquals("data-extraction-rules", rules().tagName)
        assertEquals(
            listOf("cloud-backup", "device-transfer"),
            elementChildren(rules()).map { it.tagName }.sorted(),
        )
    }

    @Test
    fun `cloud-backup excludes exactly the nine domains`() =
        assertEquals("cloud-backup must exclude exactly the nine domains", nineDomains, excludes("cloud-backup").map { it.first }.toSet())

    @Test
    fun `device-transfer excludes exactly the nine domains`() =
        assertEquals("device-transfer must exclude exactly the nine domains", nineDomains, excludes("device-transfer").map { it.first }.toSet())

    @Test
    fun `cloud-backup rules all use path dot`() =
        assertTrue("cloud-backup: every exclude must use path=\".\"", excludes("cloud-backup").all { it.second == "." })

    @Test
    fun `device-transfer rules all use path dot`() =
        assertTrue("device-transfer: every exclude must use path=\".\"", excludes("device-transfer").all { it.second == "." })

    @Test
    fun `cloud-backup has only exclude children`() =
        assertEquals(
            "cloud-backup: only <exclude> children allowed (no <include>)",
            setOf("exclude"),
            elementChildren(section("cloud-backup")).map { it.tagName }.toSet(),
        )

    @Test
    fun `device-transfer has only exclude children`() =
        assertEquals(
            "device-transfer: only <exclude> children allowed (no <include>)",
            setOf("exclude"),
            elementChildren(section("device-transfer")).map { it.tagName }.toSet(),
        )
}
