# Settings Toolbar Tabs + Card Rows (#99) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-scroll `SettingsViewController` with an `NSTabViewController` (toolbar style, 3 tabs) whose tabs render sections as Cursor-IDE-style card rows.

**Architecture:** One `@MainActor` root tab controller eager-loads three child VCs (General / Notifications / Appearance). A shared layout-only factory (`SettingsCardFactory`) produces section headers, card chrome, and rows; each child VC owns its controls, `@objc` actions, and its own `updateUI()`. `CursorMeterApp` swaps the content VC type and drops the manual window title.

**Tech Stack:** Swift 6 (strict concurrency), pure AppKit, zero external deps, macOS 14+.

**Spec:** `docs/superpowers/specs/2026-07-20-issue-99-settings-tabs-design.md`

## Global Constraints

- Swift 6 strict concurrency: every new class is `@MainActor`.
- Zero external dependencies; AppKit + ServiceManagement only.
- Behavior preserved, ownership redistributed: every existing control action calls the same `UsageViewModel` setter it does today.
- No `animator().isHidden` anywhere (NSStackView blink; see existing comments at `SettingsViewController.swift:524,540`).
- Conditional hide/show never resizes the window; only tab switches do.
- Testing policy: no new unit tests (view construction is outside SPM test scope per project policy); `swift test` green is the regression gate for every task. Manual/AX verification happens in the final task.
- Commit format: `[#99] <type>: description`.

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/CursorMeter/SettingsCardFactory.swift` | Create | Layout-only card/row/header/root factories (no controls, no actions) |
| `Sources/CursorMeter/SettingsGeneralTabViewController.swift` | Create | Refresh + Startup + Version sections; update-check UI logic |
| `Sources/CursorMeter/SettingsNotificationsTabViewController.swift` | Create | Usage alerts, threshold slider card, app-status toggle |
| `Sources/CursorMeter/SettingsAppearanceTabViewController.swift` | Create | Menu Bar text mode, Usage Jump, Weekly Chart (enterprise-gated) |
| `Sources/CursorMeter/SettingsTabViewController.swift` | Create | Root `NSTabViewController`; tab items, eager load, `updateUI()` fan-out |
| `Sources/CursorMeter/CursorMeterApp.swift` | Modify | `openSettings()` (~line 223) + `observeSettings()` cast (~line 321) |
| `Sources/CursorMeter/SettingsViewController.swift` | Delete | Superseded (686 lines) |

Files stay flat in `Sources/CursorMeter/` (project convention — no subdirectories).

---

### Task 1: SettingsCardFactory

**Files:**
- Create: `Sources/CursorMeter/SettingsCardFactory.swift`

**Interfaces:**
- Consumes: nothing (AppKit only).
- Produces (used by Tasks 2–4):
  - `SettingsCardFactory.contentWidth: CGFloat` (420)
  - `makeSectionHeader(_ title: String) -> NSTextField`
  - `makeSection(header: String, content: NSView) -> NSView`
  - `makeCard(units: [NSView]) -> NSView`
  - `makeDividedUnit(_ row: NSView) -> NSView` — divider + row wrapper; **hide this, not the inner row**
  - `makeCardRow(title: String, caption: String? = nil, control: NSView) -> NSView`
  - `makeFullWidthCardRow(_ content: NSView) -> NSView`
  - `makeCaption(_ text: String) -> NSTextField`
  - `makeSpacer() -> NSView`
  - `makeTabRoot(sections: [NSView]) -> NSView`

- [ ] **Step 1: Write the file**

```swift
import AppKit

// MARK: - SettingsCardFactory

/// Layout-only helpers for the settings card-row visual language (#99).
/// Controls and their target/action wiring stay in the tab view controllers.
@MainActor
enum SettingsCardFactory {

    static let contentWidth: CGFloat = 420

    // MARK: Section

    /// Section header rendered outside a card (sentence case).
    static func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    /// Header + card grouped as one unit. Hiding the returned view hides the
    /// whole section (weekly-chart enterprise gating hides at this level).
    static func makeSection(header: String, content: NSView) -> NSView {
        let headerLabel = makeSectionHeader(header)
        let stack = NSStackView(views: [headerLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 4),
            content.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        return stack
    }

    // MARK: Card chrome

    /// Rounded card that stacks pre-built units vertically. Divider management
    /// is the caller's job via `makeDividedUnit` (so a hidden unit collapses
    /// together with its divider).
    static func makeCard(units: [NSView]) -> NSView {
        let stack = NSStackView(views: units)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for unit in units {
            unit.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                unit.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                unit.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        let card = CardBackgroundView()
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Row (or row group) preceded by an inset hairline divider. Conditional
    /// visibility must target the returned wrapper so the divider collapses
    /// with the row.
    static func makeDividedUnit(_ row: NSView) -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSStackView(views: [divider, row])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    // MARK: Rows

    /// Standard card row: title (+ optional caption) left, control trailing.
    static func makeCardRow(title: String, caption: String? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor

        let textStack = NSStackView(views: [titleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        if let caption {
            textStack.addArrangedSubview(makeCaption(caption))
        }

        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [textStack, makeSpacer(), control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        return row
    }

    /// Wide content (e.g. the threshold slider) spanning the card width.
    /// The explicit pins are the #75 fix carried over: after `isHidden`
    /// cycles, the content settles back at full card width, never its
    /// intrinsic minimum.
    static func makeFullWidthCardRow(_ content: NSView) -> NSView {
        let row = NSStackView(views: [content])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
        ])
        return row
    }

    static func makeCaption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.preferredMaxLayoutWidth = 260
        return label
    }

    static func makeSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: Tab root

    /// Root view for one tab: fixed content width, sections stacked with
    /// equal top/bottom padding. Bottom pin is `equalTo` so the tab's
    /// fitting size drives the per-tab window height.
    static func makeTabRoot(sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: contentWidth),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
        ])
        return root
    }
}

// MARK: - CardBackgroundView

/// Card chrome with appearance-correct dynamic colors. `updateLayer()` is
/// AppKit's hook for resolving dynamic NSColors against the effective
/// appearance — a plain `layer.backgroundColor = ...` at init would bake in
/// whichever appearance was active then.
@MainActor
final class CardBackgroundView: NSView {

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsCardFactory.swift
git commit -m "[#99] feat: card-row layout factory for settings redesign"
```

---

### Task 2: SettingsGeneralTabViewController

**Files:**
- Create: `Sources/CursorMeter/SettingsGeneralTabViewController.swift`

**Interfaces:**
- Consumes: `SettingsCardFactory` (Task 1 signatures), `UsageViewModel` setters `setRefreshInterval(_:)`, `setActivityRefreshEnabled(_:)`, `setBrowserLoginEnabled(_:)`, `checkForUpdate()`, properties `refreshInterval`, `activityRefreshEnabled`, `browserLoginEnabled`, `activeAuthSource`, `isCheckingUpdate`, `lastUpdateCheckResult`, `availableUpdate`; `RefreshInterval.allCases`, `ExternalURL.openGitHub(_:)`, `SMAppService.mainApp`.
- Produces: `SettingsGeneralTabViewController(viewModel:)`, `func updateUI()` (called by Task 5).

Behavior notes (all carried from `SettingsViewController.swift`, delete-source in Task 6):
- Checkboxes become `NSSwitch` + separate row title (card visual language; mockup A). `.state` semantics identical.
- `updateUpdatesUI()` moves verbatim (states: checking / available / failed / upToDate).
- Launch-at-login failure reverts the switch (same as today, `SettingsViewController.swift:575-588`).

- [ ] **Step 1: Write the file**

```swift
import AppKit
import ServiceManagement

// MARK: - SettingsGeneralTabViewController

/// General tab: Refresh, Startup, Version sections (#99).
@MainActor
final class SettingsGeneralTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: Controls (retained for updateUI)

    private var intervalPopUp = NSPopUpButton()
    private var activityRefreshToggle = NSSwitch()
    private var launchAtLoginToggle = NSSwitch()
    private var browserLoginToggle = NSSwitch()
    private var authSourceLabel = NSTextField(labelWithString: "")
    private var updateStatusLabel = NSTextField(labelWithString: "")
    private var updateSpinner = NSProgressIndicator()
    private var checkNowButton = NSButton()
    private var downloadButton = NSButton()

    // MARK: Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: Lifecycle

    override func loadView() {
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Refresh", content: makeRefreshCard()),
            SettingsCardFactory.makeSection(header: "Startup", content: makeStartupCard()),
            SettingsCardFactory.makeSection(header: "Version", content: makeVersionCard()),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    // MARK: Public API

    func updateUI() {
        let currentIndex = RefreshInterval.allCases.firstIndex(of: viewModel.refreshInterval) ?? 0
        intervalPopUp.selectItem(at: currentIndex)
        activityRefreshToggle.state = viewModel.activityRefreshEnabled ? .on : .off
        launchAtLoginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        browserLoginToggle.state = viewModel.browserLoginEnabled ? .on : .off

        // #54: which credential source authenticated the current session.
        authSourceLabel.stringValue = {
            switch viewModel.activeAuthSource {
            case .cursorIDE:    return "Auth: Cursor IDE"
            case .browserLogin: return "Auth: Browser login"
            case nil:           return "Auth: —"
            }
        }()

        updateUpdatesUI()
    }

    // MARK: Cards

    private func makeRefreshCard() -> NSView {
        intervalPopUp = NSPopUpButton()
        for interval in RefreshInterval.allCases {
            intervalPopUp.addItem(withTitle: interval.label)
        }
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged)

        activityRefreshToggle = NSSwitch()
        activityRefreshToggle.target = self
        activityRefreshToggle.action = #selector(activityRefreshToggleChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Interval", control: intervalPopUp),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Refresh on Cursor activity",
                caption: "Refreshes ~1 min after Cursor use; Interval is the fallback.",
                control: activityRefreshToggle
            )),
        ])
    }

    private func makeStartupCard() -> NSView {
        launchAtLoginToggle = NSSwitch()
        launchAtLoginToggle.target = self
        launchAtLoginToggle.action = #selector(launchAtLoginChanged)

        // #90: browser login is deprecated — opt-in only.
        browserLoginToggle = NSSwitch()
        browserLoginToggle.target = self
        browserLoginToggle.action = #selector(browserLoginToggleChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Launch at login", control: launchAtLoginToggle),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Enable browser login",
                caption: "Deprecated — Cursor IDE connection is the supported sign-in path.",
                control: browserLoginToggle
            )),
        ])
    }

    private func makeVersionCard() -> NSView {
        updateStatusLabel = NSTextField(labelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 13)
        updateStatusLabel.textColor = .secondaryLabelColor

        updateSpinner = NSProgressIndicator()
        updateSpinner.style = .spinning
        updateSpinner.controlSize = .small
        updateSpinner.isHidden = true
        updateSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateSpinner.widthAnchor.constraint(equalToConstant: 16),
            updateSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        checkNowButton = NSButton(title: "Check Now", target: self, action: #selector(checkNowTapped))
        checkNowButton.bezelStyle = .rounded

        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadTapped))
        downloadButton.bezelStyle = .rounded

        let statusRow = NSStackView(views: [
            updateSpinner, updateStatusLabel, SettingsCardFactory.makeSpacer(),
            checkNowButton, downloadButton,
        ])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // #54 auth source + credits.
        authSourceLabel.font = .systemFont(ofSize: 11)
        authSourceLabel.textColor = .secondaryLabelColor

        let authorLabel = NSTextField(labelWithString: "Made by WoojinAhn ·")
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .tertiaryLabelColor

        let githubLink = NSButton(title: "GitHub ↗", target: self, action: #selector(openGitHub))
        githubLink.isBordered = false
        githubLink.font = .systemFont(ofSize: 11)
        githubLink.contentTintColor = .linkColor

        let authorRow = NSStackView(views: [authorLabel, githubLink, SettingsCardFactory.makeSpacer()])
        authorRow.orientation = .horizontal
        authorRow.spacing = 2

        let aboutStack = NSStackView(views: [authSourceLabel, authorRow])
        aboutStack.orientation = .vertical
        aboutStack.alignment = .leading
        aboutStack.spacing = 3
        aboutStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        return SettingsCardFactory.makeCard(units: [
            statusRow,
            SettingsCardFactory.makeDividedUnit(aboutStack),
        ])
    }

    // MARK: Actions

    @objc private func intervalChanged() {
        let index = intervalPopUp.indexOfSelectedItem
        guard index >= 0, index < RefreshInterval.allCases.count else { return }
        viewModel.setRefreshInterval(RefreshInterval.allCases[index])
    }

    @objc private func activityRefreshToggleChanged() {
        viewModel.setActivityRefreshEnabled(activityRefreshToggle.state == .on)
    }

    @objc private func launchAtLoginChanged() {
        let enable = launchAtLoginToggle.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Launch at login failed: \(error)")
            // Revert toggle on failure
            launchAtLoginToggle.state = enable ? .off : .on
        }
    }

    @objc private func browserLoginToggleChanged() {
        viewModel.setBrowserLoginEnabled(browserLoginToggle.state == .on)
    }

    @objc private func openGitHub() {
        ExternalURL.openGitHub(URL(string: "https://github.com/WoojinAhn/CursorMeter")!)
    }

    @objc private func checkNowTapped() {
        updateSpinner.isHidden = false
        updateSpinner.startAnimation(nil)
        updateStatusLabel.stringValue = "Checking..."
        updateStatusLabel.textColor = .secondaryLabelColor
        checkNowButton.isHidden = true
        downloadButton.isHidden = true

        Task {
            await viewModel.checkForUpdate()
            updateUpdatesUI()
        }
    }

    @objc private func downloadTapped() {
        guard let update = viewModel.availableUpdate,
              let url = URL(string: update.htmlURL)
        else { return }
        ExternalURL.openGitHub(url)
    }

    // MARK: Updates UI

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func updateUpdatesUI() {
        if viewModel.isCheckingUpdate {
            updateSpinner.isHidden = false
            updateSpinner.startAnimation(nil)
            updateStatusLabel.stringValue = "v\(currentVersion) · Checking..."
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = true
            return
        }

        updateSpinner.isHidden = true
        updateSpinner.stopAnimation(nil)

        switch viewModel.lastUpdateCheckResult {
        case .available(let release):
            updateStatusLabel.stringValue = "v\(currentVersion) · v\(release.version) new"
            updateStatusLabel.textColor = .labelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = false
        case .failed(let reason):
            updateStatusLabel.stringValue = "v\(currentVersion) · Couldn't check (\(reason))"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = false
            downloadButton.isHidden = true
        case .upToDate, nil:
            updateStatusLabel.stringValue = "v\(currentVersion) · Up to date"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = false
            downloadButton.isHidden = true
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` (old `SettingsViewController` still compiles alongside — duplicate-looking logic is temporary until Task 6 deletes it)

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsGeneralTabViewController.swift
git commit -m "[#99] feat: General tab (Refresh/Startup/Version) as card rows"
```

---

### Task 3: SettingsNotificationsTabViewController

**Files:**
- Create: `Sources/CursorMeter/SettingsNotificationsTabViewController.swift`

**Interfaces:**
- Consumes: `SettingsCardFactory`, `ThresholdRangeSlider` (`onChange: ((Double, Double) -> Void)?`, `setValues(warning:critical:)`), `UsageViewModel` `notificationEnabled`, `appStatusNotificationEnabled`, `warningThreshold`, `criticalThreshold`, `setNotificationEnabled(_:)`, `setAppStatusNotificationEnabled(_:)`, `setWarningThreshold(_:)`, `setCriticalThreshold(_:)`.
- Produces: `SettingsNotificationsTabViewController(viewModel:)`, `func updateUI()`.

Behavior notes:
- The hideable unit for the threshold row is the **divided unit wrapper** (`thresholdUnit`), so the divider collapses with it. Direct `isHidden` snap, no animator.
- Long checkbox title "App status notifications (new version · connection errors)" splits into title + caption.

- [ ] **Step 1: Write the file**

```swift
import AppKit

// MARK: - SettingsNotificationsTabViewController

/// Notifications tab: usage alerts, thresholds, app status (#99).
@MainActor
final class SettingsNotificationsTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: Controls (retained for updateUI)

    private var notificationToggle = NSSwitch()
    private var appStatusToggle = NSSwitch()
    private var thresholdSlider = ThresholdRangeSlider()
    /// Divided-unit wrapper around the slider row — the conditional-hide
    /// target (divider collapses with the row).
    private var thresholdUnit = NSView()

    // MARK: Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Notifications"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: Lifecycle

    override func loadView() {
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Notifications", content: makeNotificationsCard()),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    // MARK: Public API

    func updateUI() {
        notificationToggle.state = viewModel.notificationEnabled ? .on : .off
        thresholdUnit.isHidden = !viewModel.notificationEnabled
        appStatusToggle.state = viewModel.appStatusNotificationEnabled ? .on : .off

        // Threshold range slider — setValues normalizes corrupted pairs
        // (gap + bounds), so no cross-slider juggling is needed here.
        thresholdSlider.setValues(
            warning: viewModel.warningThreshold,
            critical: viewModel.criticalThreshold
        )
    }

    // MARK: Card

    private func makeNotificationsCard() -> NSView {
        notificationToggle = NSSwitch()
        notificationToggle.target = self
        notificationToggle.action = #selector(notificationToggleChanged)

        thresholdSlider = ThresholdRangeSlider()
        thresholdSlider.onChange = { [weak self] warning, critical in
            self?.viewModel.setWarningThreshold(warning)
            self?.viewModel.setCriticalThreshold(critical)
        }

        appStatusToggle = NSSwitch()
        appStatusToggle.target = self
        appStatusToggle.action = #selector(appStatusToggleChanged)

        thresholdUnit = SettingsCardFactory.makeDividedUnit(
            SettingsCardFactory.makeFullWidthCardRow(thresholdSlider)
        )

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Enable usage alerts", control: notificationToggle),
            thresholdUnit,
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "App status notifications",
                caption: "New version · connection errors",
                control: appStatusToggle
            )),
        ])
    }

    // MARK: Actions

    @objc private func notificationToggleChanged() {
        let enabled = notificationToggle.state == .on
        viewModel.setNotificationEnabled(enabled)
        // Same NSStackView caveat as the jump-effect toggle: animator().isHidden
        // causes a layout/alpha desync that reads as a "blink". Snap instead.
        thresholdUnit.isHidden = !enabled
    }

    @objc private func appStatusToggleChanged() {
        viewModel.setAppStatusNotificationEnabled(appStatusToggle.state == .on)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsNotificationsTabViewController.swift
git commit -m "[#99] feat: Notifications tab with threshold card"
```

---

### Task 4: SettingsAppearanceTabViewController

**Files:**
- Create: `Sources/CursorMeter/SettingsAppearanceTabViewController.swift`

**Interfaces:**
- Consumes: `SettingsCardFactory`, `UsageViewModel` `menuBarDisplayMode`, `usageData?.isPercentOnly`, `jumpEffectEnabled`, `jumpIntensity`, `jumpGlyphStyle`, `isEnterpriseTeam`, `weeklyChartEnabled`, `weeklyChartStyle` + matching setters; `JumpIntensity`, `JumpGlyphStyle`, `WeeklyChartStyle` raw-value enums.
- Produces: `SettingsAppearanceTabViewController(viewModel:)`, `func updateUI()`.

Behavior notes:
- Jump sub-rows keep the **single-container collapse** (`jumpSubRowsContainer`) — per-row hiding rejected (NSStackView spacing-thrash avoidance, carried from the old ivar comment). Snap `isHidden`, no animator.
- Weekly Chart hides at the **section container** level (header + card together) when not enterprise.
- `percentOnly` forces Percent selection and disables the Ratio item (index 1).

- [ ] **Step 1: Write the file**

```swift
import AppKit

// MARK: - SettingsAppearanceTabViewController

/// Appearance tab: menu bar text, usage jump, weekly chart (#99).
@MainActor
final class SettingsAppearanceTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: Controls (retained for updateUI)

    private var menuBarDisplayPopUp = NSPopUpButton()
    private var jumpEffectToggle = NSSwitch()
    private var jumpIntensitySegmented = NSSegmentedControl()
    private var jumpGlyphStyleSegmented = NSSegmentedControl()
    /// Container that wraps both jump sub-rows (Intensity + Style) so the
    /// effect-toggle collapse targets a single view rather than two stacking
    /// peers — avoids mid-animation spacing thrash in NSStackView.
    private var jumpSubRowsContainer = NSView()
    private var weeklyChartToggle = NSSwitch()
    private var weeklyChartStyleSegmented = NSSegmentedControl()
    /// Header + card container — hidden entirely on non-enterprise accounts.
    private var weeklyChartSection = NSView()

    // MARK: Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Appearance"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: Lifecycle

    override func loadView() {
        weeklyChartSection = SettingsCardFactory.makeSection(
            header: "Weekly Chart", content: makeWeeklyChartCard())
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Menu Bar", content: makeMenuBarCard()),
            SettingsCardFactory.makeSection(header: "Usage Jump", content: makeJumpCard()),
            weeklyChartSection,
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    // MARK: Public API

    func updateUI() {
        // Menu bar display mode — percent-only plans can't show a ratio.
        let percentOnly = viewModel.usageData?.isPercentOnly == true
        if percentOnly {
            menuBarDisplayPopUp.selectItem(at: 2)
            menuBarDisplayPopUp.item(at: 1)?.isEnabled = false
        } else {
            menuBarDisplayPopUp.selectItem(at: viewModel.menuBarDisplayMode)
            menuBarDisplayPopUp.item(at: 1)?.isEnabled = true
        }

        jumpEffectToggle.state = viewModel.jumpEffectEnabled ? .on : .off
        jumpIntensitySegmented.selectedSegment = viewModel.jumpIntensity.rawValue
        jumpGlyphStyleSegmented.selectedSegment = viewModel.jumpGlyphStyle.rawValue
        jumpSubRowsContainer.isHidden = !viewModel.jumpEffectEnabled

        // Weekly chart — visible only on enterprise team accounts.
        weeklyChartSection.isHidden = !viewModel.isEnterpriseTeam
        weeklyChartToggle.state = viewModel.weeklyChartEnabled ? .on : .off
        weeklyChartStyleSegmented.selectedSegment = viewModel.weeklyChartStyle.rawValue
        weeklyChartStyleSegmented.isEnabled = viewModel.weeklyChartEnabled
    }

    // MARK: Cards

    private func makeMenuBarCard() -> NSView {
        menuBarDisplayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        menuBarDisplayPopUp.addItems(withTitles: [
            "None",
            "Ratio (e.g. 120/500)",
            "Percent (e.g. 24%)",
        ])
        menuBarDisplayPopUp.target = self
        menuBarDisplayPopUp.action = #selector(menuBarDisplayModeChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Usage text next to icon", control: menuBarDisplayPopUp),
        ])
    }

    private func makeJumpCard() -> NSView {
        jumpEffectToggle = NSSwitch()
        jumpEffectToggle.target = self
        jumpEffectToggle.action = #selector(jumpEffectToggleChanged)

        jumpIntensitySegmented = NSSegmentedControl(
            labels: ["Quiet", "Normal", "Bold"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(jumpIntensityChanged)
        )

        // Style row — segment labels are the actual emoji pairs so the result
        // is visible inline. Pair order tracks `JumpGlyphStyle` raw values.
        jumpGlyphStyleSegmented = NSSegmentedControl(
            labels: ["⚡ 🚀", "💲 💸"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(jumpGlyphStyleChanged)
        )

        let subRows = NSStackView(views: [
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Intensity", control: jumpIntensitySegmented)),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Style", control: jumpGlyphStyleSegmented)),
        ])
        subRows.orientation = .vertical
        subRows.alignment = .leading
        subRows.spacing = 0
        for unit in subRows.arrangedSubviews {
            NSLayoutConstraint.activate([
                unit.leadingAnchor.constraint(equalTo: subRows.leadingAnchor),
                unit.trailingAnchor.constraint(equalTo: subRows.trailingAnchor),
            ])
        }
        jumpSubRowsContainer = subRows

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Visual jump effect",
                caption: "Highlight sudden usage jumps in the menu bar.",
                control: jumpEffectToggle
            ),
            jumpSubRowsContainer,
        ])
    }

    private func makeWeeklyChartCard() -> NSView {
        weeklyChartToggle = NSSwitch()
        weeklyChartToggle.target = self
        weeklyChartToggle.action = #selector(weeklyChartToggleChanged)

        weeklyChartStyleSegmented = NSSegmentedControl(
            labels: ["Outline", "Dim", "Both"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(weeklyChartStyleChanged)
        )

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Show weekly chart",
                caption: "Rolling 7-day usage. Enterprise team accounts only.",
                control: weeklyChartToggle
            ),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Today", control: weeklyChartStyleSegmented)),
        ])
    }

    // MARK: Actions

    @objc private func menuBarDisplayModeChanged() {
        viewModel.setMenuBarDisplayMode(menuBarDisplayPopUp.indexOfSelectedItem)
    }

    @objc private func jumpEffectToggleChanged() {
        let enabled = jumpEffectToggle.state == .on
        viewModel.setJumpEffectEnabled(enabled)
        // animator().isHidden in an NSStackView is misleading: layout removes
        // the view immediately while alpha fades over the animation window, so
        // siblings appear to jump first and the view "blinks" away. Setting
        // isHidden directly avoids the mid-animation discontinuity.
        jumpSubRowsContainer.isHidden = !enabled
    }

    @objc private func jumpIntensityChanged() {
        let raw = jumpIntensitySegmented.selectedSegment
        guard let intensity = JumpIntensity(rawValue: raw) else { return }
        viewModel.setJumpIntensity(intensity)
    }

    @objc private func jumpGlyphStyleChanged() {
        let raw = jumpGlyphStyleSegmented.selectedSegment
        guard let style = JumpGlyphStyle(rawValue: raw) else { return }
        viewModel.setJumpGlyphStyle(style)
    }

    @objc private func weeklyChartToggleChanged() {
        let enabled = weeklyChartToggle.state == .on
        viewModel.setWeeklyChartEnabled(enabled)
        weeklyChartStyleSegmented.isEnabled = enabled
    }

    @objc private func weeklyChartStyleChanged() {
        let raw = weeklyChartStyleSegmented.selectedSegment
        guard let style = WeeklyChartStyle(rawValue: raw) else { return }
        viewModel.setWeeklyChartStyle(style)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsAppearanceTabViewController.swift
git commit -m "[#99] feat: Appearance tab (menu bar, jump, weekly chart)"
```

---

### Task 5: SettingsTabViewController (root)

**Files:**
- Create: `Sources/CursorMeter/SettingsTabViewController.swift`

**Interfaces:**
- Consumes: the three child VCs from Tasks 2–4 (`init(viewModel:)`, `updateUI()`).
- Produces: `SettingsTabViewController(viewModel:)`, `func updateUI()` — the single public entry point `CursorMeterApp` calls (Task 6).

Behavior notes:
- Eager-load children (`_ = vc.view`) so `updateUI()` fan-out and per-tab fitting sizes never hit an unloaded child (AppKit `NSViewController` has no `loadViewIfNeeded`; touching `.view` forces the load).
- `canPropagateSelectedChildViewControllerTitle = true` + child `title`s drive the window title per tab (System Settings convention).

- [ ] **Step 1: Write the file**

```swift
import AppKit

// MARK: - SettingsTabViewController

/// Root of the settings window: toolbar-style tabs (#99). AppKit owns the
/// window's toolbar and animates the frame to each tab's fitting size on
/// selection; `CursorMeterApp` must not touch `window.toolbar` or set a
/// manual window title.
@MainActor
final class SettingsTabViewController: NSTabViewController {

    private let generalVC: SettingsGeneralTabViewController
    private let notificationsVC: SettingsNotificationsTabViewController
    private let appearanceVC: SettingsAppearanceTabViewController

    init(viewModel: UsageViewModel) {
        generalVC = SettingsGeneralTabViewController(viewModel: viewModel)
        notificationsVC = SettingsNotificationsTabViewController(viewModel: viewModel)
        appearanceVC = SettingsAppearanceTabViewController(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)

        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true

        addTab(generalVC, symbol: "gearshape")
        addTab(notificationsVC, symbol: "bell.badge")
        addTab(appearanceVC, symbol: "paintbrush")

        // Eager-load all children so updateUI() fan-out and per-tab fitting
        // sizes never hit an unloaded view (spec decision; views are small
        // and #93 frees the whole graph on window close).
        for item in tabViewItems {
            _ = item.viewController?.view
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: Public API

    /// Single push-refresh entry point (#54 observation + popover parity).
    func updateUI() {
        generalVC.updateUI()
        notificationsVC.updateUI()
        appearanceVC.updateUI()
    }

    // MARK: Helpers

    private func addTab(_ viewController: NSViewController, symbol: String) {
        let item = NSTabViewItem(viewController: viewController)
        item.label = viewController.title ?? ""
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: viewController.title
        )
        addTabViewItem(item)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/CursorMeter/SettingsTabViewController.swift
git commit -m "[#99] feat: toolbar-tab root controller with updateUI fan-out"
```

---

### Task 6: Integrate into CursorMeterApp, delete old controller

**Files:**
- Modify: `Sources/CursorMeter/CursorMeterApp.swift` (`openSettings()` ~line 223, `observeSettings()` ~line 321)
- Delete: `Sources/CursorMeter/SettingsViewController.swift`

**Interfaces:**
- Consumes: `SettingsTabViewController(viewModel:)`, `.updateUI()` (Task 5).
- Produces: nothing new — same `openSettings()` / `windowWillClose` behavior (#93 teardown unchanged).

- [ ] **Step 1: Swap the content view controller in `openSettings()`**

Current code (`CursorMeterApp.swift:223-226`):

```swift
let settingsVC = SettingsViewController(viewModel: viewModel)
let window = NSWindow(contentViewController: settingsVC)
window.title = "Settings"
window.styleMask = [.titled, .closable, .miniaturizable]
```

Replace with:

```swift
let settingsVC = SettingsTabViewController(viewModel: viewModel)
let window = NSWindow(contentViewController: settingsVC)
// No manual title: the toolbar-style tab controller propagates the
// selected tab's title, and AppKit owns window.toolbar (#99).
window.styleMask = [.titled, .closable, .miniaturizable]
```

- [ ] **Step 2: Update the `observeSettings()` cast**

Current code (`CursorMeterApp.swift:321`):

```swift
(self.settingsWindow?.contentViewController as? SettingsViewController)?.updateUI()
```

Replace with:

```swift
(self.settingsWindow?.contentViewController as? SettingsTabViewController)?.updateUI()
```

- [ ] **Step 3: Delete the old controller**

```bash
git rm Sources/CursorMeter/SettingsViewController.swift
```

- [ ] **Step 4: Full build + test**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
Run: `swift test 2>&1 | tail -5` → Expected: all tests pass (`Test Suite 'All tests' passed`)

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorMeterApp.swift
git commit -m "[#99] feat: settings window hosts tab controller; retire flat pane"
```

---

### Task 7: Live verification (reinstall + AX + resize + #75 regression)

**Files:** none (manual verification; screenshots handled in the session's shipping step)

- [ ] **Step 1: Reinstall the app** (CLAUDE.md sequence)

```bash
pkill -9 -x CursorMeter
rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh
cp -r CursorMeter.app /Applications/
open /Applications/CursorMeter.app
```

- [ ] **Step 2: AX pass — element paths only, no coordinates**

For each tab (`General`, `Notifications`, `Appearance`): click the toolbar button by name via System Events, confirm expected controls exist, confirm window title equals the tab name. Do not AXPress any NSSwitch (double-fire risk); presence checks only.

- [ ] **Step 3: Verify per-tab resize + conditional states**

- Switching tabs animates the window height to fit each tab.
- Notifications tab: threshold slider spans the card width; after toggling alerts off/on via `defaults write` + relaunch (not by clicking the switch), the slider settles at full width (#75 regression gate).
- Appearance tab: weekly-chart section hidden on this machine's non-enterprise account state, jump sub-rows collapse when jump effect is off.

- [ ] **Step 4: #93 spot check**

Open settings, close the window, confirm memory returns (footprint spot check via Activity Monitor or `footprint`), no formal A/B needed.
