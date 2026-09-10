#!/bin/bash
#
# Reverses install.sh: removes the watcher, the script link, the Claude Code
# hooks and the effort pin, and takes the widget out of the bar. The plugin
# folder itself is removed with `omarchy plugin remove io.github.gmantoha.claude-effort`.

set -euo pipefail

PLUGIN_ID="io.github.gmantoha.claude-effort"
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-effort-sync"

systemctl --user disable --now claude-effort-sync.path 2>/dev/null || true
rm -f "$unit_dir/claude-effort-sync.path" "$unit_dir/claude-effort-sync.service"
systemctl --user daemon-reload
rm -f "$bin_dir/claude-effort-sync"
rm -rf "$state_dir"

if [[ -s $settings ]] && command -v jq >/dev/null; then
  cp -a "$settings" "$settings.bak.$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp "$(dirname "$settings")/.settings.json.XXXXXX")
  jq '
    def strip: map(select(((.hooks // []) | map(.command // "") | any(contains("claude-effort-sync"))) | not));
    del(.maxEffortLevel)
    | (if .env then .env |= del(.CLAUDE_CODE_EFFORT_LEVEL) else . end)
    | (if .hooks.SessionStart then .hooks.SessionStart |= strip else . end)
    | (if .hooks.Stop then .hooks.Stop |= strip else . end)
  ' "$settings" >"$tmp" && mv "$tmp" "$settings"
fi

command -v omarchy >/dev/null && omarchy plugin disable "$PLUGIN_ID" 2>/dev/null || true
echo "Claude effort removed. Delete the plugin folder with: omarchy plugin remove $PLUGIN_ID"
