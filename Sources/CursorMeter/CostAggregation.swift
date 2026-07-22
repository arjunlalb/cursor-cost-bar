import Foundation

// MARK: - Dashboard usage totals (UTC today + Monday week PT)

struct DashboardPeriodTotals: Equatable, Sendable {
    var totalUsageDollars: Double = 0
    var includedDollars: Double = 0
    var onDemandDollars: Double = 0
}

/// One calendar day in Pacific Time (Mon–today) for the weekly breakdown view.
struct DaySpendRow: Equatable, Sendable {
    let dayStart: Date
    let label: String
    let totals: DashboardPeriodTotals
    let isToday: Bool
}

struct DashboardUsageTotals: Equatable, Sendable {
    let todayUTC: DashboardPeriodTotals
    let todayPacific: DashboardPeriodTotals
    /// Spend from Monday 00:00 PT through now (matches the weekly limit window).
    let week: DashboardPeriodTotals
    /// Monday 00:00 PT through today, one row per day.
    let weekDays: [DaySpendRow]
    let weekStart: Date
    let asOf: Date
    let weekEventsIncomplete: Bool

    init(
        todayUTC: DashboardPeriodTotals,
        todayPacific: DashboardPeriodTotals,
        week: DashboardPeriodTotals,
        weekDays: [DaySpendRow],
        weekStart: Date,
        asOf: Date,
        weekEventsIncomplete: Bool = false
    ) {
        self.todayUTC = todayUTC
        self.todayPacific = todayPacific
        self.week = week
        self.weekDays = weekDays
        self.weekStart = weekStart
        self.asOf = asOf
        self.weekEventsIncomplete = weekEventsIncomplete
    }

    func today(for timezone: UsageDayTimezone) -> DashboardPeriodTotals {
        switch timezone {
        case .utc: todayUTC
        case .pacific: todayPacific
        }
    }

    var weekStartLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = CostAggregation.pstCalendar
        formatter.timeZone = CostAggregation.pstTimeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: weekStart)
    }

    func menuBarTitle(dayTimezone: UsageDayTimezone) -> String {
        let today = MenuBarMetric.totalUsage.formatValue(today(for: dayTimezone))
        let week = MenuBarMetric.totalUsage.formatValue(week)
        return "\(today) · \(week)"
    }
}

/// Calendar used for the popover/menu-bar "today" column.
enum UsageDayTimezone: Int, CaseIterable, Sendable {
    case utc = 0
    case pacific

    var label: String {
        switch self {
        case .utc: "UTC"
        case .pacific: "PT"
        }
    }

    var todayHeader: String {
        switch self {
        case .utc: "Today UTC"
        case .pacific: "Today PT"
        }
    }
}

/// Popover layout: summary (today UTC + week PT) vs per-day week breakdown.
enum UsagePopoverView: Int, CaseIterable, Sendable {
    case daily = 0
    case weekly

    var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

enum MenuBarMetric: Int, CaseIterable, Sendable {
    case totalUsage = 0
    case included
    case onDemand

    var label: String {
        switch self {
        case .totalUsage: "Total usage"
        case .included: "Included"
        case .onDemand: "On-demand"
        }
    }

    func formatValue(_ period: DashboardPeriodTotals) -> String {
        Self.formatDollars(value(for: period))
    }

    func value(for period: DashboardPeriodTotals) -> Double {
        switch self {
        case .totalUsage: period.totalUsageDollars
        case .included: period.includedDollars
        case .onDemand: period.onDemandDollars
        }
    }

    static func formatDollars(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }
}

enum CostAggregation {
    static let pstTimeZone = TimeZone(identifier: "America/Los_Angeles")!
    static let utcTimeZone = TimeZone(identifier: "UTC")!

    static var pstCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pstTimeZone
        return cal
    }

    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utcTimeZone
        return cal
    }

    /// Most recent Monday 00:00:00 in Pacific Time (inclusive week start).
    static func weekStartMonday(for date: Date, calendar: Calendar = pstCalendar) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: startOfDay)
        let daysSinceMonday = (weekday + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday, to: startOfDay)!
    }
}

extension UsageEvent {
    private var dashboardDollars: Double {
        chargedCentsSafe / 100.0
    }

    var onDemandDollars: Double {
        guard isOnDemandBilled else { return 0 }
        return dashboardDollars
    }

    var includedDollars: Double {
        guard !isOnDemandBilled else { return 0 }
        return dashboardDollars
    }

    var totalUsageDollars: Double {
        dashboardDollars
    }
}

extension Array where Element == UsageEvent {
    func dashboardTotals(
        now: Date = Date(),
        pstCalendar: Calendar = CostAggregation.pstCalendar,
        utcCalendar: Calendar = CostAggregation.utcCalendar,
        weekEventsIncomplete: Bool = false
    ) -> DashboardUsageTotals {
        let weekStart = CostAggregation.weekStartMonday(for: now, calendar: pstCalendar)
        var todayUTC = DashboardPeriodTotals()
        var todayPacific = DashboardPeriodTotals()
        var week = DashboardPeriodTotals()

        for event in self {
            guard let eventDate = event.date else { continue }
            if utcCalendar.isDate(eventDate, inSameDayAs: now) {
                accumulate(event, into: &todayUTC)
            }
            if pstCalendar.isDate(eventDate, inSameDayAs: now) {
                accumulate(event, into: &todayPacific)
            }
            if eventDate >= weekStart && eventDate <= now {
                accumulate(event, into: &week)
            }
        }

        let weekDays = buildWeekDayRows(
            now: now,
            pstCalendar: pstCalendar,
            weekStart: weekStart
        )

        return DashboardUsageTotals(
            todayUTC: todayUTC,
            todayPacific: todayPacific,
            week: week,
            weekDays: weekDays,
            weekStart: weekStart,
            asOf: now,
            weekEventsIncomplete: weekEventsIncomplete
        )
    }

    private func buildWeekDayRows(
        now: Date,
        pstCalendar: Calendar,
        weekStart: Date
    ) -> [DaySpendRow] {
        let endOfToday = pstCalendar.startOfDay(for: now)
        let dayLabelFormatter = Self.dayLabelFormatter(calendar: pstCalendar)
        var rows: [DaySpendRow] = []
        var day = weekStart

        while day <= endOfToday {
            var totals = DashboardPeriodTotals()
            for event in self {
                guard let eventDate = event.date else { continue }
                if pstCalendar.isDate(eventDate, inSameDayAs: day) {
                    accumulate(event, into: &totals)
                }
            }
            rows.append(DaySpendRow(
                dayStart: day,
                label: dayLabelFormatter.string(from: day),
                totals: totals,
                isToday: pstCalendar.isDate(day, inSameDayAs: now)
            ))
            guard let next = pstCalendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return rows
    }

    private static func dayLabelFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE M/d"
        return formatter
    }

    private func accumulate(_ event: UsageEvent, into period: inout DashboardPeriodTotals) {
        period.totalUsageDollars += event.totalUsageDollars
        period.includedDollars += event.includedDollars
        period.onDemandDollars += event.onDemandDollars
    }
}
