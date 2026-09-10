#!/bin/bash
#
# Installs everything the Claude effort panel needs outside the plugin folder:
# the sync script on PATH, the systemd watcher, and the Claude Code settings
# (base effort pinned to max, hooks that refresh usage). Safe to re-run.
#
# Run it from the plugin folder after `omarchy plugin add`:
#   ~/.config/omarchy/plugins/io.github.gmantoha.claude-effort/install.sh

set -euo pipefail

PLUGIN_ID="io.github.gmantoha.claude-effort"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bin_dir="$HOME/.local/bin"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"

for tool in jq systemctl; do
  command -v "$tool" >/dev/null || { echo "install.sh: $tool is required" >&2; exit 1; }
done

mkdir -p "$bin_dir" "$unit_dir" "$(dirname "$settings")"

# A symlink, so `omarchy plugin update` updates the script along with the panel.
ln -sfn "$here/bin/claude-effort-sync" "$bin_dir/claude-effort-sync"
install -m 644 "$here/systemd/claude-effort-sync.path" "$here/systemd/claude-effort-sync.service" "$unit_dir/"

# Claude Code: pin the base effort to max and refresh usage after every turn
# and at session start. Existing hooks and env entries are kept.
[[ -s $settings ]] || echo '{}' >"$settings"
cp -a "$settings" "$settings.bak.$(date +%Y%m%d-%H%M%S)"
hook='setsid -f nice -n 10 "$HOME/.local/bin/claude-effort-sync" --refresh >/dev/null 2>&1 </dev/null; exit 0'
tmp=$(mktemp "$(dirname "$settings")/.settings.json.XXXXXX")
jq --arg cmd "$hook" '
  def mine: {type: "command", command: $cmd, timeout: 10};
  def strip: map(select(((.hooks // []) | map(.command // "") | any(contains("claude-effort-sync"))) | not));
  .env = ((.env // {}) + {CLAUDE_CODE_EFFORT_LEVEL: "max"})
  | .hooks.SessionStart = (((.hooks.SessionStart // []) | strip) + [{matcher: "*", hooks: [mine]}])
  | .hooks.Stop = (((.hooks.Stop // []) | strip) + [{hooks: [mine]}])
' "$settings" >"$tmp" && mv "$tmp" "$settings"

systemctl --user daemon-reload
systemctl --user enable --now claude-effort-sync.path

# Put the widget in the bar next to the Agents icon when it is not there yet.
if command -v omarchy >/dev/null; then
  shell_json="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
  if ! jq -e --arg id "$PLUGIN_ID" '[.bar.layout // {} | to_entries[] | .value | arrays | .[] | objects | select(.id == $id)] | length > 0' "$shell_json" >/dev/null 2>&1; then
    omarchy plugin enable "$PLUGIN_ID" --after omarchy.agents || omarchy plugin enable "$PLUGIN_ID" --section right || true
  fi
fi

"$bin_dir/claude-effort-sync" --quiet || true
echo "Claude effort installed. Cap now: $(jq -r '.maxEffortLevel // "unset"' "$settings")"
