# Issue #90 — Browser login deprecation design

Approved 2026-07-18 (conversation). Browser login is deprecated but kept:
hidden behind a Settings opt-in, fully functional when enabled, and
auto-exposed when the Cursor IDE app is absent so no user ever has zero
connect paths.

## Decisions

| Decision | Value |
|----------|-------|
| Setting | `browserLoginEnabled` (UserDefaults key `browserLoginEnabled`), default **false**. Settings → GENERAL: checkbox "Enable browser login" + caption below: "Deprecated — Cursor IDE connection is the supported sign-in path." |
| Visibility rule | Every browser-login surface shows iff `browserLoginEnabled ∨ !ideInstalled`. Pure static `UsageViewModel.shouldShowBrowserLogin(enabled:ideInstalled:)` is the single source of truth. |
| Login layout | [Log in with Browser] button follows the rule; title gains a "(deprecated)" suffix except in the IDE-absent case it is still suffixed (consistency). Hidden → the guidance/body text no longer mentions the browser fallback. |
| Auth row | The logged-out "Log in with Browser..." row follows the same rule (hidden entirely when the rule is false). Logged-in "Log Out" row unchanged. |
| Default button | Supersedes #88's per-state Enter rule: **[Open Cursor IDE] / [Connect Cursor IDE] always carries Enter**; the browser button never does. Sole exception: IDE app absent → browser button is the only button and carries Enter. |
| Expiry notification | Routing follows the toggle: ON → open LoginWindow (today's behavior); OFF → activate the app and open the popover (IDE guidance / auto-exposed browser button handles the rest). |
| LoginWindow banner | One-line banner pinned above the web view: "⚠️ Browser login is deprecated and may stop working in a future release. Prefer Cursor IDE connection." Always shown (the window only opens through deprecated paths). |
| Unchanged | Existing browser-cookie sessions, LoginWindow whitelist/capture logic, Keychain storage, credential chain order (#54), no migration seeding. |

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
