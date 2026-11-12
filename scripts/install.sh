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
  -framework IOKit \
  -framework AppKit \
  -framework Carbon \
  -framework ApplicationServices \
  "$project_dir/src/right-command-hangul.m" \
  -o "$build_dir/right-command-hangul"

mapping_backup=$(mktemp)
trap 'status=$?
if [ "$status" -eq 0 ]; then
  rm -f "$mapping_backup"
else
  printf "Key mappings were saved to %s.\n" "$mapping_backup" >&2
fi' EXIT
"$build_dir/right-command-hangul" --print-mapping > "$mapping_backup"
launchctl bootout "gui/$user_id/$label" >/dev/null 2>&1 || true
/usr/bin/killall right-command-hangul >/dev/null 2>&1 || true
attempt=0
while /usr/bin/pgrep -u "$user_id" -x right-command-hangul >/dev/null; do
  if [ "$attempt" -ge 10 ]; then
    printf '%s\n' "The app did not stop. Quit it and retry." >&2
    exit 1
  fi
  sleep 1
  attempt=$((attempt + 1))
done
# Older versions clear all mappings when they stop, so restore the snapshot first.
/usr/bin/hidutil property --set "$(cat "$mapping_backup")" >/dev/null
install -m 0755 "$build_dir/right-command-hangul" "$binary_path"
install -m 0644 "$project_dir/app/Info.plist" "$contents_dir/Info.plist"
/usr/bin/codesign --force --sign - "$app_path" >/dev/null
rm -f "$legacy_binary"
rmdir "$(dirname "$legacy_binary")" >/dev/null 2>&1 || true
cp "$project_dir/launchagents/com.github.right-command-hangul.plist" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $binary_path" "$agent_path"
plutil -replace StandardOutPath -string "$log_dir/right-command-hangul.log" "$agent_path"
plutil -replace StandardErrorPath -string "$log_dir/right-command-hangul.log" "$agent_path"

launchctl bootstrap "gui/$user_id" "$agent_path"

printf '%s\n' "Installed. Use the 한/영 menu bar item to enable mapping and choose a switching mode."
