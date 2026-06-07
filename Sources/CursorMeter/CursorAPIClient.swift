import Foundation

enum APIError: Error {
    case unauthorized
    case forbidden
    case httpError(statusCode: Int)
    case networkError(Error)
}

actor CursorAPIClient {
    private static let usageURL = URL(string: "https://www.cursor.com/api/usage")!
    private static let usageSummaryURL = URL(string: "https://www.cursor.com/api/usage-summary")!
    private static let userInfoURL = URL(string: "https://www.cursor.com/api/auth/me")!
    private static let teamsURL = URL(string: "https://www.cursor.com/api/dashboard/teams")!
    // Dashboard POST endpoints reject the `www.` host (308 redirect) when
    // combined with `Origin: https://cursor.com` — the bare-host canonical URL
    // is the only one that returns 200 for these CSRF-checked endpoints.
    private static let filteredUsageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    private static let teamSpendURL = URL(string: "https://cursor.com/api/dashboard/get-team-spend")!

    private let session: URLSession

    init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? {
            let c = URLSessionConfiguration.ephemeral
            c.httpShouldSetCookies = false
            c.httpCookieAcceptPolicy = .never
            c.timeoutIntervalForRequest = 15
            return c
        }()
        self.session = URLSession(configuration: config)
    }

    func fetchUsage(cookieHeader: String) async throws -> UsageResponse {
        let data = try await performRequest(url: Self.usageURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func fetchUsageSummary(cookieHeader: String) async throws -> UsageSummaryResponse {
        let data = try await performRequest(url: Self.usageSummaryURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
    }

    func fetchUserInfo(cookieHeader: String) async throws -> UserInfoResponse {
        let data = try await performRequest(url: Self.userInfoURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(UserInfoResponse.self, from: data)
    }

    /// Lists teams the account belongs to. Used solely to discover a `teamId`
    /// for the analytics endpoint — required on enterprise accounts and
    /// expected to fail (non-200 or empty) on personal plans.
    func fetchTeams(cookieHeader: String) async throws -> TeamsResponse {
        let data = try await performRequest(url: Self.teamsURL, cookieHeader: cookieHeader)
        return try JSONDecoder().decode(TeamsResponse.self, from: data)
    }

    /// Fetches one page of usage events from the dashboard. Events are returned
    /// newest-first; callers paginate by incrementing `page` until the oldest
    /// event in a page is older than the desired window (or `totalUsageEventsCount`
    /// is reached).
    ///
    /// Requires the `Origin: https://cursor.com` header — the endpoint enforces
    /// origin checks on POST. Without it the server returns
    /// `{"error":"Invalid origin for state-changing request"}`.
    func fetchWeeklyUsage(
        cookieHeader: String,
        teamId: Int,
        userId: Int,
        page: Int,
        pageSize: Int = 100
    ) async throws -> FilteredUsageEventsResponse {
        let bodyDict: [String: Any] = [
            "teamId": teamId,
            "userId": userId,
            "page": page,
            "pageSize": pageSize,
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        let data = try await performRequest(
            url: Self.filteredUsageEventsURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: body,
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: data)
    }

    /// Fetches the team's member-spend roster solely to discover the caller's
    /// numeric `userId`. Required because `/api/auth/me` returns a workos id but
    /// the dashboard endpoint expects the numeric id. Same Origin-header
    /// requirement as the filtered-usage endpoint.
    func fetchTeamSpend(cookieHeader: String, teamId: Int) async throws -> TeamSpendResponse {
        let body = try JSONSerialization.data(withJSONObject: ["teamId": teamId], options: [])
        let data = try await performRequest(
            url: Self.teamSpendURL,
            cookieHeader: cookieHeader,
            method: "POST",
            body: body,
            origin: "https://cursor.com"
        )
        return try JSONDecoder().decode(TeamSpendResponse.self, from: data)
    }

    private func performRequest(
        url: URL,
        cookieHeader: String,
        method: String = "GET",
        body: Data? = nil,
        origin: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.networkError(
                NSError(domain: "CursorMeter", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
        }

        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        if httpResponse.statusCode == 403 {
            throw APIError.forbidden
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}
