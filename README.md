# Cursor Cost Bar

Fork of [CursorMeter](https://github.com/WoojinAhn/CursorMeter) focused on **on-demand charged costs** for Team/Enterprise accounts.

## What it shows

Open the menu bar popover for a **metrics comparison table** (Today PT | Week Mon–now PT):

| Metric | Source |
|--------|--------|
| On-demand billed $ | `chargedCents` on usage-based events only |
| All chargedCents $ | Every event's `chargedCents` |
| Token cost $ | `tokenUsage.totalCents` |
| Weighted units | `requestsCosts` (matches Cursor request quota) |
| Events | Event count |
| Input / output tokens | When present in events |

Billing-cycle totals from `usage-summary` appear below the table.

Pick which metric drives the **menu bar title** via the popover dropdown or Settings → Display → Menu bar metric.

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
