package com.clipulse.android.ui.common

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import com.clipulse.android.R

/** The sentence for an error, in the app's language. */
@Composable
fun UiError.text(): String = when (this) {
    UiError.SessionExpired -> stringResource(R.string.error_session_expired)
    UiError.Offline -> stringResource(R.string.error_offline)
    UiError.OfflineUsingCachedSession -> stringResource(R.string.error_offline_cached_session)
    UiError.InvalidCredentials -> stringResource(R.string.error_invalid_credentials)
    UiError.CodeInvalidOrExpired -> stringResource(R.string.error_code_invalid)
    UiError.RateLimited -> stringResource(R.string.error_rate_limited)
    is UiError.Server -> stringResource(R.string.error_server, httpCode)
    is UiError.Unknown -> stringResource(R.string.error_something_went_wrong)
    is UiError.ActionFailed -> stringResource(
        when (action) {
            UiError.Action.Acknowledge -> R.string.error_action_acknowledge
            UiError.Action.Resolve -> R.string.error_action_resolve
            UiError.Action.Snooze -> R.string.error_action_snooze
            UiError.Action.DeleteAccount -> R.string.error_action_delete_account
            UiError.Action.LoadLinkedAccounts -> R.string.error_action_load_linked_accounts
            UiError.Action.StartLink -> R.string.error_action_start_link
            UiError.Action.Link -> R.string.error_action_link
            UiError.Action.Unlink -> R.string.error_action_unlink
        },
        cause.text(),
    )
}
