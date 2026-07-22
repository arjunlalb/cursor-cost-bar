import XCTest
@testable import CursorMeter

final class CostAggregationTests: XCTestCase {

    private var pstCalendar: Calendar { CostAggregation.pstCalendar }
    private var utcCalendar: Calendar { CostAggregation.utcCalendar }

    private func pstStartOfDay(_ ymd: String) -> Date {
        date(ymd, hour: 0, calendar: pstCalendar)
    }

    private func date(_ ymd: String, hour: Int, calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.calendar = calendar
        comps.timeZone = calendar.timeZone
        let parts = ymd.split(separator: "-").map(String.init)
        comps.year = Int(parts[0])
        comps.month = Int(parts[1])
        comps.day = Int(parts[2])
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return calendar.date(from: comps)!
    }

    private func event(at date: Date, chargedCents: Double) -> UsageEvent {
        let ms = Int(date.timeIntervalSince1970 * 1000)
        return UsageEvent(
            timestamp: String(ms),
            requestsCosts: 1,
            kind: "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
            chargedCents: chargedCents
        )
    }

    func testTodayCanBeUTCOrPacific() {
        // Jul 21 00:30 UTC = Jul 20 17:30 PT
        let eventDate = date("2026-07-21", hour: 0, calendar: utcCalendar).addingTimeInterval(30 * 60)
        let now = date("2026-07-21", hour: 12, calendar: utcCalendar)
        let events = [event(at: eventDate, chargedCents: 301)]
        let totals = events.dashboardTotals(now: now, pstCalendar: pstCalendar, utcCalendar: utcCalendar)

        XCTAssertEqual(totals.today(for: .utc).totalUsageDollars, 3.01, accuracy: 0.001)
        XCTAssertEqual(totals.today(for: .pacific).totalUsageDollars, 0, accuracy: 0.001)
    }

    func testMenuBarTitleRespectsDayTimezone() {
        let totals = DashboardUsageTotals(
            todayUTC: DashboardPeriodTotals(totalUsageDollars: 3.01),
            todayPacific: DashboardPeriodTotals(totalUsageDollars: 12.80),
            week: DashboardPeriodTotals(totalUsageDollars: 67.01),
            weekDays: [],
            weekStart: pstStartOfDay("2026-07-20"),
            asOf: pstStartOfDay("2026-07-22")
        )
        XCTAssertEqual(totals.menuBarTitle(dayTimezone: .utc), "$3.01 · $67.01")
        XCTAssertEqual(totals.menuBarTitle(dayTimezone: .pacific), "$12.80 · $67.01")
    }
}
