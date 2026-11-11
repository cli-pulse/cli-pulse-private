package com.clipulse.android

import java.io.File

/**
 * Finds a project file or directory from either working directory: `android/app` (Gradle runs
 * unit tests there) or the repo root (an IDE may). Fails, never skips, when it is not found.
 */
internal fun repoFile(relative: String): File {
    val candidates = listOf(File(relative), File("android/app/$relative"))
    return candidates.firstOrNull { it.exists() }
        ?: throw AssertionError("not found: $relative (tried ${candidates.map { it.absolutePath }})")
}
