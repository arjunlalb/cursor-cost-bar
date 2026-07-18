# Issue #90 — Browser login deprecation design

Approved 2026-07-18 (conversation). Browser login is deprecated but kept:
hidden behind a Settings opt-in, fully functional when enabled, and
auto-exposed when the Cursor IDE app is absent so no user ever has zero
connect paths.

## Decisions

| Decision | Value |
|----------|-------|
| Setting | `browserLoginEnabled` (UserDefaults key `browserLoginEnabled`), default **false**. Settings → GENERAL: checkbox "Enable browser login" + caption below: "Deprecated — Cursor IDE connection is the supported sign-in path." |
| Visibility rule | Every browser-login surface shows iff `browserLoginEnabled ∨ !ideInstalled`. Pure static `UsageViewModel.shouldShowBrowserLogin(enabled:ideInstalled:)` is the single source of truth. `ideInstalled = ideAppPresenceCheck?() ?? true`, evaluated at render time, **independent of the #88 credential probe** — the presence answer is refreshed on every popover open/re-render, which is the defined re-evaluation timing (same policy as the #88 availability probe; no live install/uninstall observation). |
| Discoverability when hidden | When the rule hides the browser button in the login layout, a small caption appears instead: "Browser login can be enabled in Settings." — a session-expired browser-only user (toggle OFF, IDE installed) always has a documented recovery path. |
| Layout matrix | `ideCredentialAvailable` (nil/true) → [Connect Cursor IDE] carries Enter; `false` + installed → [Open Cursor IDE] carries Enter; `false`/nil + **not installed** → browser button is the only button and carries Enter. Browser button, when visible alongside an IDE button, is always secondary. |
| Login layout | [Log in with Browser] button follows the rule; title gains a "(deprecated)" suffix except in the IDE-absent case it is still suffixed (consistency). Hidden → the guidance/body text no longer mentions the browser fallback. |
| Auth row | The logged-out "Log in with Browser..." row follows the same rule (hidden entirely when the rule is false). Logged-in "Log Out" row unchanged. |
| Default button | Supersedes #88's per-state Enter rule: **[Open Cursor IDE] / [Connect Cursor IDE] always carries Enter**; the browser button never does. Sole exception: IDE app absent → browser button is the only button and carries Enter. |
| Expiry notification | Routing follows the toggle: ON → open LoginWindow (today's behavior); OFF → activate the app and open the popover (IDE guidance / auto-exposed browser button handles the rest). Notification copy must stay routing-neutral ("reconnect"-style wording, no promise of a login window) — verify and adjust the NotificationManager text if it is browser-specific. Window-focus policy: existing `showPopover()` semantics (NSApp.activate) suffice; with the toggle OFF a LoginWindow cannot be open. |
| LoginWindow banner | One-line banner pinned above the web view: "⚠️ Browser login is deprecated and may stop working in a future release. Prefer Cursor IDE connection." Always shown (the window only opens through deprecated paths). |
| Unchanged | Existing browser-cookie sessions, LoginWindow whitelist/capture logic, Keychain storage, credential chain order (#54), no migration seeding. |
| Messaging for IDE-absent users | The Settings caption and LoginWindow banner keep a single policy-statement copy ("Cursor IDE connection is the supported path") even when the IDE is absent — it doubles as an install nudge; only the login-layout body copy branches (per #88). |
| Single writer | `browserLoginEnabled` is mutated only by the Settings checkbox — no extra observation wiring for the Settings window itself (popover tracking is still required). |

## Components

- `UsageViewModel`
  - `var browserLoginEnabled: Bool` (observable; persisted via `setBrowserLoginEnabled` like other settings; loaded in `loadSettings`)
  - `nonisolated static func shouldShowBrowserLogin(enabled: Bool, ideInstalled: Bool) -> Bool { enabled || !ideInstalled }`
- `MenuBarView`
  - `applyLoginRequiredStatus()`: browser button gated by the rule (`viewModel.browserLoginEnabled`, `ideAppPresenceCheck`); Enter per the Default-button decision; body copy drops the browser mention when hidden.
  - Auth row builder: logged-out browser item gated by the same rule.
- `SettingsViewController`
  - GENERAL section: checkbox + caption; writes through `setBrowserLoginEnabled`; `updateUI()` reflects state.
- `CursorMeterApp`
  - Notification `.openLoginWindow` handler: branch on `viewModel.browserLoginEnabled` → `showLogin()` or activate + `showPopover()`.
- `LoginWindow`
  - Banner label above the WKWebView (fixed text, no interaction).
- Observation: `browserLoginEnabled` added to the popover tracking block in `CursorMeterApp` (CLAUDE.md pitfall — unobserved state never re-renders).

## Testing (critical logic only)

- `shouldShowBrowserLogin`: all four `enabled × ideInstalled` combinations
- setting round-trip: `setBrowserLoginEnabled` persists and `loadSettings` restores
- notification routing: toggle ON → login-window path chosen, OFF → popover path (via a seam or enum-returning pure router if extraction is cheap)

Layouts, Settings toggle, and the LoginWindow banner verified live.

## Revision note

2026-07-18: revised after codex:rescue spec review — Settings-recovery hint
when the browser button is hidden; explicit layout matrix incl.
`ideCredentialAvailable` nil handling and render-time presence evaluation;
routing-neutral notification copy requirement; documented single-copy
messaging decision and single-writer rationale. Rejected: live IDE
install/uninstall observation (popover-open re-render is the defined
timing) and a new window-focus policy for notification rerouting (existing
showPopover semantics; LoginWindow cannot be open with the toggle OFF).
