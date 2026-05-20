# v0.4.0-beta.1 — On-demand mode (beta)

> ⚠️ This is a **pre-release**. Existing v0.3.0 users will NOT be auto-notified by the in-app update check.

## What's new

- **On-demand transition.** When your monthly request (or credit) quota is exhausted AND on-demand billing is active, the menu bar progress ring + popover now switch to track on-demand spend (e.g. `$5.84 / $40.00` at 15%) instead of staying pegged at red 100%/151%.
- **Sticky latch.** Once on-demand mode engages mid-cycle, it stays until the billing cycle rolls over — no oscillation from API jitter.
- **Mode-aware notifications.** The 80%/90% threshold alerts now tell you which dimension they fire on (`월 요청 한도의 80%`, `On-demand 청구의 80% ($32 / $40)`, etc.) and re-arm against the new dimension when the mode switches.
- **Jump effect in on-demand mode.** ⚡ / 🚀 still fires against cents-based deltas after transition.
- **Fix.** On-demand routed via `teamUsage.onDemand` (some Enterprise team accounts) was silently invisible. Now falls back when `individualUsage.onDemand` is absent.

## Why beta

The on-demand transition only triggers on accounts whose request quota is actually exhausted mid-cycle. I haven't captured a real exhausted-quota API response yet — the field mapping is inferred from screenshots. If you're hitting this state, please [open an issue](https://github.com/WoojinAhn/CursorMeter/issues/new) if anything looks off.

Known limitations:
- Percent-only enterprise plans (no fixed request or credit limit) don't engage the latch — see follow-up issue.
- The latch is in-memory; an app restart while latched will re-arm threshold notifications once.

## Install (beta channel — does not affect existing v0.3.0 install)

```bash
curl -fsSL https://github.com/WoojinAhn/CursorMeter/releases/download/v0.4.0-beta.1/CursorMeter-0.4.0-beta.1.zip -o /tmp/CursorMeter-beta.zip \
  && ditto -xk /tmp/CursorMeter-beta.zip /tmp/ \
  && xattr -cr /tmp/CursorMeter.app \
  && pkill -x CursorMeter 2>/dev/null || true \
  && rm -rf /Applications/CursorMeter.app \
  && mv /tmp/CursorMeter.app /Applications/ \
  && open /Applications/CursorMeter.app
```

Once a non-beta v0.4.0 is published as `latest`, your existing install script (`Scripts/install.sh`) will pick it up normally.

---

## 한국어

> ⚠️ **베타 릴리스**입니다. 기존 v0.3.0 사용자에게는 인앱 업데이트 알림이 가지 않습니다.

### 변경 사항

- **On-demand 자동 전환.** 월 요청 한도(또는 크레딧 플랜)를 다 쓰고 on-demand 청구가 활성화되면, 메뉴바 진행률과 popover가 자동으로 on-demand 사용량(`$5.84 / $40.00`, 15% 등)을 표시하도록 전환됩니다. 더 이상 100%/151%에서 빨갛게 멈춰 있지 않습니다.
- **Sticky 모드.** 한번 on-demand 모드에 진입하면 billing cycle이 갱신될 때까지 유지됩니다.
- **알림 본문 분기.** 80% / 90% 임계 알림이 어느 한도(요청 / 플랜 / on-demand) 기준인지 본문에 명시되고, 모드 전환 시 재발사됩니다.
- **Jump effect (⚡ / 🚀)** on-demand 모드에서도 동작 (cents 단위 delta).
- **버그 수정.** `teamUsage.onDemand`로만 데이터가 내려오던 일부 Enterprise 팀 계정에서 on-demand 행이 누락되던 문제 수정.

### 베타 설치 (위 영어 섹션의 curl 명령 동일)

이슈: #36
