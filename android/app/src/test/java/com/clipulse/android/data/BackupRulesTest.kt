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

    @Test
    fun `rules file has exactly cloud-backup and device-transfer`() {
        val root = parse("src/main/res/xml/data_extraction_rules.xml")
        assertEquals("data-extraction-rules", root.tagName)
        val sections = elementChildren(root).map { it.tagName }
        assertEquals(listOf("cloud-backup", "device-transfer"), sections.sorted())
    }

    @Test
    fun `each section excludes all nine domains with path dot and nothing else`() {
        val root = parse("src/main/res/xml/data_extraction_rules.xml")
        for (section in elementChildren(root)) {
            val children = elementChildren(section)
            val tags = children.map { it.tagName }.toSet()
            assertEquals("${section.tagName}: only <exclude> children allowed (no <include>)", setOf("exclude"), tags)
            val pairs = children.map { it.getAttribute("domain") to it.getAttribute("path") }
            assertEquals("${section.tagName}: duplicate rule", pairs.size, pairs.toSet().size)
            assertEquals(
                "${section.tagName}: must exclude exactly the nine domains",
                nineDomains,
                pairs.map { it.first }.toSet(),
            )
            assertTrue(
                "${section.tagName}: every exclude must use path=\".\"",
                pairs.all { it.second == "." },
            )
        }
    }
}
