#!/bin/sh
set -eu

support_dir="$HOME/Library/Application Support/RightCommandHangul"
app_path="$HOME/Applications/Right Command Hangul.app"
agent_path="$HOME/Library/LaunchAgents/com.github.right-command-hangul.plist"
label="com.github.right-command-hangul"
user_id=$(id -u)

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
make -s -C "$project_dir"
cleanup_binary="$project_dir/build/right-command-hangul"
mapping_backup=$(mktemp)
trap 'status=$?
if [ "$status" -eq 0 ]; then
  rm -f "$mapping_backup"
else
  printf "Key mappings were saved to %s.\n" "$mapping_backup" >&2
fi' EXIT
"$cleanup_binary" --print-mapping > "$mapping_backup"
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
/usr/bin/hidutil property --set "$(cat "$mapping_backup")" >/dev/null
"$cleanup_binary" --clear-mapping
rm -f "$agent_path"
rm -rf "$app_path" "$support_dir"

printf '%s\n' "Uninstalled. Right Command and Right Alt have been restored."
