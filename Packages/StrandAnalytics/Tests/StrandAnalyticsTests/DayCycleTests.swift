import XCTest
@testable import StrandAnalytics

final class DayCycleTests: XCTestCase {
    func testDefaultsAndCalendarMode() {
        XCTAssertEqual(DayCycleMode.persisted(nil), .sleepOnset)
        XCTAssertEqual(DayCycleMode.persisted("midnight"), .midnight)
        let window = DayCycleResolver.activeWindow(mode: .midnight, latestSleep: nil, now: 86_500,
                                                   offsetSec: 0)
        XCTAssertEqual(window.startInclusive, 86_400)
        XCTAssertEqual(window.source, .calendar)
    }

    func testSleepOnsetCycleStaysOpenAcrossMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 20 * 3_600, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        let fallback = DayCycleResolver.fallbackMidnight(after: sleep.startInclusive, offsetSec: 0)
        XCTAssertEqual(fallback, 2 * 86_400)
        let active = DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                   now: fallback, offsetSec: 0)
        XCTAssertEqual(active.source, .detectedSleep)
        XCTAssertEqual(active.startInclusive, sleep.startInclusive)
    }

    /// Both branches of the 18-hour fallback rule, which neither platform pinned.
    ///
    /// `fallbackMidnight` returns the first midnight at least `minSyntheticMidnightAgeSeconds` after onset.
    /// Because the candidate is `floor(minimum / day) * day`, it is at or BELOW `minimum` always — so the
    /// direct branch is reachable only on exact equality, when onset sits precisely 18 h before a midnight.
    /// Every existing case here and on Kotlin used an onset that rolls, so a `>=` quietly weakened to `>`
    /// would have moved that boundary a full day and nothing would have failed.
    func testFallbackTakesTheMidnightExactlyEighteenHoursAfterOnset() {
        // 06:00 + 18 h lands exactly on the next midnight: taken directly, not rolled past.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 6 * 3_600, offsetSec: 0), 86_400)
    }

    /// The rolling branch at a different onset from the case above, so the two are not the same test twice.
    func testFallbackRollsWhenTheNextMidnightIsTooSoon() {
        // 23:00 + 18 h overshoots the next midnight, so the one after it wins.
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: 23 * 3_600, offsetSec: 0), 2 * 86_400)
    }

    /// The boundary is LOCAL midnight, not UTC midnight — and until now nothing said so. Every
    /// day-cycle case on both platforms passed a zero offset, so the whole offset arithmetic, which is
    /// the part that decides which local day a boundary lands on, was unpinned. This repo has already
    /// had days re-bucket on travel once, so it is worth a case rather than an argument.
    ///
    /// 06:00 local at UTC-5 is 11:00 UTC. Plus 18 h is 05:00 UTC the next day, which IS local midnight
    /// there, so the direct branch takes it: 104_400 = 29 h UTC = 00:00 local. A resolver that floored
    /// to UTC midnight would answer 86_400 and be a day out for a third of the planet.
    func testFallbackLandsOnLocalMidnightNotUTC() {
        let offsetSec = -5 * 3_600
        let onsetLocal0600 = 6 * 3_600 - offsetSec
        XCTAssertEqual(DayCycleResolver.fallbackMidnight(after: onsetLocal0600, offsetSec: offsetSec),
                       104_400)
    }

    func testAbsoluteCapStillUsesSyntheticMidnight() {
        let sleep = DayCycleWindow(id: "sleep", startInclusive: 0, endExclusive: 0,
                                   displayDay: "1970-01-01", source: .detectedSleep)
        XCTAssertEqual(DayCycleResolver.activeWindow(mode: .sleepOnset, latestSleep: sleep,
                                                     now: 40 * 3_600, offsetSec: 0).source,
                       .syntheticMidnight)
    }

    func testCoverageSegmentsPreferPriorityWithoutCrossingDeviceCounters() {
        let window = PhysiologicalSteps.CycleWindow(sleepId: "night", onset: 100, endExclusive: 500)
        let segments = PhysiologicalSteps.ownerSegmentsFromCoverage(window, coverage: [
            .init(owner: "secondary", onset: 100, endExclusive: 350, priority: 1),
            .init(owner: "active", onset: 200, endExclusive: 500, priority: 0),
        ], fallbackOwner: "secondary")
        XCTAssertEqual(segments, [
            .init(owner: "secondary", onset: 100, endExclusive: 200),
            .init(owner: "active", onset: 200, endExclusive: 500),
        ])
    }

    /// Refs #2626: a night starting before the 20:00 overnight band still opens the day cycle.
    func testEarlyBedtimeBeforeOvernightBandStillOpensTheCycle() {
        // 2026-09-22 19:45 → 2026-09-23 04:15 UTC
        let onset = 1_790_106_300 // pinned: 2026-09-22T19:45:00Z
        let end = onset + (8 * 3_600 + 30 * 60)
        // Verify the pin: 19:45 local is outside isOvernightOnset [20:00, 11:00).
        XCTAssertFalse(SleepStageTotals.isOvernightOnset(onset, offsetSec: 0))
        let classified = PhysiologicalSteps.classifyForCycle(
            [.init(onset: onset, end: end, id: "early")], offsetSec: 0, habitualMidsleepSec: nil)
        XCTAssertEqual(classified.count, 1)
        XCTAssertEqual(classified[0].kind, .mainSleep)
    }

    /// Refs #2626: a ≥40 h gap between two main nights closes at local midnight.
    func testLongGapBetweenMainNightsInsertsSyntheticMidnight() {
        let nightA = PhysiologicalSteps.CycleBoundary(sleepId: "night-a", onset: 20 * 3_600)
        let nightC = PhysiologicalSteps.CycleBoundary(sleepId: "night-c", onset: nightA.onset + 2 * 86_400)
        let now = nightC.onset + 12 * 3_600
        let closed = DayCycleResolver.boundariesClosingLongGaps([nightA, nightC], now: now, offsetSec: 0)
        let synthetic = closed.filter { $0.sleepId.hasPrefix("synthetic:") }
        XCTAssertEqual(synthetic.count, 1)
        XCTAssertEqual(synthetic[0].onset, DayCycleResolver.fallbackMidnight(after: nightA.onset, offsetSec: 0))
        let windows = PhysiologicalSteps.cycleWindows(closed, now: now)
        let windowA = try! XCTUnwrap(windows.first { $0.sleepId == "night-a" })
        XCTAssertEqual(windowA.endExclusive, synthetic[0].onset)
        XCTAssertLessThan(windowA.endExclusive - windowA.onset, DayCycleResolver.absoluteMaxOpenSeconds)
    }

    func testOpenTailPastAbsoluteCapStillInsertsSyntheticMidnight() {
        let night = PhysiologicalSteps.CycleBoundary(sleepId: "night", onset: 0)
        let now = 48 * 3_600
        let closed = DayCycleResolver.boundariesClosingLongGaps([night], now: now, offsetSec: 0)
        XCTAssertTrue(closed.contains { $0.sleepId.hasPrefix("synthetic:") })
        let windows = PhysiologicalSteps.cycleWindows(closed, now: now)
        XCTAssertTrue(windows.allSatisfy { $0.endExclusive - $0.onset < DayCycleResolver.absoluteMaxOpenSeconds })
    }
}
