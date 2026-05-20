import XCTest
@testable import CursorMeter

final class WeeklyUsageTests: XCTestCase {

    // MARK: - WeeklyUsageResponse parsing

    func testParseClickHouseResponse() throws {
        let json = """
        {
          "meta": [
            {"name": "event_date", "type": "Date"},
            {"name": "subscription_included_requests", "type": "Int64"},
            {"name": "usage_based_requests", "type": "Int64"}
          ],
          "data": [
            {
              "event_date": "2026-05-08",
              "subscription_included_requests": 13,
              "usage_based_requests": 2,
              "composer_requests": 0,
              "chat": 0,
              "agent_requests": 13,
              "bugBot": 0,
              "cmdK": 0,
              "api_key_requests": 0
            },
            {
              "event_date": "2026-05-10",
              "subscription_included_requests": 7,
              "usage_based_requests": 0,
              "composer_requests": 0,
              "chat": 0,
              "agent_requests": 7,
              "bugBot": 0,
              "cmdK": 0,
              "api_key_requests": 0
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(
            WeeklyUsageResponse.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(response.data.count, 2)
        XCTAssertEqual(response.data[0].eventDate, "2026-05-08")
        XCTAssertEqual(response.data[0].subscriptionIncludedRequests, 13)
        XCTAssertEqual(response.data[0].usageBasedRequests, 2)
        XCTAssertEqual(response.data[1].eventDate, "2026-05-10")
        XCTAssertEqual(response.data[1].subscriptionIncludedRequests, 7)
    }

    func testParseEmptyData() throws {
        let json = """
        { "meta": [], "data": [] }
        """
        let response = try JSONDecoder().decode(
            WeeklyUsageResponse.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(response.data.isEmpty)
    }

    /// Combined request count used as the chart axis.
    func testDayUsageRowCombinedRequests() {
        let row = WeeklyUsageRow(
            eventDate: "2026-05-08",
            subscriptionIncludedRequests: 13,
            usageBasedRequests: 4
        )
        XCTAssertEqual(row.totalRequests, 17)
    }

    // MARK: - 7-day rolling zero-fill

    /// Helper for date-driven tests: a `today` anchor + UTC calendar so the
    /// rolling window is deterministic regardless of host TZ.
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.calendar = utcCalendar
        f.timeZone = utcCalendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }

    func testSevenDayRollingProducesSevenEntries() {
        let response = WeeklyUsageResponse(meta: [], data: [])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.count, 7)
    }

    func testSevenDayRollingTodayIsRightmost() {
        let response = WeeklyUsageResponse(meta: [], data: [])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.last!.isToday)
        XCTAssertFalse(days.dropLast().contains(where: { $0.isToday }))
    }

    func testSevenDayRollingZeroFillsMissingDates() {
        let response = WeeklyUsageResponse(meta: [], data: [])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertTrue(days.allSatisfy { $0.requests == 0 })
    }

    func testSevenDayRollingPopulatesMatchedDates() {
        let response = WeeklyUsageResponse(meta: [], data: [
            WeeklyUsageRow(eventDate: "2026-05-08", subscriptionIncludedRequests: 13, usageBasedRequests: 2),
            WeeklyUsageRow(eventDate: "2026-05-13", subscriptionIncludedRequests: 7, usageBasedRequests: 0),
        ])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)

        // Window: 05-07, 05-08, 05-09, 05-10, 05-11, 05-12, 05-13
        XCTAssertEqual(days[0].requests, 0, "2026-05-07 missing → 0")
        XCTAssertEqual(days[1].requests, 15, "2026-05-08: 13 + 2")
        XCTAssertEqual(days[6].requests, 7, "today (2026-05-13): 7 + 0")
    }

    func testSevenDayRollingIgnoresDatesOutsideWindow() {
        let response = WeeklyUsageResponse(meta: [], data: [
            WeeklyUsageRow(eventDate: "2026-05-01", subscriptionIncludedRequests: 999, usageBasedRequests: 0),
            WeeklyUsageRow(eventDate: "2026-05-20", subscriptionIncludedRequests: 999, usageBasedRequests: 0),
        ])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        XCTAssertEqual(days.map(\.requests), [0, 0, 0, 0, 0, 0, 0])
    }

    // MARK: - dailyRequestBudget

    private func makeDisplayData(
        requestsLimit: Int,
        cycleStart: String?,
        cycleEnd: String?
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "x", name: "x", membershipType: "enterprise",
            planUsedCents: nil, planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: 0,
            requestsLimit: requestsLimit,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: cycleStart.map { date($0) },
            resetDate: cycleEnd.map { date($0) },
            daysUntilReset: nil
        )
    }

    func testDailyRequestBudget() {
        let data = makeDisplayData(
            requestsLimit: 1500,
            cycleStart: "2026-05-01",
            cycleEnd: "2026-06-01"  // 31 days
        )
        XCTAssertEqual(data.dailyRequestBudget, 1500 / 31)
    }

    func testDailyRequestBudgetReturnsNilWithoutLimit() {
        let data = makeDisplayData(
            requestsLimit: 0,
            cycleStart: "2026-05-01",
            cycleEnd: "2026-06-01"
        )
        XCTAssertNil(data.dailyRequestBudget)
    }

    func testDailyRequestBudgetReturnsNilWithoutCycleStart() {
        let data = makeDisplayData(
            requestsLimit: 500,
            cycleStart: nil,
            cycleEnd: "2026-06-01"
        )
        XCTAssertNil(data.dailyRequestBudget)
    }

    // MARK: - fetchWeeklyUsage (CursorAPIClient)

    func testFetchWeeklyUsageBuildsQuery() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        var captured: URLRequest?
        MockURLProtocol.requestHandler = { request in
            captured = request
            let body = """
            { "meta": [], "data": [
              {"event_date":"2026-05-13","subscription_included_requests":5,"usage_based_requests":1}
            ] }
            """
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }

        let response = try await client.fetchWeeklyUsage(
            cookieHeader: "session=x",
            teamId: 42,
            user: "alice@example.com",
            startDate: "2026-05-07",
            endDate: "2026-05-13"
        )

        XCTAssertEqual(response.data.first?.totalRequests, 6)

        let url = try XCTUnwrap(captured?.url)
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["teamId"], "42")
        XCTAssertEqual(items["user"], "alice@example.com")
        XCTAssertEqual(items["startDate"], "2026-05-07")
        XCTAssertEqual(items["endDate"], "2026-05-13")
        XCTAssertTrue(url.path.hasSuffix("/api/v2/analytics/team/usage"))
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cookie"), "session=x")
    }

    // MARK: - WeeklyChartStyle + UsageViewModel settings persistence

    @MainActor
    func testWeeklyChartStyleRawValueRoundTrip() {
        for style in WeeklyChartStyle.allCases {
            XCTAssertEqual(WeeklyChartStyle(rawValue: style.rawValue), style)
        }
    }

    @MainActor
    func testWeeklyChartSettingsDefaults() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        XCTAssertTrue(vm.weeklyChartEnabled)
        XCTAssertEqual(vm.weeklyChartStyle, .outline)
    }

    @MainActor
    func testSetWeeklyChartEnabledPersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartEnabled(false)

        XCTAssertFalse(vm.weeklyChartEnabled)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "weeklyChartEnabled"), false)

        let reloaded = UsageViewModel()
        XCTAssertFalse(reloaded.weeklyChartEnabled)
    }

    @MainActor
    func testSetWeeklyChartStylePersists() {
        clearWeeklyChartDefaults()
        let vm = UsageViewModel()
        vm.setWeeklyChartStyle(.both)

        XCTAssertEqual(vm.weeklyChartStyle, .both)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "weeklyChartStyle"), WeeklyChartStyle.both.rawValue)

        let reloaded = UsageViewModel()
        XCTAssertEqual(reloaded.weeklyChartStyle, .both)
    }

    private func clearWeeklyChartDefaults() {
        UserDefaults.standard.removeObject(forKey: "weeklyChartEnabled")
        UserDefaults.standard.removeObject(forKey: "weeklyChartStyle")
    }

    func testFetchWeeklyUsage403ThrowsForbidden() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = CursorAPIClient(configuration: config)
        defer { MockURLProtocol.requestHandler = nil }

        MockURLProtocol.requestHandler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        do {
            _ = try await client.fetchWeeklyUsage(
                cookieHeader: "x", teamId: 1, user: "u",
                startDate: "2026-05-07", endDate: "2026-05-13"
            )
            XCTFail("Expected forbidden")
        } catch APIError.forbidden {
            // expected — non-enterprise accounts surface 403 here
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testDailyRequestBudgetReturnsNilWhenCycleNotPositive() {
        let data = makeDisplayData(
            requestsLimit: 500,
            cycleStart: "2026-06-01",
            cycleEnd: "2026-06-01"
        )
        XCTAssertNil(data.dailyRequestBudget)
    }

    func testSevenDayRollingDatesAreConsecutive() {
        let response = WeeklyUsageResponse(meta: [], data: [])
        let days = response.sevenDayRolling(today: date("2026-05-13"), calendar: utcCalendar)
        for i in 1..<days.count {
            let diff = utcCalendar.dateComponents([.day], from: days[i - 1].date, to: days[i].date).day
            XCTAssertEqual(diff, 1, "Each entry should be the next calendar day")
        }
    }
}
