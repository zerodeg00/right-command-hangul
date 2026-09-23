# 한/영 전환 메커니즘 연구 (TISSelectInputSource 대체)

브랜치: `research/switch-mechanism`
환경: **macOS 26.2 Tahoe (Darwin 25.2.0)** — 결론에 결정적 영향.
목표: `TISSelectInputSource()` 기반 전환의 지연/알림누락을 근본적으로 없앨
대체 전환 메커니즘 조사 → 실측·문헌 근거로 채택 판단.

## TL;DR (결론 먼저)

- **"네이티브 한/영 키코드로 hidutil 단독 매핑 → 데몬 제거"는 불가능.** 한국어는
  일본어(Eisu/Kana=LANG2/LANG1)와 달리 macOS가 네이티브로 처리하는 한/영 토글
  키코드가 **없다**. (강한 부정 근거 다수)
- **"네이티브 단축키(Ctrl+Space) CGEvent 주입"은 원리상 최선이지만 이 머신에선
  두 겹으로 막힘**: (1) 해당 단축키가 꺼져 있음, (2) **Tahoe가 합성 이벤트를
  PID 게이트로 드롭**할 수 있음.
- **가장 실효적인 방향은 "TIS를 버리는 것"이 아니라 "Karabiner처럼 쓰는 것"**:
  Karabiner도 같은 `TISSelectInputSource`를 쓴다. 빠른 이유는 API가 아니라
  ① GUI(Aqua) 세션·콘솔 유저 컨텍스트, ② 소스 목록 사전 캐싱(핫패스 열거 제거),
  ③ fire-and-forget. + CJKV 레이스는 **macism식 "임시 포커스 윈도우 트릭"**으로
  강제 확정.

## 배경: 현행 방식의 한계 (실측)

현행: 오른쪽 ⌘/Alt →(hidutil) F18 → 데몬 CGEvent 탭이 F18 소비 →
`TISSelectInputSource()` → 완료 알림으로 확인 → 눌러둔 키 flush.

인프로세스 실측:
- `TISSelectInputSource` 반환 대개 <1ms, **간헐적 11~27ms 블로킹**, status 항상 `noErr`.
- **완료 알림 자주 누락** → `kReadyDelay(0.035s)` 대신 `kSafetyTimeout(0.25s)`
  폴백 → "누르고 기다려야 바뀜"의 정체.
- 핫패스에서 매 전환마다 `TISCreateInputSourceList` 재열거(불필요 비용).

로컬 환경:
- 소스: `com.apple.keylayout.ABC`, `com.apple.inputmethod.Korean.2SetKorean` (2개뿐 → 토글 단순).
- 네이티브 전환 단축키: **60(이전)=Ctrl+Space `enabled=0`, 61(다음) `enabled=0`** — 둘 다 꺼짐.
- plist: `ProcessType=Interactive`, gui 도메인 에이전트(세션 컨텍스트는 대체로 양호), 단 소스 캐싱 없음.

---

## 조사 결과

### A. Karabiner는 실제로 무엇을 쓰나 — "왜 빠른가"

- **같은 API.** `select_input_source` → 최종적으로 `TISSelectInputSource()` 호출
  (`cpp-osx-input_source/input_source.hpp` `select()`), 메인큐 dispatch로 감쌈.
  더 낮은/비공개 API 아님.
- **차이는 실행 컨텍스트.** `Karabiner-Console-User-Server`가 **GUI(Aqua) 세션의
  LaunchAgent로 콘솔 유저로** 실행됨(`DEVELOPMENT.md`). TIS는 라이브 GUI 세션에
  붙어 있을 때 제대로 동작; 백그라운드/비-GUI 세션에서 지연·알림누락이 생김.
- **핫패스 캐싱.** 선택 가능한 소스 목록을 미리 만들어두고
  `kTISNotifyEnabledKeyboardInputSourcesChanged` 때만 재빌드 → 전환 시 열거 0.
- **fire-and-forget.** 알림 기다리지 않고 TIS 쏘고 반환.
- **한국어 특례:** Karabiner/커뮤니티조차 CJKV에선 raw TIS를 못 믿어, 시스템
  "이전 입력소스" 단축키 경유를 권장(issue #1602).

### B. 네이티브 심볼릭 핫키 CGEvent 주입

- **원리상 동작·최선:** 설정된 60번 핫키(keycode+mask를 `com.apple.symbolichotkeys`
  에서 읽어) `CGEventCreateKeyboardEvent`+`CGEventPost(.cghidEventTap)`로 down/up
  동일 flags로 주입 → **WindowServer가 네이티브로 전환** (TIS 레이스 회피). 2소스면 깔끔한 토글.
- **막는 요인 (이 머신):**
  1. 해당 단축키 `enabled=0` → 켜야만 동작(시스템 설정 변경 필요).
  2. **Tahoe 합성이벤트 게이트**: WindowServer가 sender PID 검사로 합성 이벤트를
     드롭할 수 있음("CGEventPost dead-end on Tahoe"). Accessibility 권한 필수,
     샌드박스면 완전 차단. → **이 머신(Tahoe)에서 실제로 통하는지 실증 필요.**
- **대안(macism):** 핫키 주입이 아니라 `TISSelectInputSource` 후 **아주 작은
  임시 포커스 NSWindow**를 띄웠다가 닫아 IME 엔진을 강제 확정 + 대기.
  **Tahoe에선 대기값 ~150ms** 필요(구버전 ~1ms). 신뢰성↑ 대신 지연·포커스 순간 탈취.
- 함정: down/up flags 불일치 시 스페이스 오입력, keyDown 단독 불가, >2 소스는 직접 선택 불가(순환만).

### C. 네이티브 한/영 키코드(LANG1/LANG2)로 hidutil 단독 매핑

- **결론: 불가.** 한국어에는 네이티브 한/영 토글 키코드가 없음.
- HID(page 0x07): LANG1=0x90(=Kana/한글, vk 0x68), LANG2=0x91(=Eisu/한자, vk 0x66).
  일본어는 macOS가 Eisu/Kana를 1급 명령으로 처리(→ rinsuki dotfiles가 hidutil
  단독으로 일본어 전환 성공). **한국어는 LANG1/LANG2가 입력전환으로 소비되지 않음(inert).**
- Apple 한국어 입력기 가이드에도 전용 한/영 키 없음(Input 메뉴/Caps Lock/Fn만).
- 모든 데몬리스 한국어 가이드가 F18/F19 → 시스템 단축키 경유(=B의 설정판)를 쓰고
  LANG1을 안 씀 = 강한 부정 근거.

---

## 방식 비교

| 방식 | 지연/신뢰성 | 데몬 제거 | 이 머신(Tahoe) 실현성 | 비고 |
|---|---|---|---|---|
| 현행 raw TIS + 알림대기 | 알림누락 시 0.25s | 아니오 | 동작하나 지연 | 현 상태 |
| **C. hidutil→LANG1 단독** | — | 예(이상적) | **불가(한국어 미지원)** | 사망 |
| **B. 네이티브 핫키 주입** | 최상(원리상) | 부분 | **위험**: 단축키 꺼짐+Tahoe 게이트 | 실증 필수 |
| B'. F18→시스템단축키(데몬리스) | 상 | 예 | 가능하나 단축키 켜야 함 | 키 버퍼링 기능 상실, 순환만 |
| **A+macism. TIS를 제대로 + 포커스트릭** | 상(단 +~150ms) | 아니오 | **가장 확실** | 캐싱+GUI세션+fire&forget+IME강제확정 |

## 권고

"option 3 = TIS를 버린다"는 **깨끗한 승자가 없다**:
- C(네이티브 키코드)는 한국어에서 원천 불가.
- B(핫키 주입)는 Tahoe 합성이벤트 게이트 때문에 이 머신에서 통할지 불확실 —
  실제 앱(Accessibility 보유)으로 실증하기 전엔 베팅 불가.

대신 조사가 드러낸 **진짜 지렛대는 "TIS를 Karabiner처럼 쓰는 것"**:
1. 소스 목록 캐싱(핫패스 `TISCreateInputSourceList` 제거).
2. GUI(Aqua) 세션·콘솔 유저 컨텍스트 보장(`LimitLoadToSessionType=Aqua` 검토).
3. fire-and-forget + CJKV 레이스는 macism식 임시 포커스 윈도우로 확정,
   폴백 타임아웃 단축.

### 다음 단계(제안 우선순위)
1. **실증 스파이크(B 판정용):** 실제 앱 컨텍스트에서 Tahoe 합성이벤트가 통하는지
   최소 프로토타입으로 확인 → 통하면 B가 최선.
2. **안전한 개선(권장 기본선):** A+macism 방식 프로토타입 — 캐싱 + fire&forget +
   포커스 윈도우 트릭. Tahoe에서 신뢰성 확보되는 유일하게 확실한 경로.

## 출처
- Karabiner: cpp-osx-input_source `input_source.hpp`, cpp-osx-input_source_selector `selector.hpp`,
  Karabiner-Elements `DEVELOPMENT.md`, issue #1602 (CJKV).
- macism (laishulu/macism): TIS + 포커스윈도우 + Tahoe 150ms 대기.
- Tahoe CGEventPost 게이트: nick-liu.com "Tahoe hotkey dead-end".
- 심볼릭핫키 구조: jimratliff gist, diimdeep/dotfiles.
- LANG1/LANG2: W3C uievents-key #55, rinsuki/dotfiles(일본어), Apple 한국어 입력기 가이드, HID usage tables.
