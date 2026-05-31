## Install

### Quick Install (recommended)

Downloads, unzips, removes quarantine, and moves to `/Applications` automatically. ([view script](https://github.com/WoojinAhn/CursorMeter/blob/main/Scripts/install.sh))

```bash
curl -sL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

### Manual Install
1. Download **CursorMeter-0.4.0.zip** below
2. Unzip the archive
3. Remove quarantine: `xattr -cr CursorMeter.app`
4. If upgrading, quit the running app first (menu bar → Quit)
5. Move `CursorMeter.app` to `/Applications`
6. Launch from Applications or Spotlight

---

## 설치

### 빠른 설치 (권장)

다운로드, 압축 해제, 격리 해제, `/Applications` 이동을 자동으로 수행합니다. ([스크립트 보기](https://github.com/WoojinAhn/CursorMeter/blob/main/Scripts/install.sh))

```bash
curl -sL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

### 수동 설치
1. 아래에서 **CursorMeter-0.4.0.zip** 다운로드
2. 압축 해제
3. 격리 해제: `xattr -cr CursorMeter.app`
4. 업그레이드 시, 실행 중인 앱 먼저 종료 (메뉴바 → Quit)
5. `CursorMeter.app`을 `/Applications`로 이동
6. Applications 또는 Spotlight에서 실행

---

## ✨ What's New

### On-demand mode

When your monthly request (or credit) quota is exhausted **and** on-demand billing is active, the menu bar ring and popover now switch to track on-demand spend (e.g. `$5.84 / $40.00` at 15%) instead of staying pegged at red 100% / 151%. The transition is sticky for the rest of the billing cycle — no oscillation from API jitter — and unlatches automatically when the cycle rolls over.

- **Mode-aware progress display.** Menu bar ring and popover progress bar both reflect on-demand spend once latched; the previous request-based row drops to a secondary line so you still see context.
- **Mode-aware threshold notifications.** 80% / 90% alerts now tell you which dimension they fire on (`월 요청 한도의 80%`, `On-demand 청구의 80% ($32 / $40)`, etc.) and re-arm against the new dimension when the mode switches.
- **Jump cue (⚡ / 🚀) works in on-demand mode.** Fires against cents-based deltas after transition.
- **Cycle rollover unlatches.** When a new billing cycle starts, on-demand mode releases automatically and the request-based view comes back.

## 🔧 Improvements

- **On-demand row no longer silently invisible on some Enterprise team accounts.** Data routed via `teamUsage.onDemand` (instead of `individualUsage.onDemand`) was previously dropped; now falls back correctly.
- **Logout fully resets on-demand state.** The latch is cleared on sign-out so the next account doesn't inherit the previous one's mode.

## ⚠️ Known Limitations

- **Percent-only enterprise plans** (no fixed request or credit limit) don't engage the on-demand latch — tracked as a follow-up.
- **The latch is in-memory.** An app restart while latched will re-arm threshold notifications once for the current cycle.
- **Passkey / WebAuthn login still not supported.** Same Apple Developer Program entitlement constraint as before — fall back to password + 2FA, an email code, or sign in with GitHub.

**Full Changelog**: https://github.com/WoojinAhn/CursorMeter/compare/v0.3.0...v0.4.0

---

## ✨ 새 기능

### On-demand 모드

월 요청 한도(또는 크레딧 플랜)를 다 쓰고 on-demand 청구가 활성화되면, 메뉴바 ring과 popover가 자동으로 on-demand 사용량(`$5.84 / $40.00`, 15% 등)을 표시하도록 전환됩니다. 더 이상 100% / 151%에서 빨갛게 멈춰 있지 않습니다. 한번 전환되면 billing cycle이 갱신될 때까지 유지되고(API jitter로 깜빡이지 않음), 새 사이클이 시작되면 자동으로 해제됩니다.

- **모드 인식 진행률 표시.** 전환 후 메뉴바 ring과 popover progress bar가 on-demand 사용량을 반영하고, 기존 요청 기반 정보는 보조 라인으로 내려가 맥락 확인이 가능합니다.
- **모드 인식 임계 알림.** 80% / 90% 알림 본문이 어느 한도(요청 / 플랜 / on-demand) 기준인지 명시되고(`월 요청 한도의 80%`, `On-demand 청구의 80% ($32 / $40)` 등), 모드 전환 시 새 차원에 대해 재발사됩니다.
- **Jump effect (⚡ / 🚀)** on-demand 모드에서도 동작 (cents 단위 delta).
- **사이클 갱신 시 자동 해제.** 새 billing cycle이 시작되면 latch가 풀리고 요청 기반 뷰로 자연스럽게 돌아옵니다.

## 🔧 개선

- **일부 Enterprise 팀 계정에서 on-demand 행이 누락되던 문제 수정.** `teamUsage.onDemand`로만 데이터가 내려오던 경우(`individualUsage.onDemand` 없음) 표시되지 않던 버그를 fallback 처리로 해결.
- **로그아웃 시 on-demand 상태 완전 초기화.** 다음 로그인 계정이 이전 계정의 latch 상태를 이어받지 않도록 sign-out 시 정리.

## ⚠️ 알려진 한계

- **퍼센트 전용 엔터프라이즈 플랜** (고정 request / credit limit 없는 케이스)에서는 on-demand latch가 작동하지 않습니다 — 후속 이슈로 트래킹.
- **Latch는 in-memory.** Latch 상태에서 앱을 재시작하면 해당 사이클의 임계 알림이 한 번 더 발사될 수 있습니다.
- **Passkey / WebAuthn 로그인은 여전히 지원되지 않습니다.** 동일한 Apple Developer Program entitlement 제약 — Google 계정이 passkey만 등록되어 있다면 비밀번호 + 2FA, 이메일 인증 코드, 또는 GitHub 로그인으로 대체해주세요.
