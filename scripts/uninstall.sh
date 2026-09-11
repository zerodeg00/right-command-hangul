#!/bin/sh
set -eu

support_dir="$HOME/Library/Application Support/RightCommandHangul"
app_path="$HOME/Applications/Right Command Hangul.app"
binary_path="$app_path/Contents/MacOS/right-command-hangul"
legacy_binary="$support_dir/right-command-hangul"
agent_path="$HOME/Library/LaunchAgents/com.github.right-command-hangul.plist"
label="com.github.right-command-hangul"
user_id=$(id -u)

launchctl bootout "gui/$user_id/$label" >/dev/null 2>&1 || true
if [ -x "$binary_path" ]; then
  "$binary_path" --clear-mapping
elif [ -x "$legacy_binary" ]; then
  "$legacy_binary" --clear-mapping
else
  /usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
fi
rm -f "$agent_path"
rm -rf "$app_path" "$support_dir"

printf '%s\n' "Uninstalled. Right Command and Right Alt have been restored."
