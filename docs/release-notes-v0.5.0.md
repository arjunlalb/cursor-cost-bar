## Install

### Quick Install (recommended)

Downloads, unzips, removes quarantine, and moves to `/Applications` automatically. ([view script](https://github.com/WoojinAhn/CursorMeter/blob/main/Scripts/install.sh))

```bash
curl -sL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

### Manual Install
1. Download **CursorMeter-0.5.0.zip** below
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
1. 아래에서 **CursorMeter-0.5.0.zip** 다운로드
2. 압축 해제
3. 격리 해제: `xattr -cr CursorMeter.app`
4. 업그레이드 시, 실행 중인 앱 먼저 종료 (메뉴바 → Quit)
5. `CursorMeter.app`을 `/Applications`로 이동
6. Applications 또는 Spotlight에서 실행

---

## ✨ What's New

### Weekly chart now reflects weighted usage, not raw call count

The popover's 7-day bar graph used to count every API call equally — 10 light auto-completes looked identical to 10 Max-mode Opus calls. The y-axis now sums Cursor's weighted billing unit (`requestsCosts`) instead, so a single Max-mode Opus call with a large context can correctly outweigh dozens of light completions. The same unit denominates Cursor's plan limit (`Requests: 130 / 500`), so chart heights and plan-progress display now speak the same language.

The dashed daily-budget reference line is removed — relative day-to-day comparison via heat color is the chart's single visual job now.

### Mode-aware hover tooltip

Hovering a bar now shows the unit that matches that day's actual billing mode:

- **Plan-covered days** → raw weighted-unit integer (e.g. `929`) — matches the `Requests: X / 2000` denominator
- **On-demand days** → real dollars charged (e.g. `$0.96`) — matches the `$X / $40` on-demand cap

Mode is detected per day from each event's billing classification, so the chart adapts automatically across billing-cycle rollovers — no hardcoded cycle dates.

## 🔧 Improvements

- **Popover no longer stays open when you click a system menu bar item.** Clicking Battery, Wi-Fi, Control Center, etc. while the popover is open now dismisses it cleanly. The `transient` behavior alone didn't catch these clicks because they land on SystemUIServer rather than a regular window — a global event monitor closes the popover for any out-of-app click while it's visible.
- **Update checker no longer silently masks failures as "Up to date".** Previously, a GitHub API error, decoding failure, or network timeout was indistinguishable from being current — every failure path rendered as "Up to date". Settings now shows `Couldn't check (<reason>)` with the Check Now button available for retry, so a broken update mechanism is visible instead of hidden.

## ⚠️ Known Limitations

- **Weekly chart is enterprise-team accounts only.** Personal Pro / Free plans don't see the chart — the data source is a Cursor dashboard endpoint that returns empty on non-team plans. Tracked as a follow-up.
- **Percent-only enterprise plans** still don't engage the on-demand latch (carried over from v0.4.0).
- **Passkey / WebAuthn login still not supported.** Same Apple Developer Program entitlement constraint as before — fall back to password + 2FA, an email code, or sign in with GitHub.

**Full Changelog**: https://github.com/WoojinAhn/CursorMeter/compare/v0.4.0...v0.5.0

---

## ✨ 새 기능

### 주간 차트, 호출 횟수 대신 가중 사용량을 반영합니다

팝오버의 7일 막대 차트는 그동안 모든 API 호출을 동일하게 1로 셌습니다 — 가벼운 자동완성 10개와 Max-mode Opus 10콜이 같은 높이로 보였죠. 이제 y축이 Cursor의 가중 과금 단위(`requestsCosts`) 합을 표시하므로, 큰 context를 가진 Max-mode Opus 1콜이 가벼운 자동완성 수십 개를 상대적으로 압도할 수 있습니다. plan 한도(`Requests: 130 / 500`)도 동일 단위라, 차트 높이와 plan 진행률 표시가 같은 의미로 읽힙니다.

기존의 dashed 일일 예산선은 제거했습니다 — 차트는 막대 사이 상대 비교(heat color)만 표현하도록 단순화했습니다.

### 모드 인식 호버 tooltip

막대 위에 마우스를 올리면 그날 *실제 과금 모드*에 맞는 단위로 값을 표시합니다:

- **Plan 흡수된 날** → 가중치 정수 (예: `929`) — `Requests: X / 2000` 분모와 같은 단위
- **On-demand 청구된 날** → 실제 청구 달러 (예: `$0.96`) — `$X / $40` on-demand 한도와 같은 단위

날짜별 모드는 각 이벤트의 과금 분류에서 직접 도출됩니다. 사이클 경계가 차트 윈도우 안에 들어와도 자동으로 분기되며, 별도의 사이클 날짜 하드코딩이 없습니다.

## 🔧 개선

- **다른 메뉴바 앱(배터리, Wi-Fi, 제어 센터 등) 클릭 시 popover가 닫힙니다.** 시스템 메뉴 항목 클릭은 일반 윈도우가 아니라 SystemUIServer에 도달해서 `transient` 자체 dismiss 가 안 잡히던 문제 — popover 열린 동안 앱 외부 클릭을 잡는 global event monitor 추가로 해결.
- **업데이트 체크 실패가 "Up to date"로 위장되는 문제 수정.** 이전에는 GitHub API 에러, 디코딩 실패, 네트워크 타임아웃 모두 "Up to date"로 표시되어 사용자가 인지할 수 없었습니다. Settings 의 Updates 섹션에 `Couldn't check (<reason>)` 상태가 추가되고 Check Now 버튼이 그대로 노출되어 수동 재시도 가능합니다.

## ⚠️ 알려진 한계

- **주간 차트는 엔터프라이즈 팀 계정 전용.** 개인 Pro / Free 플랜에서는 차트가 표시되지 않습니다 — 데이터 소스(Cursor 대시보드 엔드포인트)가 팀 계정 외에는 빈 응답을 반환하기 때문. 후속 이슈로 트래킹 중.
- **퍼센트 전용 엔터프라이즈 플랜**에서는 여전히 on-demand latch가 작동하지 않습니다 (v0.4.0에서 이어진 한계).
- **Passkey / WebAuthn 로그인은 여전히 지원되지 않습니다.** 동일한 Apple Developer Program entitlement 제약 — 비밀번호 + 2FA, 이메일 인증 코드, 또는 GitHub 로그인으로 대체해주세요.
