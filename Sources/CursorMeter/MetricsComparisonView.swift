import AppKit

/// Daily summary (today UTC + week PT) or weekly per-day breakdown (Mon PT → today).
@MainActor
final class MetricsComparisonView: NSView {

    private enum Palette {
        static let cardFill = NSColor.labelColor.withAlphaComponent(0.045)
        static let cardBorder = NSColor.separatorColor.withAlphaComponent(0.55)
        static let header = NSColor.secondaryLabelColor
        static let metricName = NSColor.labelColor
        static let total = NSColor.labelColor
        static let included = CircularProgressIcon.accentColor
        static let onDemand = CircularProgressIcon.warnColor
        static let muted = NSColor.tertiaryLabelColor
        static let todayHighlight = CircularProgressIcon.accentColor.withAlphaComponent(0.12)
        static let todayBorder = CircularProgressIcon.accentColor.withAlphaComponent(0.35)

        static func valueColor(for metric: MenuBarMetric, amount: Double) -> NSColor {
            switch metric {
            case .totalUsage:
                return total
            case .included:
                return amount > 0 ? included : muted
            case .onDemand:
                return amount > 0 ? onDemand : muted
            }
        }

        static func valueWeight(for metric: MenuBarMetric, amount: Double) -> NSFont.Weight {
            switch metric {
            case .totalUsage:
                return .semibold
            case .included:
                return amount > 0 ? .medium : .regular
            case .onDemand:
                return amount > 0 ? .semibold : .regular
            }
        }
    }

    private struct MetricRow {
        let metric: MenuBarMetric
        let container: NSView
        let name: NSTextField
        let today: NSTextField
        let week: NSTextField
    }

    private struct DayRow {
        let name: NSTextField
        let total: NSTextField
        let included: NSTextField
        let onDemand: NSTextField
        let container: NSView
    }

    private let cardView = NSView()
    private let dailyTodayHeader = NSTextField(labelWithString: "Today UTC")
    private let dailyPanel = NSStackView()
    private let weeklyPanel = NSStackView()
    private let weeklyDaysStack = NSStackView()
    private var metricRows: [MetricRow] = []
    private var dayRows: [DayRow] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(
        totals: DashboardUsageTotals?,
        view: UsagePopoverView,
        dayTimezone: UsageDayTimezone
    ) {
        dailyPanel.isHidden = view != .daily
        weeklyPanel.isHidden = view != .weekly
        dailyTodayHeader.stringValue = dayTimezone.todayHeader

        if let totals {
            let today = totals.today(for: dayTimezone)
            for row in metricRows {
                row.today.stringValue = row.metric.formatValue(today)
                row.week.stringValue = row.metric.formatValue(totals.week)
                styleValueField(row.today, metric: row.metric, period: today)
                styleValueField(row.week, metric: row.metric, period: totals.week)
                row.name.font = NSFont.systemFont(
                    ofSize: 12,
                    weight: row.metric == .totalUsage ? .semibold : .medium
                )
            }
            for (index, day) in totals.weekDays.enumerated() where index < dayRows.count {
                let row = dayRows[index]
                row.name.stringValue = day.label + (day.isToday ? " · today" : "")
                row.total.stringValue = MenuBarMetric.totalUsage.formatValue(day.totals)
                row.included.stringValue = MenuBarMetric.included.formatValue(day.totals)
                row.onDemand.stringValue = MenuBarMetric.onDemand.formatValue(day.totals)
                styleWeeklyValue(row.total, metric: .totalUsage, period: day.totals)
                styleWeeklyValue(row.included, metric: .included, period: day.totals)
                styleWeeklyValue(row.onDemand, metric: .onDemand, period: day.totals)
                styleDayRow(row, isToday: day.isToday)
            }
            for index in totals.weekDays.count..<dayRows.count {
                let row = dayRows[index]
                row.name.stringValue = "—"
                row.total.stringValue = "—"
                row.included.stringValue = "—"
                row.onDemand.stringValue = "—"
                styleDayRow(row, isToday: false)
            }
        } else {
            for row in metricRows {
                row.today.stringValue = "—"
                row.week.stringValue = "—"
                row.today.textColor = Palette.muted
                row.week.textColor = Palette.muted
            }
            for row in dayRows {
                row.name.stringValue = "—"
                row.total.stringValue = "—"
                row.included.stringValue = "—"
                row.onDemand.stringValue = "—"
                styleDayRow(row, isToday: false)
            }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        configureCard()
        addSubview(cardView)
        NSLayoutConstraint.activate([
            cardView.topAnchor.constraint(equalTo: topAnchor),
            cardView.bottomAnchor.constraint(equalTo: bottomAnchor),
            cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
            root.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -12),
            root.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            root.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
        ])

        buildDailyPanel()
        buildWeeklyPanel()
        root.addArrangedSubview(dailyPanel)
        root.addArrangedSubview(weeklyPanel)
        dailyPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        weeklyPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func configureCard() {
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = Palette.cardBorder.cgColor
        cardView.layer?.backgroundColor = Palette.cardFill.cgColor
    }

    private func buildDailyPanel() {
        dailyPanel.orientation = .vertical
        dailyPanel.alignment = .leading
        dailyPanel.spacing = 6
        dailyPanel.translatesAutoresizingMaskIntoConstraints = false

        dailyPanel.addArrangedSubview(makeDailyHeaderRow())
        dailyPanel.addArrangedSubview(makeDivider())

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 4
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        dailyPanel.addArrangedSubview(rowsStack)

        for metric in MenuBarMetric.allCases {
            let row = makeMetricRow(metric: metric)
            metricRows.append(row)
            rowsStack.addArrangedSubview(row.container)
            row.container.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsStack.widthAnchor.constraint(equalTo: dailyPanel.widthAnchor).isActive = true
    }

    private func buildWeeklyPanel() {
        weeklyPanel.orientation = .vertical
        weeklyPanel.alignment = .leading
        weeklyPanel.spacing = 6
        weeklyPanel.translatesAutoresizingMaskIntoConstraints = false
        weeklyPanel.isHidden = true

        weeklyPanel.addArrangedSubview(makeWeeklyHeaderRow())
        weeklyPanel.addArrangedSubview(makeDivider())

        weeklyDaysStack.orientation = .vertical
        weeklyDaysStack.alignment = .leading
        weeklyDaysStack.spacing = 4
        weeklyDaysStack.translatesAutoresizingMaskIntoConstraints = false
        weeklyPanel.addArrangedSubview(weeklyDaysStack)

        for _ in 0..<7 {
            let row = makeDayRow()
            dayRows.append(row)
            weeklyDaysStack.addArrangedSubview(row.container)
            row.container.widthAnchor.constraint(equalTo: weeklyDaysStack.widthAnchor).isActive = true
        }
        weeklyDaysStack.widthAnchor.constraint(equalTo: weeklyPanel.widthAnchor).isActive = true
    }

    private func makeDailyHeaderRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(makeLabel("", size: 11, weight: .semibold, color: Palette.header))
        row.addArrangedSubview(makeFlexibleSpacer())
        dailyTodayHeader.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        dailyTodayHeader.textColor = Palette.header
        dailyTodayHeader.alignment = .right
        dailyTodayHeader.widthAnchor.constraint(equalToConstant: 78).isActive = true
        row.addArrangedSubview(dailyTodayHeader)
        row.addArrangedSubview(
            makeLabel("Since Mon PT", size: 11, weight: .semibold, color: Palette.header, align: .right, width: 78)
        )
        return row
    }

    private func makeWeeklyHeaderRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.addArrangedSubview(makeLabel("Day (PT)", size: 11, weight: .semibold, color: Palette.header))
        row.addArrangedSubview(makeFlexibleSpacer())
        row.addArrangedSubview(makeLabel("Total", size: 11, weight: .semibold, color: Palette.header, align: .right, width: 58))
        row.addArrangedSubview(makeLabel("Incl.", size: 11, weight: .semibold, color: Palette.included.withAlphaComponent(0.85), align: .right, width: 58))
        row.addArrangedSubview(makeLabel("On-dem.", size: 11, weight: .semibold, color: Palette.onDemand.withAlphaComponent(0.85), align: .right, width: 58))
        return row
    }

    private func makeMetricRow(metric: MenuBarMetric) -> MetricRow {
        let name = makeLabel(
            metric.label,
            size: 12,
            weight: metric == .totalUsage ? .semibold : .medium,
            color: Palette.metricName
        )
        let today = makeValueLabel("—", width: 78)
        let week = makeValueLabel("—", width: 78)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(makeFlexibleSpacer())
        stack.addArrangedSubview(today)
        stack.addArrangedSubview(week)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        if metric == .totalUsage {
            container.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return MetricRow(metric: metric, container: container, name: name, today: today, week: week)
    }

    private func makeDayRow() -> DayRow {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let name = makeLabel("—", size: 12, weight: .regular, color: Palette.header)
        let total = makeValueLabel("—", width: 58)
        let included = makeValueLabel("—", width: 58)
        let onDemand = makeValueLabel("—", width: 58)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(makeFlexibleSpacer())
        stack.addArrangedSubview(total)
        stack.addArrangedSubview(included)
        stack.addArrangedSubview(onDemand)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 7
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        return DayRow(name: name, total: total, included: included, onDemand: onDemand, container: container)
    }

    private func styleValueField(
        _ field: NSTextField,
        metric: MenuBarMetric,
        period: DashboardPeriodTotals
    ) {
        let amount = metric.value(for: period)
        field.textColor = Palette.valueColor(for: metric, amount: amount)
        field.font = NSFont.monospacedDigitSystemFont(
            ofSize: 13,
            weight: Palette.valueWeight(for: metric, amount: amount)
        )
    }

    private func styleWeeklyValue(
        _ field: NSTextField,
        metric: MenuBarMetric,
        period: DashboardPeriodTotals
    ) {
        styleValueField(field, metric: metric, period: period)
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: Palette.valueWeight(for: metric, amount: metric.value(for: period)))
    }

    private func styleDayRow(_ row: DayRow, isToday: Bool) {
        row.container.layer?.backgroundColor = isToday
            ? Palette.todayHighlight.cgColor
            : nil
        row.container.layer?.borderWidth = isToday ? 1 : 0
        row.container.layer?.borderColor = isToday ? Palette.todayBorder.cgColor : nil
        row.name.font = NSFont.systemFont(ofSize: 12, weight: isToday ? .semibold : .regular)
        row.name.textColor = isToday ? Palette.metricName : Palette.header
    }

    private func makeValueLabel(_ text: String, width: CGFloat) -> NSTextField {
        makeLabel(text, size: 13, weight: .semibold, color: Palette.total, align: .right, width: width)
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        align: NSTextAlignment = .left,
        width: CGFloat? = nil
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = align
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(
            .init(NSLayoutConstraint.Priority.defaultLow.rawValue),
            for: .horizontal
        )
        if let width {
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return field
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func makeDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }
}
