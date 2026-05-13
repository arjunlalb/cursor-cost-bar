## Install

### Quick Install (recommended)

Downloads, unzips, removes quarantine, and moves to `/Applications` automatically. ([view script](https://github.com/WoojinAhn/CursorMeter/blob/main/Scripts/install.sh))

```bash
curl -sL https://raw.githubusercontent.com/WoojinAhn/CursorMeter/main/Scripts/install.sh | bash
```

### Manual Install
1. Download **CursorMeter-0.3.0.zip** below
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
1. 아래에서 **CursorMeter-0.3.0.zip** 다운로드
2. 압축 해제
3. 격리 해제: `xattr -cr CursorMeter.app`
4. 업그레이드 시, 실행 중인 앱 먼저 종료 (메뉴바 → Quit)
5. `CursorMeter.app`을 `/Applications`로 이동
6. Applications 또는 Spotlight에서 실행

---

## ✨ What's New

### Weekly usage chart (enterprise team accounts)
A rolling 7-day bar graph now lives inside the popover for Cursor enterprise team accounts, so you can see how the week is trending without leaving the menu bar.

- Heat-colored bars (green / yellow / red) tied to the weekly maximum, with the most recent day highlighted (today shown rightmost).
- Adaptive y-axis ceiling and a dashed daily-budget reference line (`planLimit / cycleDays`) so each bar reads in context.
- Hover any bar for the exact request count.
- Today-highlight style is configurable in Settings — **Outline / Dim others / Both**, default Outline.
- Personal Pro / Free accounts: the chart and its Settings section are hidden automatically; the rest of the app is unchanged.

## 🔧 Improvements

- **Threshold notifications now re-arm at each billing cycle.** Previously, once 80% / 90% fired in a given cycle, the app stayed silent through the next cycle until you logged out. The new cycle is now detected automatically and the alerts reset.
- **Offline auto-retry actually retries.** When a refresh failed while the laptop was offline, the menu bar showed "Waiting for network…" but the 60-second background retry never fired. Reconnecting now restores the data without manually clicking refresh.
- **Switching accounts no longer leaves the previous team's chart on screen.** Signing into a different account, or being removed from a team mid-session, now clears the cached enterprise data immediately instead of waiting for a logout.
- **Jump cue (⚡ / 🚀) is no longer cut short.** A concurrent refresh could previously redraw the ring before the emoji's display window ended; the swap is now protected for its full 6 / 15s duration.
- **Color thresholds are now consistent between the menu-bar ring and the popover progress bar.** Both surfaces switch to yellow at 70% and red at 90% (the popover bar previously used 80% / 90%, occasionally giving conflicting signals at the same usage level).
- **Faster enterprise refresh.** The weekly fetch now runs in parallel with the main usage / summary / user-info batch once the team ID is cached, shaving one round-trip off each refresh.

## 🔒 Security

- **`https` is now enforced inside the login WebView.** Both navigation callbacks reject `http://`, `file:`, `javascript:`, and `data:` URLs even when the host is on the whitelist, closing a defense-in-depth gap on downgrade-to-HTTP redirects.
- **Pending offline retry is cancelled on logout.** A retry scheduled before logout could otherwise fire a stale refresh up to a minute later against cleared credentials.

See [`SECURITY.md`](https://github.com/WoojinAhn/CursorMeter/blob/main/SECURITY.md) for the full threat model.

## ⚠️ Known Limitations

- **Passkey / WebAuthn login is still not supported.** Same Apple Developer Program entitlement constraint as before — fall back to password + 2FA, an email code, or sign in with GitHub if your Google account requires a passkey.

**Full Changelog**: https://github.com/WoojinAhn/CursorMeter/compare/v0.2.1...v0.3.0

---

## ✨ 새 기능

### 주간 사용량 차트 (엔터프라이즈 팀 계정)
팝오버 안에 최근 7일 막대 그래프가 추가됐습니다. 브라우저를 열지 않고도 한 주의 사용 추이를 한눈에 볼 수 있습니다.

- 주간 최대값 기준으로 막대를 초록 / 노랑 / 빨강으로 표시, 오른쪽 끝이 오늘입니다.
- y축은 자동 스케일링, dashed line으로 일일 예산(`planLimit / cycleDays`) 기준선을 함께 그려서 각 막대를 맥락 속에서 읽을 수 있습니다.
- 막대 위에 마우스를 올리면 정확한 요청 수가 tooltip으로 표시됩니다.
- 오늘 강조 스타일은 Settings에서 선택 가능 — **Outline / Dim others / Both**, 기본값 Outline.
- 개인 Pro / Free 계정에서는 차트와 관련 Settings 섹션이 자동으로 숨겨집니다. 다른 기능은 그대로 동작합니다.

## 🔧 개선

- **빌링 사이클이 바뀌면 임계치 알림이 다시 발화합니다.** 이전엔 한 사이클에서 80% / 90% 알림이 한 번 떠도 다음 사이클로 넘어가도 침묵 상태였는데, 이제 사이클 변경을 감지해서 자동으로 다시 켜집니다.
- **오프라인 자동 재시도가 실제로 작동합니다.** 노트북이 오프라인인 상태에서 새로고침 실패 시 "Waiting for network…"는 표시됐지만 60초 background retry가 실행되지 않던 버그를 고쳤습니다. 네트워크 복구 시 자동으로 데이터가 회복됩니다.
- **계정/팀 전환 시 이전 팀의 차트가 남지 않습니다.** 다른 계정으로 로그인하거나 세션 중 팀에서 제거된 경우, 로그아웃 없이도 캐시가 즉시 정리됩니다.
- **점프 큐(⚡ / 🚀)가 중간에 잘리지 않습니다.** 다른 새로고침이 끼어들어 ring 아이콘을 다시 그리던 race를 막아, 6초 / 15초 노출 시간이 보장됩니다.
- **메뉴바 ring과 팝오버 progress bar의 색 임계치가 통일됐습니다.** 둘 다 70%에서 노랑, 90%에서 빨강으로 전환됩니다 (이전엔 popover bar만 80% / 90%였고 같은 사용량에 서로 다른 색이 보이는 순간이 있었음).
- **엔터프라이즈 새로고침이 빨라졌습니다.** team ID가 캐시된 이후로는 weekly fetch가 기본 batch와 병렬로 실행되어 매 새로고침마다 한 round-trip 절약.

## 🔒 보안

- **로그인 WebView에서 `https` 스킴까지 강제합니다.** 두 navigation 콜백 모두 `http://`, `file:`, `javascript:`, `data:` URL을 거부합니다 — 호스트가 화이트리스트에 있어도 마찬가지. HTTP downgrade redirect에 대한 defense-in-depth.
- **로그아웃 시 보류 중인 오프라인 재시도 취소.** 이전엔 로그아웃 직전에 예약된 재시도가 최대 1분 뒤에 빈 자격증명으로 새로고침을 시도할 수 있었습니다.

전체 위협 모델은 [`SECURITY.ko.md`](https://github.com/WoojinAhn/CursorMeter/blob/main/SECURITY.ko.md) 참조.

## ⚠️ 알려진 한계

- **Passkey / WebAuthn 로그인은 여전히 지원되지 않습니다.** 동일한 Apple Developer Program entitlement 제약 — Google 계정이 passkey만 등록되어 있다면 비밀번호 + 2FA, 이메일 인증 코드, 또는 GitHub 로그인으로 대체해주세요.
