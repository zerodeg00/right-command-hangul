#!/bin/sh
set -eu

install_dir="$HOME/Library/Application Support/RightCommandHangul"
agent_path="$HOME/Library/LaunchAgents/com.github.right-command-hangul.plist"
label="com.github.right-command-hangul"
user_id=$(id -u)

launchctl bootout "gui/$user_id/$label" >/dev/null 2>&1 || true
if [ -x "$install_dir/right-command-hangul" ]; then
  "$install_dir/right-command-hangul" --clear-mapping
else
  /usr/bin/hidutil property --set '{"UserKeyMapping":[]}' >/dev/null
fi
rm -f "$agent_path"
rm -rf "$install_dir"

printf '%s\n' "Uninstalled. Right Command and Right Alt have been restored."
