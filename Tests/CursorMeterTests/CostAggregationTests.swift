import XCTest
@testable import CursorMeter

final class CostAggregationTests: XCTestCase {

    private var pstCalendar: Calendar { CostAggregation.pstCalendar }

    private func pstStartOfDay(_ ymd: String) -> Date {
        var comps = DateComponents()
        comps.calendar = pstCalendar
        comps.timeZone = CostAggregation.pstTimeZone
        let parts = ymd.split(separator: "-").map(String.init)
        comps.year = Int(parts[0])
        comps.month = Int(parts[1])
        comps.day = Int(parts[2])
        comps.hour = 0
        comps.minute = 0
        comps.second = 0
        return pstCalendar.date(from: comps)!
    }

    private func event(
        _ ymd: String,
        hour: Int = 12,
        cents: Double,
        onDemand: Bool = true
    ) -> UsageEvent {
        var comps = DateComponents()
        comps.calendar = pstCalendar
        comps.timeZone = CostAggregation.pstTimeZone
        let parts = ymd.split(separator: "-").map(String.init)
        comps.year = Int(parts[0])
        comps.month = Int(parts[1])
        comps.day = Int(parts[2])
        comps.hour = hour
        let day = pstCalendar.date(from: comps)!
        let ms = Int(day.timeIntervalSince1970 * 1000)
        return UsageEvent(
            timestamp: String(ms),
            kind: onDemand ? "USAGE_EVENT_KIND_USAGE_BASED" : "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
            chargedCents: cents
        )
    }

    func testWeekStartMondayOnWednesday() {
        let wed = event("2026-07-22", hour: 15, cents: 0).date!
        let start = CostAggregation.weekStartMonday(for: wed, calendar: pstCalendar)
        XCTAssertEqual(pstCalendar.component(.weekday, from: start), 2)
        XCTAssertEqual(start, pstStartOfDay("2026-07-20"))
    }

    func testWeekStartMondayOnMonday() {
        let mon = pstStartOfDay("2026-07-20")
        let start = CostAggregation.weekStartMonday(for: mon, calendar: pstCalendar)
        XCTAssertEqual(start, mon)
    }

    func testCostTotalsSumsOnDemandOnly() {
        let now = event("2026-07-22", hour: 15, cents: 0).date!
        let events = [
            event("2026-07-22", cents: 125, onDemand: true),
            event("2026-07-22", cents: 999, onDemand: false),
            event("2026-07-21", cents: 50, onDemand: true),
            event("2026-07-14", cents: 500, onDemand: true),
        ]
        let totals = events.costTotals(now: now, calendar: pstCalendar)
        XCTAssertEqual(totals.todayDollars, 1.25, accuracy: 0.001)
        XCTAssertEqual(totals.weekDollars, 1.75, accuracy: 0.001)
        XCTAssertEqual(totals.weekStart, pstStartOfDay("2026-07-20"))
    }

    func testPlanIncludedEventsContributeZero() {
        let now = pstStartOfDay("2026-07-20")
        let events = [event("2026-07-20", cents: 420, onDemand: false)]
        let totals = events.costTotals(now: now, calendar: pstCalendar)
        XCTAssertEqual(totals.todayDollars, 0, accuracy: 0.001)
        XCTAssertEqual(totals.weekDollars, 0, accuracy: 0.001)
    }
}
