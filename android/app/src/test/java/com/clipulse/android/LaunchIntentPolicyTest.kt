package com.clipulse.android

import org.junit.Assert.assertEquals
import org.junit.Test

/** Which intents MainActivity.onCreate hands to the OAuth callback owner. */
class LaunchIntentPolicyTest {

    @Test
    fun `only an Activity started with its intent just now hands it over`() {
        val table = listOf(
            Triple(false, false, true), // a first creation: the intent is new
            Triple(true, false, false), // a rotation or a restore after a process death
            Triple(false, true, false), // relaunched from Recents: the original intent replayed
            Triple(true, true, false),
        )
        for ((isRecreation, fromHistory, expected) in table) {
            assertEquals(
                "isRecreation=$isRecreation fromHistory=$fromHistory",
                expected,
                shouldHandleLaunchIntent(isRecreation = isRecreation, fromHistory = fromHistory),
            )
        }
    }
}
