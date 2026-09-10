# Claude effort for Omarchy

A bar panel for [Omarchy](https://omarchy.org/) that steers
[Claude Code](https://code.claude.com/)'s effort level from your Claude
session usage: full effort while the 5-hour window is fresh, gradually lower
as it fills up. Running sessions follow along without a restart.

| Session usage      | Effort |
|--------------------|--------|
| below 30 %         | max    |
| 30 % to 59 %       | xhigh  |
| 60 % to 79 %       | high   |
| 80 % and up        | medium |

The thresholds are sliders in the panel. The panel sits next to Omarchy's
Agents panel and shows the current tier, the session meter with the
thresholds as notches, and the time until the window resets.

## How it works

- Omarchy's Agents panel already collects Claude's rate limits with
  `omarchy agent usage-update`. `bin/claude-effort-sync` reads the
  "Session (5-hour)" percentage from that record and writes a matching
  `maxEffortLevel` cap into `~/.claude/settings.json`.
- Claude Code watches its settings file and applies the cap before every
  request, so an open session changes tier on its next message. The base
  effort is pinned to `max` through the `CLAUDE_CODE_EFFORT_LEVEL` env entry
  in the same file, because the settings keys themselves don't accept `max`.
- A systemd user path unit reruns the sync whenever Omarchy rewrites the
  usage record, and two Claude Code hooks (Stop and SessionStart) refresh the
  usage in the background so the number is at most one turn old.
- The panel is a display plus a settings editor. Thresholds live on the
  widget's entry in `~/.config/omarchy/shell.json`, where the sync script
  reads them.

## Requirements

- Omarchy with the Omarchy shell and the Agents panel (Claude signed in).
- Claude Code 2.1.267 or later (`maxEffortLevel` support).
- `jq`.

## Install

```bash
omarchy plugin add https://github.com/gmantoha/omarchy-claude-effort.git --enable
~/.config/omarchy/plugins/io.github.gmantoha.claude-effort/install.sh
```

`install.sh` links the sync script into `~/.local/bin`, installs and starts
the systemd watcher, adds the env entry and hooks to `~/.claude/settings.json`
(a timestamped backup is kept), and places the widget after the Agents icon.
Later updates come through `omarchy plugin update`.

Without `omarchy plugin add`, clone the repo into
`~/.config/omarchy/plugins/io.github.gmantoha.claude-effort` and run the same
`install.sh`.

## Using the panel

- Left click the bar icon to open the panel, middle click to refresh usage,
  right click to open the Agents panel. Tab switches between the two panels.
- The switch in the header turns the automation off; Claude then runs at max.
- Drag the sliders, or use `j`/`k` to pick a row and `h`/`l` to move it by
  five points. Dragging a threshold past its neighbor pushes the neighbor
  along. `r` refreshes usage, `Esc` closes.

The same controls are available over IPC and `omarchy bar set`:

```bash
omarchy-shell io.github.gmantoha.claude-effort setThreshold highAt 70
omarchy-shell io.github.gmantoha.claude-effort automation off      # on | off | toggle
omarchy-shell io.github.gmantoha.claude-effort refresh
omarchy-shell io.github.gmantoha.claude-effort status
omarchy bar set io.github.gmantoha.claude-effort xhighAt 35 --json
```

The sync script can be driven directly too:

```bash
claude-effort-sync --dry-run                 # current usage and tier
claude-effort-sync --dry-run --percent 85    # try the mapping
claude-effort-sync --refresh                 # refresh usage, then apply
journalctl --user -u claude-effort-sync.service -f
```

## What `install.sh` touches

Everything runs as your user; nothing needs root.

- `~/.local/bin/claude-effort-sync`: a symlink to `bin/claude-effort-sync` in the plugin folder.
- `~/.config/systemd/user/claude-effort-sync.{path,service}`: the watcher on Omarchy's usage record.
- `~/.claude/settings.json`: adds `env.CLAUDE_CODE_EFFORT_LEVEL`, a `Stop` hook and a `SessionStart` hook, and from then on the sync script maintains `maxEffortLevel`. A timestamped backup is written first.
- `~/.config/omarchy/shell.json`: the widget entry with the thresholds, written by `omarchy plugin enable` and by the panel.
- `~/.local/state/claude-effort-sync/state.json`: the record the panel displays.

The sync script calls `omarchy agent usage-update --limits-only claude`, which is Omarchy's own collector; it is what contacts Anthropic's usage endpoint. Nothing else touches the network. Dependencies: `jq`, `systemd --user`, and the Omarchy shell.

## Things to know

- `CLAUDE_CODE_EFFORT_LEVEL` overrides `/effort`, so manual effort picks in a
  session no longer stick while the automation is installed. Turn the
  automation off in the panel to run at max, or remove the env entry to get
  manual control back (then `max` is only reachable with `--effort max`).
- When a cap is active, Claude Code prints a one-line notice such as
  `Effort 'xhigh' exceeds the cap ... using 'medium'`.
- If the usage record still describes a window that has already reset, the
  sync refreshes it and otherwise treats the new window as empty.
- After editing the plugin's QML, run `omarchy restart shell`; the shell does
  not always swap a running bar widget for the edited one.

## Development

`qmllint` ships with `qt6-declarative` but is not on PATH. The shell's
`qs.*` modules resolve through a directory that contains a `qs` link to the
shell root:

```bash
mkdir -p /tmp/qmlroot && ln -sfn "$OMARCHY_PATH/shell" /tmp/qmlroot/qs
/usr/lib/qt6/bin/qmllint -I /tmp/qmlroot -I "$OMARCHY_PATH/shell" Panel.qml
omarchy plugin validate .
```

The remaining `unqualified` and `missing-property` warnings come from the
shell's dynamic `Style` singleton and inline components; the stock Agents
panel reports the same ones.

## Uninstall

```bash
~/.config/omarchy/plugins/io.github.gmantoha.claude-effort/uninstall.sh
omarchy plugin remove io.github.gmantoha.claude-effort
```

## License

MIT, see [LICENSE](LICENSE).
