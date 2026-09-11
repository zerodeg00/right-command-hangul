# Right Command Hangul

macOS에서 오른쪽 `Command(⌘)` 키와 Windows 키보드의 오른쪽 `Alt` 키를
한/영 전환키로 바꿔 주는 작고 단순한 유틸리티입니다.

MacBook 내장 키보드와 macOS 또는 Windows 모드로 연결된 외장 키보드에서
사용할 수 있습니다. Caps Lock과 왼쪽 `⌘`는 원래 기능을 그대로 유지합니다.

## 왜 만들었나요?

Windows 키보드에 익숙하다가 Mac을 사용하면 한/영 전환키의 위치가 불편하게
느껴질 때가 많습니다. macOS에서는 Caps Lock이나 `Control-Space`로 입력
소스를 전환할 수 있지만, Caps Lock을 본래 용도로 계속 사용하고 싶거나 키
조합이 아닌 오른손 엄지의 단일 키로 빠르게 전환하고 싶은 사람도 있습니다.

이 문제를 해결하는 대표적인 방법은 Karabiner-Elements입니다. 강력하고 좋은
도구지만, 단지 오른쪽 `⌘` 하나를 한/영키로 바꾸기 위해 시스템 입력을 다루는
큰 프로그램을 추가로 설치하고 권한을 부여하는 것은 부담스럽게 느껴졌습니다.

그래서 macOS에 이미 포함된 기능만 이용하는 작은 도구를 직접 만들었습니다.
별도의 키보드 커스터마이징 앱이나 패키지 관리자를 설치하지 않고, Apple의
기본 API와 `hidutil`만으로 오른쪽 `⌘`를 한/영 전환키로 사용할 수 있습니다.

## 주요 특징

- Karabiner-Elements를 설치하지 않아도 됩니다.
- 입력 모니터링 권한은 요구하지 않습니다.
- 전환 직후 첫 글자를 안전하게 처리하기 위해 접근성 권한만 사용합니다.
- Caps Lock 기능을 변경하지 않습니다.
- 왼쪽 `⌘`는 기존 Command 키로 계속 사용할 수 있습니다.
- MacBook 내장 키보드와 외장 키보드에 함께 적용됩니다.
- 로그인하면 자동으로 실행됩니다.
- 네트워크 통신, 업데이트 확인, 사용자 데이터 수집을 하지 않습니다.
- 소스 코드가 짧아 실제 동작을 직접 확인할 수 있습니다.

## 요구 사항

- macOS
- 시스템 설정에 한국어 입력 소스가 추가되어 있어야 합니다.
- 외장 키보드는 macOS 모드로 연결되어 있어야 합니다.
- Xcode Command Line Tools의 `clang`이 필요합니다.
- 처음 실행할 때 macOS 접근성 권한을 허용해야 합니다.

한국어 입력 소스는 다음 경로에서 추가할 수 있습니다.

> 시스템 설정 → 키보드 → 텍스트 입력 → 편집 → `+` → 한국어

`clang`이 없다면 다음 명령으로 Command Line Tools 설치 창을 열 수 있습니다.

```sh
xcode-select --install
```

## 설치 방법

저장소를 내려받고 설치 스크립트를 실행합니다.

```sh
git clone https://github.com/zerodeg00/right-command-hangul.git
cd right-command-hangul
./scripts/install.sh
```

설치에는 `sudo`가 필요하지 않습니다. 설치 스크립트는 다음 작업을 수행합니다.

1. 현재 Mac에서 네이티브 실행 파일을 빌드합니다.
2. `~/Applications/Right Command Hangul.app`에 설치합니다.
3. 로그인 시 자동 실행되도록 `~/Library/LaunchAgents`에 등록합니다.
4. 접근성 권한을 요청하고, 허용되면 오른쪽 `⌘`를 F18로 매핑해 입력 소스
   전환 서비스를 시작합니다.

처음 설치하면 macOS가 접근성 권한을 묻습니다. 대화상자에서 시스템 설정을
연 뒤 `Right Command Hangul`을 허용해 주세요. 서비스가 실행된 상태로 권한을
확인하므로 로그아웃하거나 재부팅할 필요 없이 바로 사용할 수 있습니다.

권한 대화상자를 닫았거나 앱이 보이지 않는다면 다음 경로에서 직접 허용할 수
있습니다.

> 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용 → Right Command Hangul

## 사용 방법

오른쪽 `⌘` 또는 Windows 키보드의 오른쪽 `Alt`를 짧게 누르면 한글과
영문 입력 소스가 전환됩니다.

- 오른쪽 `⌘`: 한/영 전환
- Windows 키보드의 오른쪽 `Alt`: 한/영 전환
- 왼쪽 `⌘`: 기존 Command 기능
- Caps Lock: 기존 대문자 고정 기능
- `Control-Space`: 기존 macOS 입력 소스 단축키

영문 입력 소스는 `ABC`, 한국어 입력 소스는 `두벌식`을 우선 사용합니다.
해당 입력 소스가 없으면 활성화된 다른 영문 또는 한국어 입력 소스를
선택합니다.

## 제거 방법

저장소 폴더에서 다음 명령을 실행합니다.

```sh
./scripts/uninstall.sh
```

로그인 에이전트와 실행 파일이 삭제되고 오른쪽 `⌘`의 키 매핑도 해제됩니다.

## 어떻게 동작하나요?

macOS의 일반 키 상태 API는 왼쪽과 오른쪽 Command 키를 동일하게 취급합니다.
이를 구분하기 위해 다음과 같이 동작합니다.

1. `/usr/bin/hidutil`로 오른쪽 Command와 Right Alt의 HID 코드를 F18에
   매핑합니다.
2. 백그라운드 서비스가 이벤트 탭에서 F18을 직접 받아 소비한 뒤 Apple의
   Text Input Source API로 한국어와 영문 입력 소스를 전환합니다.
3. macOS가 입력 소스 변경을 완료했다는 알림을 보내기 전 들어온 키 이벤트는
   메모리에 잠깐 보관합니다.
4. 변경 알림이 도착하면 보관한 이벤트를 원래 순서대로 즉시 전달합니다. 알림이
   오지 않더라도 0.25초 뒤에는 반드시 전달해 키 입력이 사라지지 않게 합니다.

이 방식은 메뉴 막대의 입력 소스 표시만 먼저 바뀌고 실제 앱은 이전 입력
소스로 첫 글자를 처리하는 경쟁 상태를 막습니다. 폴링하지 않으므로 유휴
상태에서도 첫 입력을 놓치지 않으며, F18이 현재 앱까지 전달되어 경고음이
발생하는 것도 방지합니다. macOS의 입력 소스 단축키 설정은 수정하지 않습니다.
F18은 일반 키보드에 거의 없는 키이므로 다른 키와 충돌할 가능성도 낮습니다.

## 보안과 개인정보

- 관리자 권한을 사용하지 않습니다.
- 입력 모니터링 권한은 요청하지 않습니다.
- 접근성 권한은 F18을 소비하고 전환 직후의 키 이벤트를 잠깐 보관했다가 다시
  전달하는 데에만 사용합니다.
- 키 입력 내용이나 작성 중인 문자를 기록하거나 파일로 저장하지 않습니다.
- 인터넷에 연결하지 않습니다.
- 앱 번들, 로그인 에이전트와 로그 파일 외에는 설치하지 않습니다.

## 제한 사항

- 오른쪽 `⌘`는 한/영 전환 전용이 되므로 Command 조합키로 사용할 수 없습니다.
- macOS에서 Right Alt와 Right Option은 같은 HID 키이므로, 오른쪽 `Option`도
  한/영 전환 전용이 됩니다.
- macOS 로그인 화면에서는 동작하지 않습니다. 사용자 로그인 이후에만
  동작합니다.
- 다른 도구가 `hidutil`의 `UserKeyMapping`을 관리하고 있다면 서로의 매핑을
  덮어쓸 수 있습니다.
- 외장 키보드가 Windows 모드라면 오른쪽 키가 다른 HID 코드로 전달될 수
  있습니다. 키보드를 macOS 모드로 전환해 주세요.
- 소스에서 직접 빌드한 앱이므로 업데이트 뒤 macOS가 접근성 권한을 다시
  요구할 수 있습니다.

## 문제 해결

### 오른쪽 Command 또는 Alt를 눌러도 전환되지 않아요

서비스가 실행 중인지 확인합니다.

```sh
launchctl print "gui/$(id -u)/com.github.right-command-hangul"
```

`state = running`이 보이지 않으면 설치 스크립트를 다시 실행합니다.

```sh
./scripts/install.sh
```

외장 키보드를 사용한다면 키보드가 macOS 모드인지도 확인해 주세요.
서비스가 실행 중인데 동작하지 않으면 시스템 설정의 손쉬운 사용 목록에서
`Right Command Hangul`이 허용되어 있는지도 확인해 주세요.

### 입력 소스 전환 기능만 확인하고 싶어요

아래 명령은 키를 누르지 않고 입력 소스를 한 번 전환합니다.

```sh
"$HOME/Applications/Right Command Hangul.app/Contents/MacOS/right-command-hangul" --toggle
```

현재 입력 소스의 시스템 ID를 확인할 수도 있습니다.

```sh
"$HOME/Applications/Right Command Hangul.app/Contents/MacOS/right-command-hangul" --current
```

### 로그는 어디에 있나요?

```text
~/Library/Logs/RightCommandHangul/right-command-hangul.log
```

## 개발

직접 빌드하려면 저장소 루트에서 다음 명령을 실행합니다.

```sh
make
```

빌드 결과는 `build/right-command-hangul`에 생성됩니다.

## 라이선스

[MIT License](LICENSE)
