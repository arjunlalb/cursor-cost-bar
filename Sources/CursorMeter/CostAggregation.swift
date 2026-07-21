import Foundation

/// Charged-cost totals for today and the current Monday-aligned week (Pacific Time).
struct CostTotals: Equatable, Sendable {
    let todayDollars: Double
    let weekDollars: Double
    let weekStart: Date
    let asOf: Date

    static func formatDollars(_ amount: Double) -> String {
        String(format: "$%.2f", amount)
    }

    var menuBarTitle: String {
        "\(Self.formatDollars(todayDollars)) · \(Self.formatDollars(weekDollars))"
    }

    var weekStartLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = CostAggregation.pstCalendar
        formatter.timeZone = CostAggregation.pstTimeZone
        formatter.dateFormat = "EEE MMM d"
        return formatter.string(from: weekStart)
    }
}

enum CostAggregation {
    static let pstTimeZone = TimeZone(identifier: "America/Los_Angeles")!

    static var pstCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = pstTimeZone
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
    /// Actual billed dollars for on-demand events only; plan-included usage is $0.
    var billedDollars: Double {
        guard isOnDemandBilled else { return 0 }
        return chargedCentsSafe / 100.0
    }
}

extension Array where Element == UsageEvent {
    func costTotals(now: Date = Date(), calendar: Calendar = CostAggregation.pstCalendar) -> CostTotals {
        let weekStart = CostAggregation.weekStartMonday(for: now, calendar: calendar)
        var todaySum = 0.0
        var weekSum = 0.0
        for event in self {
            guard let eventDate = event.date else { continue }
            let dollars = event.billedDollars
            if calendar.isDate(eventDate, inSameDayAs: now) {
                todaySum += dollars
            }
            if eventDate >= weekStart, eventDate <= now {
                weekSum += dollars
            }
        }
        return CostTotals(
            todayDollars: todaySum,
            weekDollars: weekSum,
            weekStart: weekStart,
            asOf: now
        )
    }
}
