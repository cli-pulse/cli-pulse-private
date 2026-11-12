package com.clipulse.android

/**
 * Whether MainActivity.onCreate hands its intent (possibly an OAuth deep link) to the
 * callback owner: only for an Activity started with that intent just now. Not when it is
 * recreated ([isRecreation]: a rotation, or a restore after a process death), and not when
 * Android relaunched it from Recents ([fromHistory]: `FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY`,
 * which replays the original intent). In both cases the intent is an old one: its link was
 * handled when it first arrived. A plain function, so a JVM test can check the table.
 */
internal fun shouldHandleLaunchIntent(isRecreation: Boolean, fromHistory: Boolean): Boolean =
    !isRecreation && !fromHistory
