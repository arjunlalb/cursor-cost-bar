import AppKit

/// Daily summary (today UTC + week PT) or weekly per-day breakdown (Mon PT → today).
@MainActor
final class MetricsComparisonView: NSView {

    private struct MetricRow {
        let metric: MenuBarMetric
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
            }
            for (index, day) in totals.weekDays.enumerated() where index < dayRows.count {
                let row = dayRows[index]
                row.name.stringValue = day.label + (day.isToday ? " ·" : "")
                row.total.stringValue = MenuBarMetric.totalUsage.formatValue(day.totals)
                row.included.stringValue = MenuBarMetric.included.formatValue(day.totals)
                row.onDemand.stringValue = MenuBarMetric.onDemand.formatValue(day.totals)
                row.name.font = NSFont.systemFont(ofSize: 11, weight: day.isToday ? .semibold : .regular)
                row.name.textColor = day.isToday ? NSColor.labelColor : NSColor.secondaryLabelColor
            }
            for index in totals.weekDays.count..<dayRows.count {
                let row = dayRows[index]
                row.name.stringValue = "—"
                row.total.stringValue = "—"
                row.included.stringValue = "—"
                row.onDemand.stringValue = "—"
            }
        } else {
            for row in metricRows {
                row.today.stringValue = "—"
                row.week.stringValue = "—"
            }
            for row in dayRows {
                row.name.stringValue = "—"
                row.total.stringValue = "—"
                row.included.stringValue = "—"
                row.onDemand.stringValue = "—"
            }
        }
    }

    // MARK: - Layout

    private func buildLayout() {
        translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        buildDailyPanel()
        buildWeeklyPanel()
        root.addArrangedSubview(dailyPanel)
        root.addArrangedSubview(weeklyPanel)
        dailyPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        weeklyPanel.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
    }

    private func buildDailyPanel() {
        dailyPanel.orientation = .vertical
        dailyPanel.alignment = .leading
        dailyPanel.spacing = 4
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
            rowsStack.addArrangedSubview(metricRowContainer(row))
        }
        rowsStack.widthAnchor.constraint(equalTo: dailyPanel.widthAnchor).isActive = true
    }

    private func buildWeeklyPanel() {
        weeklyPanel.orientation = .vertical
        weeklyPanel.alignment = .leading
        weeklyPanel.spacing = 4
        weeklyPanel.translatesAutoresizingMaskIntoConstraints = false
        weeklyPanel.isHidden = true

        weeklyPanel.addArrangedSubview(makeWeeklyHeaderRow())
        weeklyPanel.addArrangedSubview(makeDivider())

        weeklyDaysStack.orientation = .vertical
        weeklyDaysStack.alignment = .leading
        weeklyDaysStack.spacing = 3
        weeklyDaysStack.translatesAutoresizingMaskIntoConstraints = false
        weeklyPanel.addArrangedSubview(weeklyDaysStack)

        for _ in 0..<7 {
            let row = makeDayRow()
            dayRows.append(row)
            weeklyDaysStack.addArrangedSubview(row.container)
        }
        weeklyDaysStack.widthAnchor.constraint(equalTo: weeklyPanel.widthAnchor).isActive = true
    }

    private func makeDailyHeaderRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.addArrangedSubview(makeLabel("", size: 10, weight: .semibold, color: .secondaryLabelColor))
        row.addArrangedSubview(makeFlexibleSpacer())
        dailyTodayHeader.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        dailyTodayHeader.textColor = NSColor.secondaryLabelColor
        dailyTodayHeader.alignment = .right
        dailyTodayHeader.widthAnchor.constraint(equalToConstant: 68).isActive = true
        row.addArrangedSubview(dailyTodayHeader)
        row.addArrangedSubview(makeLabel("Since Mon PT", size: 10, weight: .semibold, color: .secondaryLabelColor, align: .right, width: 68))
        return row
    }

    private func makeWeeklyHeaderRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.addArrangedSubview(makeLabel("Day (PT)", size: 10, weight: .semibold, color: .secondaryLabelColor))
        row.addArrangedSubview(makeFlexibleSpacer())
        row.addArrangedSubview(makeLabel("Total", size: 10, weight: .semibold, color: .secondaryLabelColor, align: .right, width: 52))
        row.addArrangedSubview(makeLabel("Incl.", size: 10, weight: .semibold, color: .secondaryLabelColor, align: .right, width: 52))
        row.addArrangedSubview(makeLabel("On-dem.", size: 10, weight: .semibold, color: .secondaryLabelColor, align: .right, width: 52))
        return row
    }

    private func metricRowContainer(_ row: MetricRow) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.addArrangedSubview(row.name)
        stack.addArrangedSubview(makeFlexibleSpacer())
        stack.addArrangedSubview(row.today)
        stack.addArrangedSubview(row.week)
        return stack
    }

    private func makeMetricRow(metric: MenuBarMetric) -> MetricRow {
        MetricRow(
            metric: metric,
            name: makeLabel(metric.label, size: 11, weight: .regular, color: .labelColor),
            today: makeValueLabel("—", width: 68),
            week: makeValueLabel("—", width: 68)
        )
    }

    private func makeDayRow() -> DayRow {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let name = makeLabel("—", size: 11, weight: .regular, color: .secondaryLabelColor)
        name.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let total = makeValueLabel("—", width: 52)
        let included = makeValueLabel("—", width: 52)
        let onDemand = makeValueLabel("—", width: 52)
        stack.addArrangedSubview(name)
        stack.addArrangedSubview(makeFlexibleSpacer())
        stack.addArrangedSubview(total)
        stack.addArrangedSubview(included)
        stack.addArrangedSubview(onDemand)
        return DayRow(name: name, total: total, included: included, onDemand: onDemand, container: stack)
    }

    private func makeValueLabel(_ text: String, width: CGFloat) -> NSTextField {
        makeLabel(text, size: 11, weight: .regular, color: .secondaryLabelColor, align: .right, width: width)
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
        field.font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
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
