**English** | [한국어](SECURITY.ko.md)

# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in CursorMeter, **please do not open a public issue.** Use GitHub's Private Vulnerability Reporting:

**Report**: [github.com/WoojinAhn/CursorMeter/security/advisories/new](https://github.com/WoojinAhn/CursorMeter/security/advisories/new)

### What to include

- Description of the vulnerability
- Steps to reproduce
- Expected impact
- Affected version (CursorMeter release tag and macOS version)

### Process

1. You report privately via the GitHub advisory form above
2. Acknowledgement within 48 hours
3. Fix is developed and tested
4. New release is published
5. Vulnerability is disclosed publicly via the GitHub advisory

---

## Threat Model

CursorMeter is a menu bar app that calls undocumented Cursor API endpoints using cookie-based session credentials. The protected assets are:

- **Cursor session cookies** (Keychain-stored), reusable for the lifetime of the session token
- **Account email / name**, derived from `/api/auth/me`

The login WebView is the only place CursorMeter loads third-party origins. Everything else (`/api/usage-summary`, `/api/usage`, `/api/auth/me`) talks directly to `cursor.com` over HTTPS using `URLSessionConfiguration.ephemeral`.

## WebView Whitelist Policy

The login WebView (`LoginWindow.swift`) validates every navigation against a two-tier host whitelist. The same check runs in both `decidePolicyFor navigationAction` and `decidePolicyFor navigationResponse`.

### Tier 1 — exact host match

Used for parents with broad attack surface where suffix matching could let a subdomain takeover or open redirect pivot through this WebView.

| Host | Reason |
|---|---|
| `cursor.com`, `www.cursor.com`, `authenticator.cursor.sh`, `authenticate.cursor.sh` | Cursor primary |
| `accounts.google.com`, `oauth2.googleapis.com` | Google OAuth (well-known endpoints only) |
| `github.com`, `api.github.com` | GitHub OAuth (no `pages.github.com` / `gist.github.com`) |
| `js.stripe.com`, `m.stripe.network` | Cursor dashboard payment widgets |
| `api.workos.com` | WorkOS non-tenant API |
| `login.microsoftonline.com` | Azure AD entry |

### Tier 2 — suffix match

Used only where exact enumeration is impractical (internal Cursor service segmentation, tenant-scoped SSO).

| Suffix | Reason |
|---|---|
| `.cursor.com`, `.cursor.sh` | Internal segmentation |
| `.workos.com` | Tenant-scoped SSO connections |
| `.microsoftonline.com` | Azure AD tenant variability |

### Mitigations in place

- `WKWebsiteDataStore.nonPersistent()` — login WebView leaves no on-disk cookie / cache
- `javaScriptCanOpenWindowsAutomatically = false`
- WebView is opened only for login and torn down immediately on completion
- Host check is case-insensitive
- Both `navigationAction` and `navigationResponse` enforce the same whitelist

### Cookie capture validation

Before persisting cookies to Keychain, `captureAndComplete` verifies that all names in `requiredCookieNames` are present. This blocks partial-cookie-write races where non-auth cookies (CSRF, analytics) arrive before the session token, which would otherwise produce a "successful" capture with an empty session header.

### Accepted residual risk

Subdomain takeover of an entity under one of the Tier 2 suffix providers (e.g. an unmaintained `*.workos.com` tenant) could in principle reach the login WebView. The blast radius is limited to a single Cursor login session; we accept this risk in exchange for supporting tenant-scoped SSO without an unbounded enumeration burden.

## Out of Scope

- Vulnerabilities in upstream dependencies (Cursor, Apple SDKs, OAuth providers) — please report to the respective vendor
- Issues that require physical access to an unlocked Mac
- Speculative timing attacks against the local Keychain
