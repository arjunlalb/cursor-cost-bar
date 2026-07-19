# Cursor Activity Watcher (#92) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh usage shortly after real Cursor IDE activity by watching Cursor's conversation-search WAL file, debounced and rate-capped, with the existing 5-min poll as fallback.

**Architecture:** A new `@MainActor` `CursorActivityWatcher` (DispatchSource on the WAL file, parent-directory fallback when the WAL is absent) emits `onActivity` → `UsageViewModel.noteActivity()` debounces 20 s and defers past a shared 60 s min-interval guard → existing `refresh()`. One settings toggle, default ON. Spec: `docs/superpowers/specs/2026-07-19-issue-92-cursor-activity-watcher-design.md`.

**Tech Stack:** Swift 6 strict concurrency, pure AppKit, macOS SDK only (zero external dependencies), XCTest via `swift test`.

## Global Constraints

- Swift 6 strict concurrency: `@MainActor` / `Sendable`; CI (Xcode 16.4) is stricter than local — constants referenced from `nonisolated` test contexts must be `nonisolated static let`; avoid `setUp`/`tearDown` state (create temp dirs inside each test).
- Zero external dependencies — macOS SDK only.
- Tests must never touch the real Keychain, `UNUserNotificationCenter.current()`, or the real Cursor path — use `UsageViewModel` seams (`init(apiClient:)` + `MockURLProtocol`, `keychainDeleteHandler`, `sessionExpiredNotifier`, `testHook_setCookieHeader`) and temp dirs.
- Timing tests: inject shortened durations (tens of ms) via `@ObservationIgnored internal var` seams; assert on refresh **counts** after convergence (pattern: `IDESignInGuidanceTests.swift:71-72`). No wall-clock assertions.
- **Never write to the real Cursor WAL** (`~/Library/Application Support/Cursor/...`) — appending to a live SQLite WAL can corrupt Cursor's DB. All FS tests use temp dirs.
- Commit format: `[#92] <type>: description`. After each push: `gh run list --limit 1`.
- New observable state read by UI/app must be added to a `withObservationTracking` block in `CursorMeterApp` (one-shot; re-arm after onChange), or it silently never updates.

---

### Task 1: `CursorActivityWatcher` — file watching core

**Files:**
- Create: `Sources/CursorMeter/CursorActivityWatcher.swift`
- Test: `Tests/CursorMeterTests/CursorActivityWatcherTests.swift`

**Interfaces:**
- Consumes: `Log.info` (existing logging), Dispatch/Foundation only.
- Produces: `@MainActor final class CursorActivityWatcher` with
  `init(filePath: String = CursorActivityWatcher.defaultWALPath, onActivity: @escaping @MainActor () -> Void)`,
  `func start()`, `func stop()`, `private(set) var isWatching: Bool`.
  Task 2 extends this same class; Task 4 constructs it in `CursorMeterApp`.

- [ ] **Step 1: Write the failing tests** (write-event delivery, stop, dir-absent no-op)

```swift
// Tests/CursorMeterTests/CursorActivityWatcherTests.swift
import XCTest
@testable import CursorMeter

@MainActor
final class CursorActivityWatcherTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func append(_ text: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try handle.close()
    }

    private func waitUntil(_ timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    func testWriteEventFiresOnActivity() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")
        try Data("x".utf8).write(to: file)

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()
        XCTAssertTrue(watcher.isWatching)

        try append("y", to: file)
        await waitUntil { fired >= 1 }
        XCTAssertGreaterThanOrEqual(fired, 1)
        watcher.stop()
    }

    func testStopDeliversNoFurtherEvents() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")
        try Data("x".utf8).write(to: file)

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)

        try append("y", to: file)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fired, 0)
    }

    func testMissingParentDirectoryIsInertNoOp() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString)")
            .appendingPathComponent("wal")

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: missing.path) { fired += 1 }
        watcher.start()   // must not crash
        XCTAssertFalse(watcher.isWatching)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fired, 0)
        watcher.stop()    // idempotent, must not crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CursorActivityWatcherTests 2>&1 | tail -5`
Expected: FAIL to build — `cannot find 'CursorActivityWatcher' in scope`

- [ ] **Step 3: Implement the watcher core**

```swift
// Sources/CursorMeter/CursorActivityWatcher.swift
import Foundation

/// Watches Cursor's conversation-search WAL file for write activity and
/// reports it via `onActivity`. Pure trigger: holds an O_EVTONLY fd and
/// never reads file contents, so cost is independent of file size.
///
/// The WAL is absent whenever SQLite last closed cleanly — a normal state,
/// not an error. Task 2 adds the parent-directory fallback for that case;
/// only a missing parent directory (Cursor not installed) leaves the
/// watcher permanently inert.
@MainActor
final class CursorActivityWatcher {
    nonisolated static let defaultWALPath =
        ("~/Library/Application Support/Cursor/User/globalStorage/conversation-search.db-wal"
            as NSString).expandingTildeInPath

    private let filePath: String
    private let directoryPath: String
    private let onActivity: @MainActor () -> Void
    private var fileSource: (any DispatchSourceFileSystemObject)?
    private(set) var isWatching = false

    init(
        filePath: String = CursorActivityWatcher.defaultWALPath,
        onActivity: @escaping @MainActor () -> Void
    ) {
        self.filePath = filePath
        self.directoryPath = (filePath as NSString).deletingLastPathComponent
        self.onActivity = onActivity
    }

    func start() {
        guard !isWatching else { return }
        isWatching = attachToFile()
        if !isWatching {
            Log.info("CursorActivityWatcher inactive: watch target unavailable")
        }
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        isWatching = false
    }

    @discardableResult
    private func attachToFile() -> Bool {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Handlers run on the main queue; hop into MainActor explicitly
            // to keep Swift 6 strict concurrency clean.
            MainActor.assumeIsolated {
                self?.handleFileEvent()
            }
        }
        source.setCancelHandler { close(fd) }
        fileSource = source
        source.resume()
        return true
    }

    private func handleFileEvent() {
        guard let source = fileSource else { return }
        let events = source.data
        if events.contains(.delete) || events.contains(.rename) {
            // SQLite checkpoint replaced the WAL; the old fd is dead.
            fileSource?.cancel()
            fileSource = nil
            isWatching = attachToFile()
            // Task 2 replaces this branch with the directory fallback.
        } else {
            onActivity()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CursorActivityWatcherTests 2>&1 | tail -5`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorActivityWatcher.swift Tests/CursorMeterTests/CursorActivityWatcherTests.swift
git commit -m "[#92] feat: CursorActivityWatcher file-watch core"
```

---

### Task 2: Watcher WAL lifecycle — delete/recreate and directory fallback

**Files:**
- Modify: `Sources/CursorMeter/CursorActivityWatcher.swift` (extend Task 1 class)
- Test: `Tests/CursorMeterTests/CursorActivityWatcherTests.swift` (append tests)

**Interfaces:**
- Consumes: Task 1's `CursorActivityWatcher` internals.
- Produces: same public surface; new behavior — `start()` with WAL absent but parent dir present attaches to the directory and hands off to the file when it appears (firing one `onActivity`); `.delete`/`.rename` falls back to the directory when immediate re-open fails.

- [ ] **Step 1: Write the failing tests**

```swift
// Append to CursorActivityWatcherTests.swift

    func testDeleteRecreateKeepsDelivering() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")
        try Data("x".utf8).write(to: file)

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()

        try FileManager.default.removeItem(at: file)
        try? await Task.sleep(for: .milliseconds(100))
        try Data("z".utf8).write(to: file)          // recreate = activity
        await waitUntil { fired >= 1 }
        let afterRecreate = fired

        try append("w", to: file)                    // events on the NEW file
        await waitUntil { fired > afterRecreate }
        XCTAssertGreaterThan(fired, afterRecreate)
        watcher.stop()
    }

    func testAbsentFileAttachesWhenItAppears() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("wal")   // does not exist yet

        var fired = 0
        let watcher = CursorActivityWatcher(filePath: file.path) { fired += 1 }
        watcher.start()
        XCTAssertTrue(watcher.isWatching)   // dir fallback counts as watching

        try Data("x".utf8).write(to: file)
        await waitUntil { fired >= 1 }      // appearance itself is activity
        XCTAssertGreaterThanOrEqual(fired, 1)

        let beforeAppend = fired
        try append("y", to: file)           // now attached to the file itself
        await waitUntil { fired > beforeAppend }
        XCTAssertGreaterThan(fired, beforeAppend)
        watcher.stop()
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CursorActivityWatcherTests 2>&1 | tail -5`
Expected: `testAbsentFileAttachesWhenItAppears` FAILS (`isWatching` false); `testDeleteRecreateKeepsDelivering` may flake-fail on the recreate race — both must pass after Step 3.

- [ ] **Step 3: Implement the directory fallback**

Replace `start()`, `handleFileEvent()`'s delete branch, and `stop()`; add `attachToDirectory()`:

```swift
    private var directorySource: (any DispatchSourceFileSystemObject)?

    func start() {
        guard !isWatching else { return }
        isWatching = attachToFile() || attachToDirectory()
        if !isWatching {
            Log.info("CursorActivityWatcher inactive: watch target unavailable")
        }
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        directorySource?.cancel()
        directorySource = nil
        isWatching = false
    }

    private func handleFileEvent() {
        guard let source = fileSource else { return }
        let events = source.data
        if events.contains(.delete) || events.contains(.rename) {
            // SQLite checkpoint removed/replaced the WAL; the old fd is dead.
            fileSource?.cancel()
            fileSource = nil
            if !attachToFile() {
                isWatching = attachToDirectory()
            }
        } else {
            onActivity()
        }
    }

    @discardableResult
    private func attachToDirectory() -> Bool {
        guard directorySource == nil else { return true }
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleDirectoryEvent()
            }
        }
        source.setCancelHandler { close(fd) }
        directorySource = source
        source.resume()
        return true
    }

    private func handleDirectoryEvent() {
        guard FileManager.default.fileExists(atPath: filePath), attachToFile() else { return }
        directorySource?.cancel()
        directorySource = nil
        onActivity()   // the WAL appearing IS activity
    }
```

- [ ] **Step 4: Run the watcher suite 3× to shake out flakes**

Run: `for i in 1 2 3; do swift test --filter CursorActivityWatcherTests 2>&1 | tail -2; done`
Expected: `Executed 5 tests, with 0 failures` ×3

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/CursorActivityWatcher.swift Tests/CursorMeterTests/CursorActivityWatcherTests.swift
git commit -m "[#92] feat: watcher WAL-lifecycle handling with directory fallback"
```

---

### Task 3: `UsageViewModel` — debounce, shared defer guard, settings state

**Files:**
- Modify: `Sources/CursorMeter/UsageViewModel.swift`
  - `SettingsKey` enum (~line 19): add case
  - state block near `watchTickInterval` (~line 272): new vars
  - `refresh()` (~line 485): stamp `lastRefreshAttempt`
  - setters block (~line 1057): `setActivityRefreshEnabled`
  - `loadSettings` (~line 1149): read persisted value
- Test: `Tests/CursorMeterTests/ActivityRefreshTests.swift` (create)

**Interfaces:**
- Consumes: existing `refresh()`, `SettingsKey`/`UserDefaults` helpers, `testHook_setCookieHeader`, `MockURLProtocol`.
- Produces (Task 4 relies on these exact names):
  `var activityRefreshEnabled: Bool` (observable, default `true`),
  `func setActivityRefreshEnabled(_ enabled: Bool)`,
  `func noteActivity()`,
  seams `activityDebounceInterval: Duration` (default `.seconds(20)`), `activityMinRefreshInterval: Duration` (default `.seconds(60)`).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/CursorMeterTests/ActivityRefreshTests.swift
import XCTest
@testable import CursorMeter

/// Thread-safe hit counter for MockURLProtocol handlers (which run off-main).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

@MainActor
final class ActivityRefreshTests: XCTestCase {

    private func makeViewModel(counting counter: RequestCounter) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/usage-summary" { counter.increment() }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (ok, Data("{}".utf8))
        }
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}   // UNUserNotificationCenter crashes in SPM tests
        vm.updateCheckRunner = { .upToDate }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=TEST")
        vm.activityDebounceInterval = .milliseconds(30)
        vm.activityMinRefreshInterval = .milliseconds(150)
        return vm
    }

    private func waitUntil(_ timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    func testBurstCollapsesToSingleRefresh() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        for _ in 0..<5 { vm.noteActivity() }
        await waitUntil { counter.count >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 1)
    }

    func testGuardDefersButNeverDrops() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        await vm.refresh()                       // any-source refresh stamps the guard
        XCTAssertEqual(counter.count, 1)

        vm.noteActivity()                        // debounce 30ms < guard 150ms
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(counter.count, 1)         // deferred: not fired early...
        await waitUntil { counter.count >= 2 }
        XCTAssertEqual(counter.count, 2)         // ...and not dropped
    }

    func testToggleOffCancelsPendingDebounce() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.noteActivity()
        vm.setActivityRefreshEnabled(false)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(vm.activityRefreshEnabled)
    }

    func testNoteActivityWhileDisabledIsNoOp() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.setActivityRefreshEnabled(false)
        vm.noteActivity()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ActivityRefreshTests 2>&1 | tail -5`
Expected: FAIL to build — `value of type 'UsageViewModel' has no member 'noteActivity'`

- [ ] **Step 3: Implement view-model logic**

`SettingsKey` (~line 19), add:

```swift
    case activityRefreshEnabled
```

State block (next to `watchTickInterval`, ~line 272):

```swift
    /// Event-driven refresh (#92): activity from CursorActivityWatcher is
    /// debounced, then deferred past a min-interval guard shared with every
    /// other refresh source. Defer — never drop — so a burst always lands.
    var activityRefreshEnabled = true
    @ObservationIgnored internal var activityDebounceInterval: Duration = .seconds(20)
    @ObservationIgnored internal var activityMinRefreshInterval: Duration = .seconds(60)
    @ObservationIgnored private var activityDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var activityGeneration = 0
    @ObservationIgnored private var lastRefreshAttempt: ContinuousClock.Instant?
```

In `refresh()`, immediately after the `guard !isRefreshing` line (~line 486):

```swift
        lastRefreshAttempt = ContinuousClock.now
```

New method (place after `refresh()`):

```swift
    /// Trailing-edge debounce + shared min-interval guard (defer semantics).
    func noteActivity() {
        guard activityRefreshEnabled else { return }
        activityDebounceTask?.cancel()
        let generation = activityGeneration
        activityDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.activityDebounceInterval)
            guard !Task.isCancelled, generation == self.activityGeneration else { return }
            if let last = self.lastRefreshAttempt {
                let remaining = self.activityMinRefreshInterval - ContinuousClock.now.duration(since: last)
                if remaining > .zero {
                    try? await Task.sleep(for: remaining)
                    guard !Task.isCancelled, generation == self.activityGeneration else { return }
                }
            }
            self.activityDebounceTask = nil
            await self.refresh()
        }
    }
```

Setter (next to `setWeeklyChartEnabled`, ~line 1077):

```swift
    func setActivityRefreshEnabled(_ enabled: Bool) {
        activityRefreshEnabled = enabled
        UserDefaults.standard.set(enabled, for: .activityRefreshEnabled)
        if !enabled {
            activityGeneration += 1
            activityDebounceTask?.cancel()
            activityDebounceTask = nil
        }
    }
```

`loadSettings` (~line 1149 block), add:

```swift
        if let enabled = defaults.object(for: .activityRefreshEnabled) as? Bool {
            activityRefreshEnabled = enabled
        }
```

- [ ] **Step 4: Run the new suite, then the full suite**

Run: `swift test --filter ActivityRefreshTests 2>&1 | tail -3` → `Executed 4 tests, with 0 failures`
Run: `swift test 2>&1 | tail -3` → 0 failures (no regression)

- [ ] **Step 5: Commit**

```bash
git add Sources/CursorMeter/UsageViewModel.swift Tests/CursorMeterTests/ActivityRefreshTests.swift
git commit -m "[#92] feat: debounced activity refresh with shared defer guard in UsageViewModel"
```

---

### Task 4: Settings toggle UI + app wiring

**Files:**
- Modify: `Sources/CursorMeter/SettingsViewController.swift`
  - toggle property (next to `weeklyChartToggle`, ~line 32)
  - `makeRefreshSection()` (~line 209): add row
  - control-state sync block (~line 177): sync toggle state
  - `@objc` actions block (~line 487): add handler
- Modify: `Sources/CursorMeter/CursorMeterApp.swift`
  - property + creation in `applicationDidFinishLaunching` (~line 72-79)
  - new `observeActivityRefreshSetting()` re-arm block (mirror `observeSettings()` at ~line 291)

**Interfaces:**
- Consumes: Task 3's `activityRefreshEnabled` / `setActivityRefreshEnabled` / `noteActivity`; Task 1/2's `CursorActivityWatcher`.
- Produces: user-visible toggle "Refresh on Cursor activity"; watcher lifecycle bound to the setting.

- [ ] **Step 1: SettingsViewController — add the toggle**

Property (~line 32):

```swift
    private var activityRefreshToggle = NSSwitch()
```

In `makeRefreshSection()` (~line 209), after the interval row, following the `weeklyChartToggle` row pattern at ~line 343:

```swift
        activityRefreshToggle = NSSwitch()
        activityRefreshToggle.target = self
        activityRefreshToggle.action = #selector(activityRefreshToggleChanged)
        activityRefreshToggle.state = viewModel.activityRefreshEnabled ? .on : .off

        let activityLabel = makeLabel("Refresh on Cursor activity")
        let activityRow = NSStackView(views: [activityLabel, makeSpacer(), activityRefreshToggle])
        activityRow.orientation = .horizontal
        activityRow.spacing = 8
        activityRow.alignment = .centerY
```

Add `activityRow` to the section's vertical stack. In the control-state sync block (~line 177):

```swift
        activityRefreshToggle.state = viewModel.activityRefreshEnabled ? .on : .off
```

Action (~line 487 block):

```swift
    @objc private func activityRefreshToggleChanged() {
        viewModel.setActivityRefreshEnabled(activityRefreshToggle.state == .on)
    }
```

- [ ] **Step 2: CursorMeterApp — create watcher, bind to setting**

Property near the other stored properties:

```swift
    private var activityWatcher: CursorActivityWatcher?
```

In `applicationDidFinishLaunching` after `observeSettings()` (~line 79):

```swift
        activityWatcher = CursorActivityWatcher { [weak self] in
            self?.viewModel.noteActivity()
        }
        syncActivityWatcher()
        observeActivityRefreshSetting()
```

New methods (mirror the one-shot re-arm shape of `observeSettings()` at ~line 291 exactly — read it first and copy its structure):

```swift
    private func syncActivityWatcher() {
        if viewModel.activityRefreshEnabled {
            activityWatcher?.start()
        } else {
            activityWatcher?.stop()
        }
    }

    private func observeActivityRefreshSetting() {
        withObservationTracking {
            _ = viewModel.activityRefreshEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.syncActivityWatcher()
                self.observeActivityRefreshSetting()   // one-shot: re-arm
            }
        }
    }
```

- [ ] **Step 3: Build + full test suite**

Run: `swift build 2>&1 | tail -3` → succeeds, no warnings about Sendable/isolation
Run: `swift test 2>&1 | tail -3` → 0 failures

- [ ] **Step 4: Commit + push + CI check**

```bash
git add Sources/CursorMeter/SettingsViewController.swift Sources/CursorMeter/CursorMeterApp.swift
git commit -m "[#92] feat: settings toggle and app wiring for activity-driven refresh"
git push && gh run list --limit 1
```

Expected: CI `Test` run success (CI Sendable rules are stricter than local — see Global Constraints if it fails).

---

### Task 5: Live verification, docs, screenshot

**Files:**
- Modify: `CLAUDE.md` (Architecture table), `README.md` + `README.ko.md` (feature list)
- Recapture: `docs/screenshots/settings.png` (new toggle is user-visible)

- [ ] **Step 1: Reinstall and verify watcher attaches** (App Reinstall sequence from CLAUDE.md)

```bash
pkill -9 -x CursorMeter; rm -rf /Applications/CursorMeter.app
bash Scripts/package_app.sh && cp -r CursorMeter.app /Applications/ && open /Applications/CursorMeter.app
sleep 5
/usr/bin/log show --predicate 'subsystem == "com.cursormeter" AND process == "CursorMeter"' --info --debug --last 1m | grep -i activity
```

Expected: either no "inactive" line (attached to real WAL) or the single inactive line if Cursor's WAL is momentarily absent (then it is dir-watching — also fine). **Do not write to the real WAL to force an event** (Global Constraints); end-to-end firing is verified by running one real Cursor query and re-checking `log show` for a refresh within ~80 s (20 s debounce + API time), or deferred to the user.

- [ ] **Step 2: Recapture `docs/screenshots/settings.png`**

AX-path-driven capture per CLAUDE.md (element paths only, no coordinates; `screencapture -x` + `sips` crop). **PII rule: inspect the capture for the real name / company email BEFORE `git add`.**

- [ ] **Step 3: Docs**

- `CLAUDE.md` Architecture table: add `| CursorActivityWatcher.swift | Watches Cursor's conversation-search WAL (DispatchSource); debounced event-driven refresh trigger |`
- `README.md` / `README.ko.md`: one feature bullet — refresh follows Cursor activity (within ~1 min), 5-min polling as fallback. No memory-footprint claims without A/B measurement.

- [ ] **Step 4: Commit + push + CI + close-out**

```bash
git add CLAUDE.md README.md README.ko.md docs/screenshots/settings.png
git commit -m "[#92] docs: architecture entry, README feature bullet, settings screenshot"
git push && gh run list --limit 1
gh issue close 92 --comment "Shipped: watcher + debounced refresh + settings toggle. Spec/plan in docs/superpowers/."
gh issue list --state open
```

Expected: CI green; remaining open issues shown to the user (workflow step 6).
