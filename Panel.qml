import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Claude effort: the tier claude-effort-sync is holding Claude Code at, the
// session usage that decides it, and the thresholds between the tiers.
//
// The panel is a display plus a settings editor. The decision itself lives in
// ~/.local/bin/claude-effort-sync, which reads the thresholds off this
// widget's shell.json entry and leaves a state record for the panel to draw.
Panel {
  id: root
  moduleName: "io.github.gmantoha.claude-effort"
  ipcTarget: "io.github.gmantoha.claude-effort"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string statePath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/claude-effort-sync/state.json"
  readonly property string syncCommand: home + "/.local/bin/claude-effort-sync"

  readonly property var tiers: ["max", "xhigh", "high", "medium"]
  readonly property var thresholdKeys: ["xhighAt", "highAt", "mediumAt"]

  property var state: null
  property double nowMs: Date.now()
  property bool cursorActive: false
  // 0 is the automation switch in the hero, 1..3 the threshold rows.
  property int cursor: 0
  // Thresholds shown while a slider drags.
  property var liveThresholds: null
  // Edits the shell has not handed back through `settings` yet. Every write
  // is built on top of these, so a second change made before the first one
  // round-trips cannot resurrect the old value.
  property var pendingChanges: ({})
  property bool refreshing: false

  readonly property bool automationOn: String(effective("automation", "On")).toLowerCase() !== "off"
  readonly property var thresholds: liveThresholds || {
    xhighAt: pct(effective("xhighAt", 30)),
    highAt: pct(effective("highAt", 60)),
    mediumAt: pct(effective("mediumAt", 80))
  }
  readonly property real percent: state && state.percent !== null && state.percent !== undefined
    && isFinite(Number(state.percent)) ? Number(state.percent) : -1
  readonly property string tier: state ? String(state.tier || "") : ""
  readonly property string status: state ? String(state.status || "") : ""
  readonly property bool alarming: automationOn && tier === "medium"

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
  function pct(v) { return Math.round(clamp(Number(v), 0, 100)) }

  function effective(name, fallback) {
    return pendingChanges[name] !== undefined ? pendingChanges[name] : setting(name, fallback)
  }

  // Once the saved entry carries a pending value, the override has done its job.
  onSettingsChanged: {
    var remaining = {}
    var dropped = false
    for (var key in pendingChanges) {
      if (JSON.stringify(settings ? settings[key] : undefined) === JSON.stringify(pendingChanges[key])) dropped = true
      else remaining[key] = pendingChanges[key]
    }
    if (dropped) pendingChanges = remaining
  }

  // ------------------------------------------------------------ thresholds
  //
  // The three thresholds are a ladder: dragging one past its neighbour pushes
  // the neighbour along instead of letting the ladder cross itself.
  function adjusted(key, value) {
    var t = { xhighAt: thresholds.xhighAt, highAt: thresholds.highAt, mediumAt: thresholds.mediumAt }
    var v = pct(value)
    t[key] = v
    if (key === "xhighAt") {
      t.highAt = Math.max(t.highAt, v)
      t.mediumAt = Math.max(t.mediumAt, t.highAt)
    } else if (key === "highAt") {
      t.xhighAt = Math.min(t.xhighAt, v)
      t.mediumAt = Math.max(t.mediumAt, v)
    } else {
      t.highAt = Math.min(t.highAt, v)
      t.xhighAt = Math.min(t.xhighAt, t.highAt)
    }
    return t
  }

  function previewThreshold(key, value) { liveThresholds = adjusted(key, value) }

  function commitThreshold(key, value) {
    var next = adjusted(key, value)
    liveThresholds = null
    persist({ xhighAt: next.xhighAt, highAt: next.highAt, mediumAt: next.mediumAt })
  }

  function setAutomation(on) {
    persist({ automation: on ? "On" : "Off" })
  }

  // Changes queue up and go out in one write, so a run of h/l nudges is one
  // shell.json rewrite rather than one per keypress.
  function persist(changes) {
    var merged = {}
    for (var key in pendingChanges) merged[key] = pendingChanges[key]
    for (var changed in changes) merged[changed] = changes[changed]
    pendingChanges = merged
    persistDebounce.restart()
    syncDebounce.restart()
  }

  // Writes back through the shell so the change lands on this widget's inline
  // entry in shell.json, the same place `omarchy bar set` writes.
  function flushPersist() {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") {
      console.warn("claude-effort", "No shell facade to save settings through")
      return false
    }
    var entry = { id: root.moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    for (var pending in pendingChanges) entry[pending] = pendingChanges[pending]
    return root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // The sync script re-reads shell.json itself, but the values ride along
  // explicitly so a run that beats the shell's write still applies them.
  function runSync(refresh) {
    var t = root.thresholds
    var args = [root.syncCommand, "--thresholds", t.xhighAt + "," + t.highAt + "," + t.mediumAt,
                "--automation", root.automationOn ? "on" : "off"]
    if (refresh) args.push("--refresh")
    else args.push("--quiet")
    Quickshell.execDetached(args)
    stateReload.restart()
  }

  function refreshNow() {
    refreshing = true
    refreshTimeout.restart()
    runSync(true)
  }

  function nudge(dx) {
    if (cursor === 0) { setAutomation(!automationOn); return }
    var key = thresholdKeys[cursor - 1]
    commitThreshold(key, thresholds[key] + dx * 5)
  }

  function activateCursor() {
    if (cursor === 0) setAutomation(!automationOn)
    else refreshNow()
  }

  // --------------------------------------------------------------- content

  function resetMs() {
    if (!state || String(state.resetsAt || "") === "") return -1
    var ms = new Date(String(state.resetsAt)).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function ageMs(iso) {
    if (String(iso || "") === "") return -1
    var ms = new Date(String(iso)).getTime()
    return isFinite(ms) ? Math.max(0, root.nowMs - ms) : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  function formatAge(ms) {
    if (ms < 0) return ""
    if (ms < 60000) return "just now"
    return formatDuration(ms) + " ago"
  }

  function heroMeta() {
    if (!automationOn) return "Automation off · max"
    if (status === "no-data" || percent < 0) return "Waiting for usage data"
    return "Session " + Math.round(percent) + "% · cap " + (tier === "max" ? "none" : tier)
  }

  function usageDetail() {
    var parts = []
    var reset = resetMs()
    if (reset > 0) parts.push("Resets in " + formatDuration(reset))
    var age = state ? formatAge(ageMs(state.usageUpdatedAt)) : ""
    if (age !== "") parts.push("usage as of " + age)
    return parts.join(" · ")
  }

  function tierLabel(index) {
    if (index === 0) return "max"
    return tiers[index] + " " + thresholds[thresholdKeys[index - 1]] + "%"
  }

  function tooltip() {
    if (!automationOn) return "Claude effort: automation off"
    if (tier === "") return "Claude effort"
    return "Claude effort: " + tier + (percent >= 0 ? " · session " + Math.round(percent) + "%" : "")
  }

  function footerText() {
    if (refreshing) return "Refreshing usage…"
    var age = state ? formatAge(ageMs(state.updatedAt)) : ""
    return (age !== "" ? "Synced " + age + " · " : "") + "r refresh · h/l adjust"
  }

  function parseState(content) {
    try {
      var parsed = JSON.parse(String(content || ""))
      root.state = parsed && typeof parsed === "object" ? parsed : null
    } catch (e) {
      console.warn("claude-effort", "Ignoring bad state file", root.statePath, e)
      root.state = null
    }
    root.refreshing = false
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    stateFile.reload()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parseState(text())
    onLoadFailed: root.state = null
  }

  Timer {
    id: persistDebounce
    interval: 150
    repeat: false
    onTriggered: root.flushPersist()
  }

  Timer {
    id: syncDebounce
    interval: 400
    repeat: false
    onTriggered: root.runSync(false)
  }

  // The state file usually announces itself through the watcher; this covers
  // the first run, when the file did not exist to be watched.
  Timer {
    id: stateReload
    interval: 1500
    repeat: false
    onTriggered: stateFile.reload()
  }

  Timer {
    id: refreshTimeout
    interval: 20000
    repeat: false
    onTriggered: root.refreshing = false
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    // omarchy-shell io.github.gmantoha.claude-effort setThreshold highAt 70
    function setThreshold(key: string, value: string): string {
      if (root.thresholdKeys.indexOf(key) < 0) return "unknown threshold: " + key
      var n = Number(value)
      if (!isFinite(n)) return "not a number: " + value
      root.commitThreshold(key, n)
      return "ok"
    }
    // omarchy-shell io.github.gmantoha.claude-effort status
    function status(): string {
      return JSON.stringify({
        automationOn: root.automationOn, thresholds: root.thresholds, pendingChanges: root.pendingChanges,
        tier: root.tier, percent: root.percent, settings: root.settings
      })
    }
    // omarchy-shell io.github.gmantoha.claude-effort automation off
    function automation(mode: string): string {
      var m = String(mode || "").toLowerCase()
      if (m !== "on" && m !== "off" && m !== "toggle") return "expected on, off, or toggle"
      root.setAutomation(m === "toggle" ? !root.automationOn : m === "on")
      return "ok"
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓅"
    active: root.alarming
    tooltipText: root.tooltip()
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.bar) root.bar.run("omarchy-shell omarchy.agents toggle") }
      else if (buttonCode === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        root.cursorActive = true
        if (dy !== 0) root.cursor = root.clamp(root.cursor + dy, 0, 3)
        if (dx !== 0) root.nudge(dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refreshNow() }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Hero: glyph · name · tier pill · automation switch ----------
        PanelHero {
          width: parent.width
          title: "Claude effort"
          detail: root.automationOn ? root.tier : "max"
          meta: root.heroMeta()
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: button.text
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            ToggleSwitch {
              checked: root.automationOn
              hasCursor: root.cursorActive && root.cursor === 0
              foreground: root.foreground
              onToggled: root.setAutomation(!root.automationOn)
              onHovered: function(isHovered) {
                if (isHovered) { root.cursorActive = true; root.cursor = 0 }
              }
            }
          }
        }

        // ---------- Session usage ----------
        PanelSeparator { foreground: root.foreground }

        Column {
          id: usageSection
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            width: parent.width
            text: "SESSION USAGE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Item {
            width: parent.width
            implicitHeight: Math.max(usageLabel.implicitHeight, usageValue.implicitHeight)

            Text {
              id: usageLabel
              textFormat: Text.PlainText
              text: "Session (5-hour)"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: usageValue
              textFormat: Text.PlainText
              text: root.percent >= 0 ? Math.round(root.percent) + "%" : "—"
              color: root.alarming ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          // The meter carries the thresholds as notches, so the distance to
          // the next tier is visible without reading the numbers.
          Item {
            id: meter
            width: parent.width
            implicitHeight: Style.space(14)
            readonly property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

            Rectangle {
              id: meterTrack
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: meter.thickness
              radius: height / 2
              color: root.track
            }

            Rectangle {
              anchors.left: meterTrack.left
              anchors.verticalCenter: meterTrack.verticalCenter
              height: meterTrack.height
              radius: meterTrack.radius
              width: meterTrack.width * root.clamp(root.percent / 100, 0, 1)
              color: root.alarming ? root.urgent : root.foreground

              Behavior on width {
                NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
              }
            }

            Repeater {
              model: root.thresholdKeys

              Rectangle {
                required property var modelData
                width: Math.max(2, Style.space(2))
                height: meter.thickness + Style.space(6)
                radius: 1
                color: root.alpha(root.foreground, 0.6)
                anchors.verticalCenter: meterTrack.verticalCenter
                x: root.clamp(meterTrack.width * root.thresholds[modelData] / 100 - width / 2, 0, meterTrack.width - width)

                Behavior on x {
                  enabled: !root.liveThresholds
                  NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                }
              }
            }
          }

          Row {
            id: ladder
            width: parent.width

            Repeater {
              model: root.tiers

              Text {
                required property var modelData
                required property int index
                readonly property bool current: root.automationOn ? modelData === root.tier : index === 0

                width: ladder.width / root.tiers.length
                textFormat: Text.PlainText
                text: root.tierLabel(index)
                color: current ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: current
                horizontalAlignment: index === 0 ? Text.AlignLeft : (index === root.tiers.length - 1 ? Text.AlignRight : Text.AlignHCenter)
                elide: Text.ElideRight
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: root.usageDetail()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        // ---------- Thresholds ----------
        PanelSeparator { foreground: root.foreground }

        Column {
          id: thresholdSection
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            width: parent.width
            text: "EFFORT THRESHOLDS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          ThresholdRow { width: parent.width; index: 1; key: "xhighAt"; label: "xhigh from" }
          ThresholdRow { width: parent.width; index: 2; key: "highAt"; label: "high from" }
          ThresholdRow { width: parent.width; index: 3; key: "mediumAt"; label: "medium from" }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Below the first threshold Claude runs at max. Changes apply to running sessions on their next request."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          topPadding: Style.space(2)
          text: root.footerText()
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          elide: Text.ElideRight
        }
      }
    }
  }

  // One threshold: name and value above a slider. Hovering or dragging moves
  // the keyboard cursor here so h/l keep adjusting the same row.
  component ThresholdRow: Column {
    id: row
    property string key: ""
    property string label: ""
    property int index: 0
    readonly property int value: Number(root.thresholds[key])
    readonly property bool hasCursor: root.cursorActive && root.cursor === index

    spacing: Style.space(2)

    Item {
      width: parent.width
      implicitHeight: Math.max(nameText.implicitHeight, valueText.implicitHeight)

      Text {
        id: nameText
        textFormat: Text.PlainText
        text: row.label
        color: row.hasCursor ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.hasCursor
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: valueText
        textFormat: Text.PlainText
        text: row.value + "%"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    PanelSlider {
      width: parent.width
      bar: root.bar
      minimum: 0
      maximum: 100
      step: 5
      integer: true
      value: row.value
      onMoved: function(v) {
        root.cursorActive = true
        root.cursor = row.index
        root.previewThreshold(row.key, v)
      }
      onReleased: function(v) { root.commitThreshold(row.key, v) }
    }

    // Hover only: the slider owns the clicks, the handler just moves the cursor.
    HoverHandler {
      onHoveredChanged: if (hovered) { root.cursorActive = true; root.cursor = row.index }
    }
  }
}
