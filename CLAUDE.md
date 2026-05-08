# CLAUDE.md — CursorMeter

## Overview

macOS menu bar app for monitoring Cursor IDE usage. Swift 6, pure AppKit (no SwiftUI), zero external dependencies.

## Build & Test

```bash
swift build              # Production build
swift test               # Run all tests (requires Xcode)
swift build -c release   # Release build
```

### App Reinstall (for testing changes)

macOS does not allow overwriting a running app binary. Always follow this sequence:

```bash
pkill -9 -x CursorMeter        # 1. Force kill
rm -rf /Applications/CursorMeter.app  # 2. Delete old bundle
bash Scripts/package_app.sh     # 3. Build release + create .app
cp -r CursorMeter.app /Applications/  # 4. Copy new bundle
open /Applications/CursorMeter.app    # 5. Launch
```

## Issue Workflow

Every feature issue follows this sequence:

1. **Test case selection** — Define tests for the logic being changed/added before writing code
2. **Implementation** — Write feature code and test code together
3. **`swift test`** — All tests must pass (currently 197)
4. **Commit/push** — Reference issue number in commit message
5. **Post-close check** — After closing an issue, run `gh issue list --state open` and show remaining issues to the user

## Architecture

| File | Role |
|------|------|
| `CursorMeterApp.swift` | App entry, NSApplicationDelegate + NSStatusItem + NSPopover |
| `MenuBarView.swift` | Popover UI (NSViewController, 4-section layout) |
| `SettingsViewController.swift` | Settings window (pure AppKit, NSViewController) |
| `UsageViewModel.swift` | State management, auto-refresh, settings persistence |
| `CursorAPIClient.swift` | API calls (actor, ephemeral URLSession) |
| `UsageModels.swift` | Codable models + display model |
| `CircularProgressIcon.swift` | Menu bar progress ring icon + color thresholds |
| `NotificationManager.swift` | Usage threshold notifications (UserNotifications) |
| `LoginWindow.swift` | WKWebView login + two-tier domain whitelist + cookie capture validation |
| `KeychainStore.swift` | Credential storage (Data Protection Keychain) |
| `LogRedactor.swift` | Sensitive data redaction for logs |
| `JumpEffectCoordinator.swift` | Observes `UsageViewModel.lastJump`, swaps `statusItem.button.image` to ⚡/🚀 emoji glyphs on tier 1/2; gates Bold + tier 2 system notification |
| `ExternalURL.swift` | Host-validated wrapper around `NSWorkspace.open` for GitHub URLs derived from the Releases API |

## Cursor API

Two undocumented endpoints used (cookie-based auth, no official schema):

| Endpoint | Purpose | Unit |
|----------|---------|------|
| `/api/usage-summary` | Primary — billingCycleEnd, plan %, membershipType | USD cents |
| `/api/usage` | Supplementary — request counts per model | requests |
| `/api/auth/me` | User info (email, name) | — |

- `UsageViewModel.refresh()` calls all three in parallel with graceful degradation
- `/api/usage` uses dynamic key parsing (no hardcoded model names)
- Reference project: [steipete/CodexBar](https://github.com/steipete/CodexBar) uses same dual-API strategy

## Conventions

- Swift 6 strict concurrency: `@MainActor`, `actor`, `Sendable`
- Zero external dependencies — macOS SDK only (`Foundation`, `AppKit`, `Security`, `WebKit`, `UserNotifications`)
- `URLSessionConfiguration.ephemeral` — no disk cache (also applies to `UpdateChecker`)
- Keychain via standard macOS Keychain (Data Protection Keychain requires entitlements unavailable to ad-hoc signed apps)
- WebView host whitelist enforced in both `decidePolicyFor navigationAction` and `decidePolicyFor navigationResponse`. Policy detail (two-tier exact + suffix list, ccTLD coverage, accepted residual risk) lives in `SECURITY.md`
- `UsageViewModel` uses `@Observable` (not `@Published`); observers must use `withObservationTracking` + re-arm pattern, not Combine `sink`
