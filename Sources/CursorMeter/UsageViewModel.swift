import Foundation
import Observation

enum AuthState {
    case loggedOut
    case loggedIn
    case loginRequired
}

/// Centralized UserDefaults keys. Avoids the typo class of bug where a
/// setter writes one literal and `loadSettings` reads a slightly different one.
private enum SettingsKey: String {
    case refreshInterval = "refreshIntervalSeconds"
    case notificationEnabled
    case warningThreshold
    case criticalThreshold
    case menuBarDisplayMode
    case jumpEffectEnabled
    case jumpIntensity
    case weeklyChartEnabled
    case weeklyChartStyle
    // Legacy keys consulted only by `loadSettings` migration block.
    case legacyShowMenuBarText = "showMenuBarText"
    case legacyShowMenuBarPercent = "showMenuBarPercent"
}

private extension UserDefaults {
    func set(_ value: Any?, for key: SettingsKey) { set(value, forKey: key.rawValue) }
    func object(for key: SettingsKey) -> Any? { object(forKey: key.rawValue) }
}

enum RefreshInterval: Int, CaseIterable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var label: String {
        switch self {
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}

// MARK: - Jump Effect Types

/// Magnitude of a usage jump between successive refreshes.
struct JumpEvent: Sendable, Equatable {
    enum Tier: Int, Sendable { case zero = 0, one = 1, two = 2 }

    /// Display mode the delta was computed in. Determines `displayDelta` formatting.
    enum Mode: Sendable, Equatable {
        case credit       // USD cents
        case request      // request count
        case percent      // server-provided percent (%-points)
    }

    let tier: Tier
    /// Delta in canonical units (cents / requests / %-points).
    let deltaCanonical: Double
    /// Delta as % of plan limit (used for tier classification).
    let deltaPct: Double
    let mode: Mode
    /// User-facing string already formatted with sign (e.g. "+$0.30", "+30 / 50", "+15.0%").
    let displayDelta: String
    let timestamp: Date
}

/// User-selectable visual intensity for the jump effect.
enum JumpIntensity: Int, Sendable, CaseIterable {
    case quiet = 0
    case normal = 1
    case bold = 2
}

/// Today-bar emphasis style for the weekly chart.
enum WeeklyChartStyle: Int, Sendable, CaseIterable {
    case outline = 0
    case dimOthers = 1
    case both = 2
}

@Observable
@MainActor
final class UsageViewModel {
    // MARK: - Auth & Data

    var authState: AuthState = .loggedOut
    var usageData: UsageDisplayData?
    var errorMessage: String?
    var isLoading = false
    var availableUpdate: UpdateChecker.Release?
    var isCheckingUpdate = false

    // MARK: - Settings

    var refreshInterval: RefreshInterval = .fiveMinutes
    var notificationEnabled: Bool = true
    var warningThreshold: Int = 80
    var criticalThreshold: Int = 90
    /// 0 = none, 1 = fraction (e.g. 120/500), 2 = percent (e.g. 24%)
    var menuBarDisplayMode: Int = 0

    // MARK: - Jump Effect

    /// Last detected jump (set on every successful refresh that produced a positive delta).
    /// `nil` while no jump has occurred since launch (or after skip conditions).
    var lastJump: JumpEvent?
    var jumpEffectEnabled: Bool = true
    var jumpIntensity: JumpIntensity = .normal

    // MARK: - Weekly Chart

    /// Last successful weekly fetch, retained across failed refreshes so the
    /// chart keeps rendering when the network blips.
    var weeklyData: [DayUsage]?
    /// True when the active account is an enterprise team (membershipType ==
    /// "enterprise" AND a teamId was discovered AND the analytics endpoint
    /// responded 200 at least once).
    var isEnterpriseTeam: Bool = false
    var weeklyChartEnabled: Bool = true
    var weeklyChartStyle: WeeklyChartStyle = .outline

    // MARK: - Private

    private var isRefreshing = false
    private let apiClient = CursorAPIClient()
    private var refreshTask: Task<Void, Never>?
    private var cachedCookieHeader: String?
    private let notificationManager = NotificationManager()

    // Previous canonical values for delta tracking. Reset to nil when display mode changes
    // (e.g. plan migration) so we don't compare across incompatible units.
    private var previousPlanUsedCents: Int?
    private var previousRequestsUsed: Int?
    private var previousServerPercent: Double?
    private var previousMode: JumpEvent.Mode?

    /// Discovered team id, cached after the first successful teams fetch.
    /// Stays set across refreshes so we don't re-call `/api/dashboard/teams`
    /// on every cycle.
    private var cachedTeamId: Int?

    /// Last observed billing-cycle start. Used to detect cycle rollover so we
    /// can clear the threshold-notification dedup set and let the user know
    /// when usage crosses 80/90 in the new cycle.
    private var previousCycleStart: Date?

    // MARK: - Init

    init() {
        loadSettings()
        Task { availableUpdate = await UpdateChecker.shared.check() }
    }

    // MARK: - Session

    func checkExistingSession() {
        do {
            if let header = try KeychainStore.loadCookieHeader() {
                cachedCookieHeader = header
                startSession()
            }
        } catch {
            Log.error("Failed to load keychain: \(error)")
        }
    }

    func onLoginSuccess(cookieHeader: String) {
        cachedCookieHeader = cookieHeader
        do {
            try KeychainStore.saveCookieHeader(cookieHeader)
            Log.info("Cookie header saved to Keychain")
        } catch {
            Log.error("Failed to save cookie: \(error)")
        }
        startSession()
    }

    private func startSession() {
        authState = .loggedIn
        Task { await refresh() }
        startAutoRefresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let cookieHeader = cachedCookieHeader else {
            authState = .loginRequired
            return
        }

        isRefreshing = true
        isLoading = true
        errorMessage = nil

        do {
            async let summaryResult = apiClient.fetchUsageSummary(cookieHeader: cookieHeader)
            async let usageResult = apiClient.fetchUsage(cookieHeader: cookieHeader)
            async let userInfoResult = apiClient.fetchUserInfo(cookieHeader: cookieHeader)

            let userInfo = try await userInfoResult

            let summary = try? await summaryResult
            let usage = try? await usageResult

            if let summary {
                usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)
            } else if let usage {
                usageData = UsageDisplayData.from(usage: usage, userInfo: userInfo)
            } else {
                throw APIError.httpError(statusCode: 0)
            }
            Log.info("Usage data refreshed")
            networkRetryTask?.cancel()
            networkRetryTask = nil

            // Compute jump delta against previous canonical value (skip on first refresh,
            // mode change, or non-positive delta).
            if let data = usageData {
                updateJumpState(from: data)
            }

            // Weekly chart fetch (enterprise teams only). Failures are absorbed —
            // last successful weeklyData stays in place.
            if let data = usageData {
                await refreshWeeklyChart(cookieHeader: cookieHeader, data: data, userInfo: userInfo)
            }

            // Detect billing-cycle rollover so threshold alerts re-arm for the
            // new cycle. Without this, `notifiedThresholds` would only clear on
            // logout, leaving the user silent through a full new cycle.
            if let newStart = usageData?.cycleStartDate, newStart != previousCycleStart {
                if previousCycleStart != nil {
                    notificationManager.resetNotifications()
                    Log.info("Billing cycle rollover detected — threshold notifications reset")
                }
                previousCycleStart = newStart
            }

            // Check notification thresholds
            if let data = usageData {
                await notificationManager.checkAndNotify(
                    percentUsed: data.percentUsed,
                    warningThreshold: warningThreshold,
                    criticalThreshold: criticalThreshold,
                    enabled: notificationEnabled
                )
            }
        } catch APIError.unauthorized {
            Log.info("Session expired, clearing keychain")
            cachedCookieHeader = nil
            do {
                try KeychainStore.deleteCookieHeader()
            } catch {
                Log.error("Keychain delete failed: \(error.localizedDescription)")
            }
            authState = .loginRequired
            usageData = nil
            stopAutoRefresh()
        } catch APIError.forbidden {
            errorMessage = "Access denied (subscription may be inactive)"
            Log.error("API returned 403 Forbidden")
        } catch {
            if usageData == nil {
                // URLSession failures are wrapped as `APIError.networkError(URLError)`
                // by the API client, so direct cast misses offline cases. Unwrap both
                // layers before deciding whether to schedule a background retry.
                let urlError: URLError? = {
                    if let direct = error as? URLError { return direct }
                    if case APIError.networkError(let underlying) = error {
                        return underlying as? URLError
                    }
                    return nil
                }()
                if urlError?.code == .notConnectedToInternet || urlError?.code == .networkConnectionLost {
                    errorMessage = "Waiting for network..."
                    scheduleNetworkRetry()
                } else {
                    errorMessage = Self.fallbackErrorMessage(for: error)
                }
            }
            Log.error("Refresh failed: \(error.localizedDescription)")
        }

        isLoading = false
        isRefreshing = false
    }

    // MARK: - Weekly chart refresh

    private static let weeklyDateFormatter: DateFormatter = {
        let f = DateFormatter()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func refreshWeeklyChart(
        cookieHeader: String,
        data: UsageDisplayData,
        userInfo: UserInfoResponse
    ) async {
        guard data.membershipType?.lowercased() == "enterprise",
              let email = userInfo.email, !email.isEmpty
        else {
            isEnterpriseTeam = false
            weeklyData = nil
            return
        }

        if cachedTeamId == nil {
            do {
                let teams = try await apiClient.fetchTeams(cookieHeader: cookieHeader)
                cachedTeamId = teams.teams.first?.id
            } catch {
                Log.info("Teams fetch failed (treating as non-enterprise): \(error.localizedDescription)")
            }
        }

        guard let teamId = cachedTeamId else {
            isEnterpriseTeam = false
            weeklyData = nil
            return
        }

        let now = Date()
        let calendar = Calendar.current
        let endDay = Self.weeklyDateFormatter.string(from: now)
        let startDay = Self.weeklyDateFormatter.string(
            from: calendar.date(byAdding: .day, value: -6, to: now) ?? now
        )

        do {
            let response = try await apiClient.fetchWeeklyUsage(
                cookieHeader: cookieHeader,
                teamId: teamId,
                user: email,
                startDate: startDay,
                endDate: endDay
            )
            // Local calendar for "today" is a spec decision (issue #60):
            // labels stay intuitive for the user, at the cost of up to 1 day
            // of UTC→local edge slippage near midnight.
            weeklyData = response.sevenDayRolling(today: now, calendar: calendar)
            isEnterpriseTeam = true
        } catch {
            // Keep the previous cache. If we never had one, gate the chart off.
            Log.info("Weekly fetch failed: \(error.localizedDescription)")
            if weeklyData == nil {
                isEnterpriseTeam = false
            }
        }
    }

    func logout() {
        cachedCookieHeader = nil
        do {
            try KeychainStore.deleteCookieHeader()
        } catch {
            Log.error("Keychain delete failed: \(error.localizedDescription)")
        }
        authState = .loggedOut
        usageData = nil
        errorMessage = nil
        weeklyData = nil
        isEnterpriseTeam = false
        cachedTeamId = nil
        previousCycleStart = nil
        stopAutoRefresh()
        notificationManager.resetNotifications()
        Log.info("Logged out")
    }

    // MARK: - Settings Setters

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, for: .refreshInterval)
        if authState == .loggedIn {
            startAutoRefresh()
        }
    }

    func setNotificationEnabled(_ enabled: Bool) {
        notificationEnabled = enabled
        UserDefaults.standard.set(enabled, for: .notificationEnabled)
    }

    func setWarningThreshold(_ value: Int) {
        warningThreshold = value
        UserDefaults.standard.set(value, for: .warningThreshold)
    }

    func setCriticalThreshold(_ value: Int) {
        criticalThreshold = value
        UserDefaults.standard.set(value, for: .criticalThreshold)
    }

    func setMenuBarDisplayMode(_ mode: Int) {
        menuBarDisplayMode = mode
        UserDefaults.standard.set(mode, for: .menuBarDisplayMode)
    }

    func setJumpEffectEnabled(_ enabled: Bool) {
        jumpEffectEnabled = enabled
        UserDefaults.standard.set(enabled, for: .jumpEffectEnabled)
    }

    func setJumpIntensity(_ intensity: JumpIntensity) {
        jumpIntensity = intensity
        UserDefaults.standard.set(intensity.rawValue, for: .jumpIntensity)
    }

    func setWeeklyChartEnabled(_ enabled: Bool) {
        weeklyChartEnabled = enabled
        UserDefaults.standard.set(enabled, for: .weeklyChartEnabled)
    }

    func setWeeklyChartStyle(_ style: WeeklyChartStyle) {
        weeklyChartStyle = style
        UserDefaults.standard.set(style.rawValue, for: .weeklyChartStyle)
    }

    func checkForUpdate() async {
        isCheckingUpdate = true
        async let result = UpdateChecker.shared.check()
        let start = ContinuousClock.now
        availableUpdate = await result
        let elapsed = ContinuousClock.now - start
        if elapsed < .milliseconds(1200) {
            try? await Task.sleep(for: .milliseconds(1200) - elapsed)
        }
        isCheckingUpdate = false
    }

    // MARK: - Private

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(for: .refreshInterval) as? Int,
           let interval = RefreshInterval(rawValue: raw)
        {
            refreshInterval = interval
        }
        if let val = defaults.object(for: .notificationEnabled) as? Bool {
            notificationEnabled = val
        }
        if let val = defaults.object(for: .warningThreshold) as? Int {
            warningThreshold = min(val, 90)
        }
        if let val = defaults.object(for: .criticalThreshold) as? Int {
            criticalThreshold = max(min(val, 100), warningThreshold + 5)
        }
        if let val = defaults.object(for: .menuBarDisplayMode) as? Int {
            menuBarDisplayMode = val
        } else {
            // Migrate from old boolean settings
            let hadText = defaults.object(for: .legacyShowMenuBarText) as? Bool ?? false
            let hadPercent = defaults.object(for: .legacyShowMenuBarPercent) as? Bool ?? false
            if hadText && hadPercent {
                menuBarDisplayMode = 2
            } else if hadText {
                menuBarDisplayMode = 1
            }
        }
        if let val = defaults.object(for: .jumpEffectEnabled) as? Bool {
            jumpEffectEnabled = val
        }
        if let raw = defaults.object(for: .jumpIntensity) as? Int,
           let intensity = JumpIntensity(rawValue: raw)
        {
            jumpIntensity = intensity
        }
        if let val = defaults.object(for: .weeklyChartEnabled) as? Bool {
            weeklyChartEnabled = val
        }
        if let raw = defaults.object(for: .weeklyChartStyle) as? Int,
           let style = WeeklyChartStyle(rawValue: raw)
        {
            weeklyChartStyle = style
        }
    }

    /// Maps an error to a user-facing message for the fallback (non-network-down, non-auth) error path.
    /// Avoid surfacing raw `localizedDescription` to UI: it can leak request URLs or other diagnostic
    /// detail picked up by crash reporters that auto-capture user-visible state.
    nonisolated static func fallbackErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "Request timed out" : "Network error"
        }
        if error is DecodingError {
            return "Failed to read usage data"
        }
        if case APIError.httpError(let code) = error {
            return "Server error (\(code))"
        }
        if case APIError.networkError(let underlying) = error {
            if let urlError = underlying as? URLError {
                return urlError.code == .timedOut ? "Request timed out" : "Network error"
            }
            return "Network error"
        }
        return "Unexpected error"
    }

    // MARK: - Jump Detection

    /// Computes delta between this refresh and the previous canonical value, classifies
    /// tier, and updates `lastJump`. Skip conditions (no event, only previous reset):
    ///   - first refresh (no baseline)
    ///   - display mode changed (unit mismatch)
    ///   - delta ≤ 0
    private func updateJumpState(from data: UsageDisplayData) {
        let mode: JumpEvent.Mode
        let current: Double
        if data.isPercentOnly {
            mode = .percent
            current = data.serverPercentUsed ?? 0
        } else if data.isCreditBased {
            mode = .credit
            current = Double(data.planUsedCents ?? 0)
        } else {
            mode = .request
            current = Double(data.requestsUsed)
        }

        let previous: Double? = {
            switch mode {
            case .credit:  return previousPlanUsedCents.map(Double.init)
            case .request: return previousRequestsUsed.map(Double.init)
            case .percent: return previousServerPercent
            }
        }()

        let modeChanged = previousMode != nil && previousMode != mode

        // Always update the baseline for the active mode.
        switch mode {
        case .credit:  previousPlanUsedCents = data.planUsedCents ?? 0
        case .request: previousRequestsUsed = data.requestsUsed
        case .percent: previousServerPercent = data.serverPercentUsed ?? 0
        }
        previousMode = mode

        guard let prev = previous, !modeChanged else {
            // First refresh in this mode: only set baseline.
            // Guard against `@Observable` firing on `nil → nil` every refresh.
            if lastJump != nil { lastJump = nil }
            return
        }

        let delta = current - prev
        guard delta > 0 else {
            if lastJump != nil { lastJump = nil }
            return
        }

        let limit: Double
        switch mode {
        case .credit:  limit = Double(data.planLimitCents ?? 0)
        case .request: limit = Double(data.requestsLimit)
        case .percent: limit = 100  // percent-only: deltas are already %-points
        }

        let event = Self.makeJumpEvent(
            mode: mode,
            delta: delta,
            limit: limit,
            timestamp: Date()
        )
        lastJump = event
    }

    /// Builds a `JumpEvent` from raw delta/limit. Pure function — exposed for testing.
    /// Classification is the OR of percent-of-limit (5/15%) and per-mode absolute
    /// thresholds; `limit ≤ 0` falls back to absolute-only.
    nonisolated static func makeJumpEvent(
        mode: JumpEvent.Mode,
        delta: Double,
        limit: Double,
        timestamp: Date = Date()
    ) -> JumpEvent {
        let tier = classifyTier(mode: mode, delta: delta, limit: limit)
        let deltaPct: Double = limit > 0 ? (delta / limit * 100.0) : 0
        return JumpEvent(
            tier: tier,
            deltaCanonical: delta,
            deltaPct: deltaPct,
            mode: mode,
            displayDelta: formatJumpDelta(delta, mode: mode),
            timestamp: timestamp
        )
    }

    /// Per-mode absolute thresholds in canonical units. A delta meeting either the
    /// percent-of-limit or the absolute threshold is enough to escalate a tier.
    /// Rationale: a single Max-mode query is roughly +0.30 USD or +15 requests
    /// regardless of plan size, so absolute thresholds keep large-plan users from
    /// silently missing those jumps.
    private nonisolated static func absoluteThresholds(
        for mode: JumpEvent.Mode
    ) -> (t1: Double, t2: Double) {
        switch mode {
        case .credit:  return (5, 30)   // cents — $0.05 / $0.30
        case .request: return (5, 15)   // request count
        case .percent: return (5, 15)   // %-points (mirrors percent-of-limit)
        }
    }

    /// Tier classification. Tier is the OR of percent-of-limit (5/15%) and per-mode
    /// absolute thresholds. When `limit ≤ 0` only the absolute thresholds apply.
    nonisolated static func classifyTier(
        mode: JumpEvent.Mode,
        delta: Double,
        limit: Double
    ) -> JumpEvent.Tier {
        guard delta > 0 else { return .zero }

        let (t1Abs, t2Abs) = absoluteThresholds(for: mode)

        if limit > 0 {
            let pct = delta / limit * 100.0
            if pct >= 15 || delta >= t2Abs { return .two }
            if pct >= 5  || delta >= t1Abs { return .one }
            return .zero
        }

        // Fallback when plan_limit ≤ 0 (unlimited / unknown) — absolute only.
        if delta >= t2Abs { return .two }
        if delta >= t1Abs { return .one }
        return .zero
    }

    /// Formats a positive delta as a signed user-facing string for the active display mode.
    nonisolated static func formatJumpDelta(_ delta: Double, mode: JumpEvent.Mode) -> String {
        switch mode {
        case .credit:
            return String(format: "+$%.2f", delta / 100.0)
        case .request:
            return "+\(Int(delta.rounded()))"
        case .percent:
            return String(format: "+%.1f%%", delta)
        }
    }

    private var networkRetryTask: Task<Void, Never>?

    private func scheduleNetworkRetry() {
        guard networkRetryTask == nil else { return }
        networkRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            self.networkRetryTask = nil
            await self.refresh()
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while let self {
                do {
                    try await Task.sleep(for: .seconds(self.refreshInterval.rawValue))
                } catch { return }
                await self.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}
