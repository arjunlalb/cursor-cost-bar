import Foundation
import Observation

enum AuthState {
    case loggedOut
    case loggedIn
    case loginRequired
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
                let urlError = error as? URLError
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
        stopAutoRefresh()
        notificationManager.resetNotifications()
        Log.info("Logged out")
    }

    // MARK: - Settings Setters

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "refreshIntervalSeconds")
        if authState == .loggedIn {
            startAutoRefresh()
        }
    }

    func setNotificationEnabled(_ enabled: Bool) {
        notificationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notificationEnabled")
    }

    func setWarningThreshold(_ value: Int) {
        warningThreshold = value
        UserDefaults.standard.set(value, forKey: "warningThreshold")
    }

    func setCriticalThreshold(_ value: Int) {
        criticalThreshold = value
        UserDefaults.standard.set(value, forKey: "criticalThreshold")
    }

    func setMenuBarDisplayMode(_ mode: Int) {
        menuBarDisplayMode = mode
        UserDefaults.standard.set(mode, forKey: "menuBarDisplayMode")
    }

    func setJumpEffectEnabled(_ enabled: Bool) {
        jumpEffectEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "jumpEffectEnabled")
    }

    func setJumpIntensity(_ intensity: JumpIntensity) {
        jumpIntensity = intensity
        UserDefaults.standard.set(intensity.rawValue, forKey: "jumpIntensity")
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
        if let raw = defaults.object(forKey: "refreshIntervalSeconds") as? Int,
           let interval = RefreshInterval(rawValue: raw)
        {
            refreshInterval = interval
        }
        if let val = defaults.object(forKey: "notificationEnabled") as? Bool {
            notificationEnabled = val
        }
        if let val = defaults.object(forKey: "warningThreshold") as? Int {
            warningThreshold = min(val, 90)
        }
        if let val = defaults.object(forKey: "criticalThreshold") as? Int {
            criticalThreshold = max(min(val, 100), warningThreshold + 5)
        }
        if let val = defaults.object(forKey: "menuBarDisplayMode") as? Int {
            menuBarDisplayMode = val
        } else {
            // Migrate from old boolean settings
            let hadText = defaults.object(forKey: "showMenuBarText") as? Bool ?? false
            let hadPercent = defaults.object(forKey: "showMenuBarPercent") as? Bool ?? false
            if hadText && hadPercent {
                menuBarDisplayMode = 2
            } else if hadText {
                menuBarDisplayMode = 1
            }
        }
        if let val = defaults.object(forKey: "jumpEffectEnabled") as? Bool {
            jumpEffectEnabled = val
        }
        if let raw = defaults.object(forKey: "jumpIntensity") as? Int,
           let intensity = JumpIntensity(rawValue: raw)
        {
            jumpIntensity = intensity
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
            lastJump = nil
            return
        }

        let delta = current - prev
        guard delta > 0 else {
            lastJump = nil
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
    /// `limit ≤ 0` triggers fixed-threshold fallback (5/15 cents, 1/5 requests, 5/15 %p).
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

    /// Tier classification. Uses % of plan limit when limit > 0; otherwise falls back
    /// to fixed canonical thresholds per mode.
    nonisolated static func classifyTier(
        mode: JumpEvent.Mode,
        delta: Double,
        limit: Double
    ) -> JumpEvent.Tier {
        guard delta > 0 else { return .zero }

        if limit > 0 {
            let pct = delta / limit * 100.0
            if pct >= 15 { return .two }
            if pct >= 5 { return .one }
            return .zero
        }

        // Fallback when plan_limit ≤ 0 (unlimited / unknown).
        switch mode {
        case .credit:
            if delta >= 15 { return .two }
            if delta >= 5 { return .one }
            return .zero
        case .request:
            if delta >= 5 { return .two }
            if delta >= 1 { return .one }
            return .zero
        case .percent:
            // Percent mode has an implicit limit of 100, but keep this branch for safety.
            if delta >= 15 { return .two }
            if delta >= 5 { return .one }
            return .zero
        }
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
