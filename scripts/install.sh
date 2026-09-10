#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir="$project_dir/build"
install_dir="$HOME/Library/Application Support/RightCommandHangul"
agent_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/RightCommandHangul"
binary_path="$install_dir/right-command-hangul"
agent_path="$agent_dir/com.github.right-command-hangul.plist"
label="com.github.right-command-hangul"
user_id=$(id -u)

mkdir -p "$build_dir" "$install_dir" "$agent_dir" "$log_dir"

clang \
  -fobjc-arc \
  -Wall -Wextra -Werror -O2 \
  -framework Foundation \
  -framework Carbon \
  -framework ApplicationServices \
  "$project_dir/src/right-command-hangul.m" \
  -o "$build_dir/right-command-hangul"

install -m 0755 "$build_dir/right-command-hangul" "$binary_path"
cp "$project_dir/launchagents/com.github.right-command-hangul.plist" "$agent_path"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $binary_path" "$agent_path"
plutil -replace StandardOutPath -string "$log_dir/right-command-hangul.log" "$agent_path"
plutil -replace StandardErrorPath -string "$log_dir/right-command-hangul.log" "$agent_path"

launchctl bootout "gui/$user_id/$label" >/dev/null 2>&1 || true
sleep 1
launchctl bootstrap "gui/$user_id" "$agent_path"

printf '%s\n' "Installed. Right Command now switches between Korean and Latin input sources."
