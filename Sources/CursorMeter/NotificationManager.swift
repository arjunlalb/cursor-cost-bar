@preconcurrency import UserNotifications

// MARK: - Threshold Evaluation

enum ThresholdLevel: Sendable, Equatable {
    case none
    case warning
    case critical
}

// MARK: - Notification Mode

enum NotificationMode: Sendable, Equatable {
    case requestQuota(used: Int, limit: Int)
    case creditPlan(usedCents: Int, limitCents: Int)
    case onDemand(usedCents: Int, limitCents: Int)
}

extension NotificationMode {
    static func formatUSD(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    func body(forPercent percent: Int) -> String {
        switch self {
        case let .requestQuota(used, limit):
            return "월 요청 한도의 \(percent)%를 초과했습니다 (\(used) / \(limit))"
        case let .creditPlan(used, limit):
            return "월 플랜의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        case let .onDemand(used, limit):
            return "On-demand 청구의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        }
    }

    var titleSuffix: String {
        switch self {
        case .requestQuota: return "Request Quota"
        case .creditPlan:   return "Plan"
        case .onDemand:     return "On-demand"
        }
    }
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager {
    private(set) var notifiedThresholds: Set<Int> = []

    nonisolated static func evaluateThreshold(
        percentUsed: Double,
        warningThreshold: Int,
        criticalThreshold: Int,
        notifiedThresholds: Set<Int>
    ) -> ThresholdLevel {
        if percentUsed >= Double(criticalThreshold)
            && !notifiedThresholds.contains(criticalThreshold)
        {
            return .critical
        }
        if percentUsed >= Double(warningThreshold)
            && !notifiedThresholds.contains(warningThreshold)
        {
            return .warning
        }
        return .none
    }

    func checkAndNotify(
        percentUsed: Double,
        warningThreshold: Int,
        criticalThreshold: Int,
        enabled: Bool,
        mode: NotificationMode
    ) async {
        guard enabled else { return }

        let level = Self.evaluateThreshold(
            percentUsed: percentUsed,
            warningThreshold: warningThreshold,
            criticalThreshold: criticalThreshold,
            notifiedThresholds: notifiedThresholds
        )

        switch level {
        case .none:
            break
        case .warning:
            await sendNotification(
                title: "Cursor \(mode.titleSuffix) Warning",
                body: mode.body(forPercent: warningThreshold)
            )
            notifiedThresholds.insert(warningThreshold)
        case .critical:
            await sendNotification(
                title: "Cursor \(mode.titleSuffix) Critical",
                body: mode.body(forPercent: criticalThreshold)
            )
            notifiedThresholds.insert(criticalThreshold)
        }
    }

    func resetNotifications() {
        notifiedThresholds.removeAll()
    }

    /// Test-only — overwrites the dedup set so oscillation/rollover tests can
    /// simulate post-notification state.
    internal func testHook_seed(_ set: Set<Int>) {
        notifiedThresholds = set
    }

    // MARK: - Usage Jump Notification

    /// Identifier prefix used for usage-jump notification requests, kept distinct
    /// from threshold notifications so callers/tests can disambiguate.
    nonisolated static let usageJumpIdentifierPrefix = "usage-jump"

    /// Formats the body string for a usage-jump notification. Pure function so the
    /// exact wording can be unit-tested without invoking UNUserNotificationCenter.
    nonisolated static func makeUsageJumpBody(displayDelta: String, currentUsage: String) -> String {
        "Used \(displayDelta) since last refresh — possible Max mode query. Now at \(currentUsage)."
    }

    /// Surfaces a system notification when a tier-2 usage jump is detected on Bold
    /// intensity. Callers (the JumpEffectCoordinator) are responsible for gating
    /// on intensity == .bold && tier == .two; this method is intensity-agnostic.
    ///
    /// On the first call with `.notDetermined` status (user has never seen a
    /// threshold notification yet), we prompt for authorization here so that
    /// opting into Bold intensity actually surfaces something. If denied or
    /// already-denied, this is a silent no-op.
    func notifyUsageJump(displayDelta: String, currentUsage: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    Log.info("Usage jump notification skipped: user denied authorization")
                    return
                }
            } catch {
                Log.error("Usage jump notification authorization failed: \(error)")
                return
            }
        default:
            Log.info("Usage jump notification skipped: not authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Usage jumped"
        content.body = Self.makeUsageJumpBody(
            displayDelta: displayDelta,
            currentUsage: currentUsage
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.usageJumpIdentifierPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Log.info("Usage jump notification sent")
        } catch {
            Log.error("Usage jump notification failed: \(error)")
        }
    }

    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try await center.add(request)
            Log.info("Notification sent: \(title)")
        } catch {
            Log.error("Notification failed: \(error)")
        }
    }
}
