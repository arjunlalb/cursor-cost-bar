# Cursor Cost Bar

Fork of [CursorMeter](https://github.com/WoojinAhn/CursorMeter) focused on **on-demand charged costs** for Team/Enterprise accounts.

## What it shows

- **Today (PT)** — sum of `chargedCents` for on-demand events today (America/Los_Angeles)
- **This week (Mon–now PT)** — same metric from Monday 00:00 Pacific through now

Plan-included usage contributes **$0.00** by design (actual charges only).

## Requirements

- macOS 14+
- Cursor IDE signed in on the same Mac
- Enterprise team account (uses `get-filtered-usage-events`)

## Build

```bash
cd cursor-cost-bar
bash Scripts/package_app.sh
cp -r CursorCostBar.app /Applications/
open -a CursorCostBar
```

First launch: right-click → Open (unsigned ad-hoc build).

## Tests

```bash
swift test
```
