package com.clipulse.android.ui.usage

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R
import com.clipulse.android.ui.navigation.LocalSnackbarHostState
import com.clipulse.android.ui.theme.providerColor
import com.clipulse.android.ui.common.text
import com.clipulse.android.ui.common.DateDisplay
import androidx.compose.ui.platform.LocalConfiguration
import android.text.format.DateFormat
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CostAnalysisScreen(
    viewModel: DailyUsageViewModel = hiltViewModel(),
    onBack: () -> Unit,
) {
    val state by viewModel.state.collectAsState()
    val snackbar = LocalSnackbarHostState.current
    // The selected tab is the range the view model actually loaded. It used to be
    // separate UI state starting at "7 Days" while the view model's init loaded 30,
    // so the screen opened with a 7-day label over 30 days of data.
    val selectedTab = RANGES.indexOf(state.days).coerceAtLeast(0)
    val errorText = state.error?.text()
    LaunchedEffect(state.error) {
        errorText?.let { snackbar.showSnackbar(it) }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.cost_analysis_title)) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            // Time range tabs
            TabRow(selectedTabIndex = selectedTab) {
                Tab(selected = selectedTab == 0, onClick = { viewModel.refresh(RANGES[0]) }) {
                    Text(stringResource(R.string.cost_7_days), modifier = Modifier.padding(12.dp))
                }
                Tab(selected = selectedTab == 1, onClick = { viewModel.refresh(RANGES[1]) }) {
                    Text(stringResource(R.string.cost_14_days), modifier = Modifier.padding(12.dp))
                }
                Tab(selected = selectedTab == 2, onClick = { viewModel.refresh(RANGES[2]) }) {
                    Text(stringResource(R.string.cost_30_days), modifier = Modifier.padding(12.dp))
                }
            }

            Spacer(Modifier.height(16.dp))

            if (state.isLoading) {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator()
                }
            } else if (state.dailyUsage.isEmpty()) {
                Text(
                    stringResource(R.string.cost_no_data),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(32.dp),
                )
            } else {
                // Cost by Provider
                val costByProvider = viewModel.costByProvider().entries.sortedByDescending { it.value }
                if (costByProvider.isNotEmpty()) {
                    Text(
                        stringResource(R.string.cost_by_provider),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    HorizontalBarChart(
                        items = costByProvider.take(8).map { BarItem(it.key, it.value, providerColor(it.key)) },
                    )
                }

                Spacer(Modifier.height(24.dp))

                // Cost by Model
                val costByModel = viewModel.costByModel().entries.sortedByDescending { it.value }
                if (costByModel.isNotEmpty()) {
                    Text(
                        stringResource(R.string.cost_by_model),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    HorizontalBarChart(
                        items = costByModel.take(10).map { BarItem(it.key, it.value, MaterialTheme.colorScheme.primary) },
                    )
                }

                Spacer(Modifier.height(24.dp))

                // Daily cost trend
                val costByDate = viewModel.costByDate()
                if (costByDate.isNotEmpty()) {
                    Text(
                        stringResource(R.string.cost_daily_trend),
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(Modifier.height(8.dp))
                    DailyCostBars(costByDate)
                }
            }
        }
    }
}

data class BarItem(val label: String, val value: Double, val color: Color)

@Composable
private fun HorizontalBarChart(items: List<BarItem>) {
    val maxValue = items.maxOfOrNull { it.value } ?: 1.0
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        for (item in items) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    item.label,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.width(100.dp),
                )
                Spacer(Modifier.width(8.dp))
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .height(16.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(item.color.copy(alpha = 0.1f)),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxHeight()
                            .fillMaxWidth(fraction = if (maxValue > 0) (item.value / maxValue).toFloat() else 0f)
                            .clip(RoundedCornerShape(4.dp))
                            .background(item.color.copy(alpha = 0.7f)),
                    )
                }
                Spacer(Modifier.width(8.dp))
                Text(
                    formatCostCompact(item.value),
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Medium,
                    modifier = Modifier.width(55.dp),
                )
            }
        }
    }
}

/** The tabs' ranges in days, in tab order. */
private val RANGES = listOf(7, 14, 30)

@Composable
private fun DailyCostBars(costByDate: Map<String, Double>) {
    val entries = costByDate.entries.toList()
    val maxCost = entries.maxOfOrNull { it.value } ?: 1.0
    // A bar chart is only colored boxes to TalkBack; say what it shows.
    val summary = pluralStringResource(
        R.plurals.cost_chart_summary, entries.size, entries.size, formatCostCompact(entries.maxOfOrNull { it.value } ?: 0.0),
    )

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(80.dp)
            .clearAndSetSemantics { contentDescription = summary },
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        for ((_, cost) in entries) {
            val fraction = if (maxCost > 0) (cost / maxCost).toFloat() else 0f
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxHeight(fraction = fraction.coerceAtLeast(0.02f))
                    .clip(RoundedCornerShape(topStart = 2.dp, topEnd = 2.dp))
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.6f)),
            )
        }
    }

    // Date labels (first and last), as month and day in the app's language.
    if (entries.size >= 2) {
        val locale = LocalConfiguration.current.locales[0]
        val pattern = remember(locale) { DateFormat.getBestDateTimePattern(locale, "Md") }
        Row(modifier = Modifier.fillMaxWidth()) {
            Text(
                DateDisplay.monthDay(entries.first().key, pattern, locale) ?: entries.first().key.takeLast(5),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.weight(1f))
            Text(
                DateDisplay.monthDay(entries.last().key, pattern, locale) ?: entries.last().key.takeLast(5),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

// internal (not private) so CostAnalysisFormatTest can pin the 2-decimal output.
internal fun formatCostCompact(cost: Double): String {
    if (cost < 0.01) return "<$0.01"
    // Currency is always 2 decimals. The >=$1 branch previously used "$%.1f",
    // rendering $220.00 as "$220.0" / $9.60 as "$9.6" (matches the Swift
    // CostFormatter bug). Use Locale.ROOT so a comma-decimal device locale
    // can't turn "$9.60" into "$9,60".
    return String.format(java.util.Locale.ROOT, "$%.2f", cost)
}
