## Install

### Quick Install (recommended)

Downloads, unzips, removes quarantine, and moves to `/Applications` automatically. ([view script](https://github.com/WoojinAhn/CursorMeter/blob/main/Scripts/install.sh))

```bash
curl -sL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

### Manual Install
1. Download **CursorMeter-0.6.0.zip** below
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
1. 아래에서 **CursorMeter-0.6.0.zip** 다운로드
2. 압축 해제
3. 격리 해제: `xattr -cr CursorMeter.app`
4. 업그레이드 시, 실행 중인 앱 먼저 종료 (메뉴바 → Quit)
5. `CursorMeter.app`을 `/Applications`로 이동
6. Applications 또는 Spotlight에서 실행

---

## ✨ What's New

### Pick your jump-effect glyphs

Settings → Usage Jump now has a **Style** row letting you choose between two emoji pairs for the menu bar jump effect:

- **Classic** (default, unchanged from v0.5.0): `⚡` for moderate jumps, `🚀` for Max-mode-sized jumps
- **Dollar**: `💲` for moderate, `💸` for big — matches the dollar-aware chart and popover for users tracking spend rather than request count

The selection persists across launches; tier classification and intensity are unaffected.

## 🔧 Improvements

- **Token-based enterprise on-demand row now shows real `$used / $limit`** instead of `0 / 0`. Popover also picks up the per-seat override (`hardLimitOverrideDollars`) from team-spend, so users on extended on-demand caps see their actual limit rather than the team default.
- **Weekly chart tooltip matches the popover denominator on token-based enterprise plans.** Plan-covered days now show `$X.XX` (sum of charged cents) instead of the raw weighted-unit integer, keeping the chart and the `$used / $limit` row in the same unit. Request-quota plans are unchanged — they continue to show the integer.
- **Notifications threshold rows stay full-width** when you toggle "Enable usage alerts" on and off. Previously the sliders sometimes settled on a narrower width after a toggle cycle.
- **Settings toggles no longer "blink"** when collapsing or expanding their sub-rows. Both the Notifications threshold controls and the Usage Jump sub-rows (Intensity + Style) now show/hide cleanly without a brief jump-up-then-disappear flicker.

## ⚠️ Known Limitations

- **Weekly chart is enterprise-team accounts only.** Personal Pro / Free plans don't see the chart — the dashboard endpoint that backs it returns empty for non-team plans.
- **Percent-only enterprise plans** still don't engage the on-demand latch (carried over from v0.4.0).
- **Passkey / WebAuthn login still not supported.** Same Apple Developer Program entitlement constraint as before — fall back to password + 2FA, an email code, or sign in with GitHub.

**Full Changelog**: https://github.com/WoojinAhn/CursorMeter/compare/v0.5.0...v0.6.0

---

## ✨ 새 기능

### Jump 이펙트 이모지 선택

Settings → Usage Jump 에 **Style** 행이 추가되어, 메뉴바 점프 이펙트에 사용할 이모지 페어를 선택할 수 있습니다:

- **Classic** (기본, v0.5.0과 동일): 중간 점프 `⚡`, Max-mode 급 점프 `🚀`
- **Dollar**: 중간 점프 `💲`, 큰 점프 `💸` — 차트/팝오버의 dollar-aware 표시와 어울리는 옵션으로, 요청 수보다 *지출* 을 추적하는 사용자에게 적합

선택은 재실행 후에도 유지됩니다. 점프 단계(tier) 분류와 강도(intensity)는 영향받지 않습니다.

## 🔧 개선

- **Token-based enterprise on-demand 행이 실제 `$used / $limit` 로 표시됩니다** (이전엔 `0 / 0`). team-spend 응답의 좌석별 override(`hardLimitOverrideDollars`)도 반영해서, on-demand 한도 증액을 받은 사용자도 자신의 실제 한도를 봅니다.
- **Token-based enterprise 플랜에서 주간 차트 tooltip이 팝오버와 같은 단위로 표시.** plan 흡수된 날도 `$X.XX` (해당 일 chargedCents 합) 로 표시되어, 차트와 popover 의 `$used / $limit` 행이 같은 단위로 일관됩니다. Request-quota 플랜은 그대로 정수 단위 유지.
- **Notifications 임계치 슬라이더 폭이 일관 유지.** 이전엔 "Enable usage alerts" 를 끄고/켜기 반복하면 슬라이더 폭이 좁아지는 경우가 있었습니다.
- **Settings 토글 시 "번쩍" 거리는 현상 해소.** Notifications 의 임계치 컨트롤과 Usage Jump 의 sub-row (Intensity + Style) 가 위로 점프했다가 사라지는 잔상 없이 깔끔하게 collapse/expand 됩니다.

## ⚠️ 알려진 한계

- **주간 차트는 엔터프라이즈 팀 계정 전용.** 개인 Pro / Free 플랜에서는 차트가 표시되지 않습니다 — 데이터 소스(Cursor 대시보드 엔드포인트)가 팀 계정 외에는 빈 응답을 반환하기 때문.
- **퍼센트 전용 엔터프라이즈 플랜**에서는 여전히 on-demand latch가 작동하지 않습니다 (v0.4.0에서 이어진 한계).
- **Passkey / WebAuthn 로그인은 여전히 지원되지 않습니다.** 동일한 Apple Developer Program entitlement 제약 — 비밀번호 + 2FA, 이메일 인증 코드, 또는 GitHub 로그인으로 대체해주세요.
