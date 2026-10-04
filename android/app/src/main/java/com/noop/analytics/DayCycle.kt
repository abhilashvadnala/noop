package com.noop.analytics

/**
 * User-selectable ownership rule for additive daily metrics.
 *
 * Sleep and recovery values keep their night/wake-day semantics; this setting is for values accumulated
 * while awake, such as steps, energy and cardiovascular load.
 */
enum class DayCycleMode(val persistedValue: String) {
    SLEEP_ONSET("sleep_onset"),
    MIDNIGHT("midnight");

    companion object {
        fun fromPersisted(value: String?): DayCycleMode = entries.firstOrNull {
            it.persistedValue == value
        } ?: SLEEP_ONSET
    }
}

/** Shared cycle window consumed by every additive daily metric. */
data class DayCycleWindow(
    val id: String,
    val startInclusive: Long,
    val endExclusive: Long,
    val displayDay: String,
    val source: Source,
) {
    enum class Source { DETECTED_SLEEP, EDITED_SLEEP, SYNTHETIC_MIDNIGHT, CALENDAR }
}

object DayCycleResolver {
    const val MIN_SYNTHETIC_MIDNIGHT_AGE_SECONDS = 18 * 3_600L
    const val ABSOLUTE_MAX_OPEN_SECONDS = 40 * 3_600L

    /** Midnight is always available and is also the honest cold-start/failure fallback. */
    fun calendarWindow(now: Long, tzOffsetSeconds: Long): DayCycleWindow {
        val local = now + tzOffsetSeconds
        val dayNumber = Math.floorDiv(local, SleepStageTotals.SECONDS_PER_DAY)
        val start = dayNumber * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
        val day = AnalyticsEngine.dayString(start, tzOffsetSeconds)
        return DayCycleWindow("calendar:$day", start, now, day, DayCycleWindow.Source.CALENDAR)
    }

    /** First local midnight that does not truncate a freshly-started sleep cycle. */
    fun fallbackMidnightAfter(start: Long, tzOffsetSeconds: Long): Long {
        val minimum = start + MIN_SYNTHETIC_MIDNIGHT_AGE_SECONDS
        val local = minimum + tzOffsetSeconds
        val dayNumber = Math.floorDiv(local, SleepStageTotals.SECONDS_PER_DAY)
        val atMidnight = dayNumber * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
        return if (atMidnight >= minimum) atMidnight
        else (dayNumber + 1) * SleepStageTotals.SECONDS_PER_DAY - tzOffsetSeconds
    }

    /**
     * Resolve the active window. Sleep-onset mode stays open across midnight even when awake coverage is
     * unavailable. The absolute cap still prevents a stale sleep boundary from remaining active forever.
     *
     * That "even when" is unconditional, not a gate: an earlier design decided it from whether awake
     * coverage was reliable and carried a `reliableAwakeCoverage` parameter for it. The gate was dropped
     * but the parameter survived — unread on both platforms, and passed `false` by every one of its call
     * sites — so it was removed rather than left looking like a switch someone could flip.
     */
    fun activeWindow(
        mode: DayCycleMode,
        latestSleep: DayCycleWindow?,
        now: Long,
        tzOffsetSeconds: Long,
    ): DayCycleWindow {
        if (mode == DayCycleMode.MIDNIGHT || latestSleep == null) {
            return calendarWindow(now, tzOffsetSeconds)
        }
        val age = now - latestSleep.startInclusive
        val mustFallback = age >= ABSOLUTE_MAX_OPEN_SECONDS
        if (!mustFallback) return latestSleep.copy(endExclusive = now)
        val boundary = fallbackMidnightAfter(latestSleep.startInclusive, tzOffsetSeconds)
        val day = AnalyticsEngine.dayString(boundary, tzOffsetSeconds)
        return DayCycleWindow(
            id = "synthetic:$day",
            startInclusive = boundary,
            endExclusive = now,
            displayDay = day,
            source = DayCycleWindow.Source.SYNTHETIC_MIDNIGHT,
        )
    }

    /**
     * Insert local-midnight boundaries wherever a gap between consecutive sleep boundaries (or the
     * open tail to [now]) reaches [ABSOLUTE_MAX_OPEN_SECONDS]. Settings copy promises "missing sleep
     * falls back to local midnight"; without this, a skipped main-night classification left the
     * previous window spanning two wake days and swallowed the middle day's steps/Effort/calories.
     * Swift twin: `DayCycleResolver.boundariesClosingLongGaps`. Refs #2626.
     */
    fun boundariesClosingLongGaps(
        boundaries: List<PhysiologicalSteps.CycleBoundary>,
        now: Long,
        tzOffsetSeconds: Long,
    ): List<PhysiologicalSteps.CycleBoundary> {
        val ordered = boundaries.asSequence()
            .filter { it.onset <= now }
            .distinctBy { it.sleepId }
            .sortedBy { it.onset }
            .toList()
        if (ordered.isEmpty()) return emptyList()
        val seen = ordered.mapTo(HashSet()) { it.sleepId }
        val result = ArrayList<PhysiologicalSteps.CycleBoundary>()
        for (index in ordered.indices) {
            val boundary = ordered[index]
            result += boundary
            val nextOnset = ordered.getOrNull(index + 1)?.onset ?: now
            var cursor = boundary.onset
            while (nextOnset - cursor >= ABSOLUTE_MAX_OPEN_SECONDS) {
                val midnight = fallbackMidnightAfter(cursor, tzOffsetSeconds)
                if (midnight <= cursor || midnight >= nextOnset) break
                val day = AnalyticsEngine.dayString(midnight, tzOffsetSeconds)
                val synthetic = PhysiologicalSteps.CycleBoundary("synthetic:$day", midnight)
                if (!seen.add(synthetic.sleepId)) break
                result += synthetic
                cursor = midnight
            }
        }
        return result
    }
}
