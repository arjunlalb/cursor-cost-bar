import UserNotifications

// MARK: - Threshold Evaluation

enum ThresholdLevel: Sendable, Equatable {
    case none
    case warning
    case critical
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
        enabled: Bool
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
                title: "Cursor Usage Warning",
                body: "Usage has reached \(Int(percentUsed))% of your limit."
            )
            notifiedThresholds.insert(warningThreshold)
        case .critical:
            await sendNotification(
                title: "Cursor Usage Critical",
                body: "Usage has reached \(Int(percentUsed))% of your limit."
            )
            notifiedThresholds.insert(criticalThreshold)
        }
    }

    func resetNotifications() {
        notifiedThresholds.removeAll()
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
    /// Authorization is *not* requested here — the threshold notification flow
    /// already prompts the user. If authorization has been denied or not yet
    /// determined, this is a silent no-op.
    func notifyUsageJump(displayDelta: String, currentUsage: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else {
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
