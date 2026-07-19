# Issue #92 — Event-Driven Usage Refresh on Cursor Activity

**Date:** 2026-07-19
**Issue:** [#92](https://github.com/WoojinAhn/CursorMeter/issues/92)

## Problem

Displayed usage lags behind actual Cursor activity by up to the polling
interval (default 5 min). The goal: refresh shortly after the user runs a
query in Cursor IDE, without increasing steady-state API traffic.

## Feasibility findings (measured on-machine, 2026-07-19)

- `~/Library/Application Support/Cursor/User/globalStorage/conversation-search.db-wal`
  changes on AI conversation activity and stays untouched while idle
  (20 s observation window, mtimes frozen). Suitable trigger signal.
- `state.vscdb` also stores general editor state — too noisy to watch.
- Local data carries **no billing figures**: `bubbleId:` entries have
  `tokenCount` fields but all sampled 300 recent bubbles read
  `{inputTokens:0, outputTokens:0}`; no cost/cents keys exist anywhere.
  `contextTokensUsed` is context-window occupancy, not billing.
- Therefore the watcher can only *time* the existing API `refresh()`;
  it cannot replace it.

## Design

### New component: `CursorActivityWatcher` (`@MainActor`, new file)

- Watches the WAL path above via
  `DispatchSource.makeFileSystemObjectSource` for `.write`, `.delete`,
  `.rename` events. Holds one file descriptor.
- On `.delete`/`.rename` (SQLite WAL checkpoints recreate the file):
  close fd, retry-open on a short delay (a few attempts, then fall back
  to watching the parent `globalStorage` directory until the file
  reappears, then re-attach to the file).
- WAL missing at startup is a **normal state** (SQLite deletes the WAL
  on clean close), not just "Cursor not installed": apply the same
  parent-directory fallback — watch `globalStorage/` until the WAL
  appears, then attach. Only when the parent directory itself is absent
  (Cursor not installed / moved) does the watcher stay off entirely;
  log one line; timer-only behavior is unchanged.
- Event and cancel handlers run on `DispatchQueue.main`
  (`makeFileSystemObjectSource(..., queue: .main)`) and hop into the
  actor via `MainActor.assumeIsolated`. The callback is typed
  `onActivity: @MainActor () -> Void`. No other queues involved —
  keeps Swift 6 strict concurrency clean.
- Decoupled from `UsageViewModel`: emits via the injected `onActivity`
  closure. Watched path is injectable for tests.

### `UsageViewModel` integration

- `onActivity` → debounce **20 s** (trailing edge: bursts during a long
  agent session collapse to one refresh 20 s after the last event).
- Min-interval guard **60 s**, measured against the last refresh
  **attempt from any source** (timer, manual, network retry, or
  event-driven) — `refresh()` itself only guards concurrent execution
  (`isRefreshing`, `UsageViewModel.swift:485`), so the rate cap lives
  here. Semantics are **defer, not drop**: if the debounce fires inside
  the guard window, schedule one trailing refresh for the moment the
  window expires (coalescing with any further events); an activity
  burst is never silently lost. Net effect: at most 1 refresh/min
  regardless of how refresh sources interleave. Timestamps use
  `ContinuousClock` (existing convention).
- Existing 5-min polling loop (`startAutoRefresh`) stays as fallback.
- Debounce/guard values are internal constants, exposed as
  `@ObservationIgnored internal var` seams for tests (same pattern as
  `watchTickInterval`).

### Settings

- One toggle in the Settings window: "Refresh on Cursor activity",
  default **ON**, persisted via `UserDefaults` (existing
  `SettingsKey` enum pattern). Toggling stops/starts the watcher live.
- Toggle OFF cancels the watcher source **and** any pending debounce /
  deferred-refresh task, and bumps a generation token so an in-flight
  callback from the old generation is ignored (same pattern as
  `ideWatchGeneration`). Nothing event-driven fires after OFF.

### Error handling

- Every watcher failure mode (fd open failure, source cancel, repeated
  reopen failure) degrades silently to timer-only polling + one
  `Log.info` line. No user-facing error UI.

## Memory / performance budget

- One fd + one dispatch source + one debounce task: ≪ 0.1 MB against
  the measured 37 MB baseline. Kernel-event driven — no polling reads,
  independent of watched file size.
- API traffic: unchanged 5-min baseline; event-driven refreshes occur
  only on real activity, capped at 1/min.

## Testing

Core logic only, real FS via temp dirs (no Cursor path in tests).
Timing: no simulated clock — tests inject **shortened durations**
(tens of ms) through the `@ObservationIgnored` seams and assert on
refresh *counts* after convergence, the same approach the existing
suite uses for `watchTickInterval`. No wall-clock assertions.

1. Debounce: N rapid file writes → exactly one `onActivity`-driven refresh.
2. Min-interval guard, defer semantics: burst inside the guard window →
   exactly one trailing refresh after the window expires (not zero —
   verifies defer-not-drop; shared guard covers a timer-sourced refresh
   immediately preceding the burst).
3. WAL lifecycle: delete + recreate watched file → events still delivered.
4. WAL absent at start, parent dir present → watcher attaches once the
   file appears; parent dir absent → start is a no-op, no crash.
5. Settings toggle OFF with a pending debounce → debounce cancelled,
   zero refreshes fire afterward.

Constraints honored: Swift 6 strict concurrency, zero external
dependencies, no Keychain/UNUserNotificationCenter in tests.

## Out of scope

- Deriving usage amounts from local data (impossible — see findings).
- Request-count heuristics from bubble counts.
- Watching Cursor process lifecycle (NSWorkspace) — YAGNI; revisit only
  if the WAL signal proves unreliable across Cursor versions.
