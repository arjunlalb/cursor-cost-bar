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
- Path missing at startup (Cursor not installed / moved): do not start;
  log one line; timer-only behavior is unchanged.
- Decoupled from `UsageViewModel`: emits via an injected
  `onActivity: () -> Void` closure. Watched path is injectable for tests.

### `UsageViewModel` integration

- `onActivity` → debounce **20 s** (trailing edge: bursts during a long
  agent session collapse to one refresh 20 s after the last event).
- Min-interval guard **60 s** between event-driven refreshes, so a
  continuously active agent session costs at most 1 refresh/min.
  Timestamps use `ContinuousClock` (existing convention).
- Existing 5-min polling loop (`startAutoRefresh`) stays as fallback.
- Debounce/guard values are internal constants, exposed as
  `@ObservationIgnored internal var` seams for tests (same pattern as
  `watchTickInterval`).

### Settings

- One toggle in the Settings window: "Refresh on Cursor activity",
  default **ON**, persisted via `UserDefaults` (existing
  `SettingsKey` enum pattern). Toggling stops/starts the watcher live.

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

Core logic only, real FS via temp dirs (no Cursor path in tests):

1. Debounce: N rapid file writes → exactly one `onActivity`-driven refresh.
2. Min-interval guard: two bursts 30 s apart (simulated clock) → second
   refresh suppressed until 60 s elapsed.
3. WAL lifecycle: delete + recreate watched file → events still delivered.
4. Missing path: watcher start is a no-op, no crash, no refresh.
5. Settings toggle OFF → watcher stopped, no event-driven refreshes.

Constraints honored: Swift 6 strict concurrency, zero external
dependencies, no Keychain/UNUserNotificationCenter in tests.

## Out of scope

- Deriving usage amounts from local data (impossible — see findings).
- Request-count heuristics from bubble counts.
- Watching Cursor process lifecycle (NSWorkspace) — YAGNI; revisit only
  if the WAL signal proves unreliable across Cursor versions.
