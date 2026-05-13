import Foundation

// MARK: - API Response: /api/v2/analytics/team/usage (ClickHouse meta+data shape)

struct WeeklyUsageResponse: Codable, Sendable {
    let meta: [MetaField]
    let data: [WeeklyUsageRow]

    struct MetaField: Codable, Sendable {
        let name: String
        let type: String
    }
}

struct WeeklyUsageRow: Codable, Sendable {
    /// `YYYY-MM-DD` (UTC date as returned by the analytics endpoint).
    let eventDate: String
    let subscriptionIncludedRequests: Int
    let usageBasedRequests: Int

    /// Chart axis — combined included + on-demand requests for the day.
    var totalRequests: Int {
        subscriptionIncludedRequests + usageBasedRequests
    }

    enum CodingKeys: String, CodingKey {
        case eventDate = "event_date"
        case subscriptionIncludedRequests = "subscription_included_requests"
        case usageBasedRequests = "usage_based_requests"
    }
}

// MARK: - API Response: /api/dashboard/teams

/// Minimal shape — only the fields needed to pick a `teamId` for the analytics
/// endpoint. The real Cursor dashboard response carries more fields; everything
/// outside `id`/`name` is ignored.
struct TeamsResponse: Codable, Sendable {
    let teams: [Team]
}

struct Team: Codable, Sendable {
    let id: Int
    let name: String?
}

// MARK: - 7-day rolling display model

struct DayUsage: Sendable, Equatable {
    let date: Date
    let requests: Int
    let isToday: Bool
}

extension WeeklyUsageResponse {
    /// Builds an ordered 7-day array ending on `today` (rightmost).
    /// Missing days in `data` are zero-filled. The match between API
    /// `event_date` (UTC `YYYY-MM-DD`) and a window date uses the supplied
    /// calendar — pass `Calendar.current` for production (local TZ), inject
    /// UTC in tests for determinism.
    func sevenDayRolling(today: Date = Date(), calendar: Calendar = .current) -> [DayUsage] {
        let startOfToday = calendar.startOfDay(for: today)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let byDate = Dictionary(uniqueKeysWithValues: data.map { ($0.eventDate, $0) })

        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)!
            let key = formatter.string(from: day)
            let requests = byDate[key]?.totalRequests ?? 0
            return DayUsage(date: day, requests: requests, isToday: offset == 0)
        }
    }
}
