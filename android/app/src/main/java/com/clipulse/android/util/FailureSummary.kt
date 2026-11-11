package com.clipulse.android.util

import com.clipulse.android.data.remote.ApiError

/**
 * What a log line may say about a failure: the exception class and, for an HTTP error, its status.
 * Never the message or stack: an [ApiError.Http] message carries the server response body.
 */
internal fun failureSummary(e: Throwable): String =
    "${e.javaClass.simpleName} status=${(e as? ApiError.Http)?.code}"
