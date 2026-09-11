#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/build"
app_path="$HOME/Applications/Right Command Hangul.app"
contents_dir="$app_path/Contents"
macos_dir="$contents_dir/MacOS"
legacy_binary="$HOME/Library/Application Support/RightCommandHangul/right-command-hangul"
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/RightCommandHangul"
binary_path="$macos_dir/right-command-hangul"
agent_path="$agent_dir/com.github.right-command-hangul.plist"
label="com.github.right-command-hangul"
user_id=$(id -u)

mkdir -p "$build_dir" "$macos_dir" "$agent_dir" "$log_dir"

clang \
  -fobjc-arc \
  -Wall -Wextra -Werror -O2 \
  -framework Foundation \
  -framework Carbon \
  -framework ApplicationServices \
  "$project_dir/src/right-command-hangul.m" \
  -o "$build_dir/right-command-hangul"

launchctl bootout "gui/$user_id/$label" >/dev/null 2>&1 || true
sleep 1
"$build_dir/right-command-hangul" --clear-mapping >/dev/null 2>&1 || true
install -m 0755 "$build_dir/right-command-hangul" "$binary_path"
install -m 0644 "$project_dir/app/Info.plist" "$contents_dir/Info.plist"
/usr/bin/codesign --force --sign - "$app_path" >/dev/null
rm -f "$legacy_binary"
rmdir "$(dirname "$legacy_binary")" >/dev/null 2>&1 || true

if "$binary_path" --per-context-input-enabled; then
  printf '\n%s\n' "주의: macOS의 '문서의 입력 소스로 자동으로 전환' 옵션이 켜져 있습니다."
  printf '%s\n' "메뉴 막대와 실제 입력 언어가 달라질 수 있으므로 다음 경로에서 꺼 주세요."
  printf '%s\n\n' "시스템 설정 → 키보드 → 텍스트 입력 → 편집 → 모든 입력 소스"
fi

cp "$project_dir/launchagents/com.github.right-command-hangul.plist" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $binary_path" "$agent_path"
plutil -replace StandardOutPath -string "$log_dir/right-command-hangul.log" "$agent_path"
plutil -replace StandardErrorPath -string "$log_dir/right-command-hangul.log" "$agent_path"

launchctl bootstrap "gui/$user_id" "$agent_path"

printf '%s\n' "Installed Right Command Hangul."
printf '%s\n' "Right Command and Right Alt switch between Korean and Latin input sources."
printf '%s\n' "Allow Accessibility access when macOS asks; switching starts as soon as it is granted."
