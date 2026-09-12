import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.codemonkey76.batch"
  ipcTarget: "io.github.codemonkey76.batch"
  manageIpc: false

  // ---- Helper ---------------------------------------------------------------
  // Everything happens through the bundled helper: it enumerates the files,
  // runs the script, and owns the state file a batch survives a shell restart
  // in. The interpreter is named outright and the helper is resolved relative
  // to this file, so nothing this widget runs comes off PATH.
  readonly property string python: "/usr/bin/python3"
  readonly property string cli: String(Qt.resolvedUrl("omarchy-batch")).replace(/^file:\/\//, "")
  function helperArgs(args) { return [root.python, "-I", root.cli].concat(args) }

  readonly property string home: Quickshell.env("HOME") || ""

  // A closed environment: enough for the helper to find the session and its
  // state directory, and nothing else the shell happens to be carrying.
  readonly property var helperEnv: {
    var env = { "PATH": "/usr/local/bin:/usr/bin:/bin", "LC_ALL": "C.UTF-8" }
    var keys = ["HOME", "USER", "LOGNAME", "XDG_RUNTIME_DIR", "XDG_SESSION_TYPE",
                "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
                "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY"]
    for (var i = 0; i < keys.length; i++) {
      var value = Quickshell.env(keys[i])
      if (value) env[keys[i]] = value
    }
    return env
  }

  // ---- Settings -------------------------------------------------------------
  readonly property int refreshSeconds: Math.max(5, parseInt(setting("refreshIntervalSec", 30), 10) || 30)
  readonly property string scriptsDirSetting: String(setting("scriptsDir", "") || "")
  readonly property string extensionsSetting: String(setting("extensions", "") || "")
  readonly property int fileTimeoutMinutes: Math.max(1, parseInt(setting("fileTimeoutMinutes", 360), 10) || 360)
  readonly property bool notifySetting: String(setting("notify", true)) !== "false"

  // ---- State ----------------------------------------------------------------
  property var job: null
  property var config: null
  property var scripts: []
  property var scan: null
  property string message: ""
  property real nowSec: Date.now() / 1000

  // Not a path, so it cannot collide with a real script.
  readonly property string browseSentinel: "browse:"

  readonly property bool running: Model.isRunning(job)
  readonly property bool busy: actionProc.running || pickProc.running
  readonly property string inputDir: config ? String(config.input || "") : ""
  readonly property string outputDir: config ? String(config.output || "") : ""
  readonly property string scriptPath: config ? String(config.script || "") : ""
  readonly property bool skipExisting: config ? config.skipExisting !== false : true
  readonly property bool startable: !running && !busy
    && inputDir !== "" && outputDir !== "" && scriptPath !== ""

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string barIcon: Model.icon(job)
  readonly property string pillText: Model.barText(job)
  readonly property string tooltipText: Model.tooltip(job, scan, nowSec)

  readonly property var scriptOptions: {
    var options = []
    var found = false
    for (var i = 0; i < scripts.length; i++) {
      var entry = scripts[i]
      if (entry.path === root.scriptPath) found = true
      options.push({ value: entry.path, label: Model.scriptLabel(entry) })
    }
    // A script chosen with the file picker lives outside the scripts folder; it
    // still has to appear, or the dropdown would quietly misreport what the
    // next run is going to use.
    if (root.scriptPath !== "" && !found) {
      options.push({ value: root.scriptPath, label: Model.homePath(root.scriptPath, root.home) })
    }
    options.push({ value: root.browseSentinel, label: "Browse…" })
    return options
  }

  // ---- Reading --------------------------------------------------------------
  function applyReply(text) {
    var reply = Model.parseLine(text)
    if (!reply) return

    if (reply.error) root.message = String(reply.error)
    else if (reply.ok !== false) root.message = ""

    // Replies are told apart by shape: a job carries a state, a scan carries a
    // pending count, a config carries the folders.
    if (reply.state !== undefined) root.job = reply
    else if (reply.scripts !== undefined) root.scripts = reply.scripts
    else if (reply.pending !== undefined) root.scan = reply
    else if (reply.input !== undefined) { root.config = reply; root.rescan() }
  }

  function refresh() {
    if (statusProc.running) return
    statusProc.command = root.helperArgs(["status"])
    statusProc.running = true
  }

  function reloadConfig() {
    if (configProc.running) return
    configProc.command = root.helperArgs(["config"])
    configProc.running = true
  }

  function reloadScripts() {
    if (scriptsProc.running) return
    scriptsProc.command = root.helperArgs(["scripts"])
    scriptsProc.running = true
  }

  function rescan() {
    if (scanProc.running) return
    scanProc.command = root.helperArgs(["scan"])
    scanProc.running = true
  }

  // ---- Writing --------------------------------------------------------------
  function act(args) {
    if (actionProc.running) return
    actionProc.command = root.helperArgs(args)
    actionProc.running = true
  }

  function pick(what) {
    if (pickProc.running) return
    root.message = ""
    pickProc.command = root.helperArgs(["pick", what])
    pickProc.running = true
  }

  function chooseScript(value) {
    if (value === root.browseSentinel) { root.pick("script"); return }
    if (value === root.scriptPath || value === "") return
    root.act(["set", "script", value])
  }

  function toggleSkip() { root.act(["set", "skipExisting", root.skipExisting ? "false" : "true"]) }

  // These deliberately do not re-check `startable` and friends. The helper
  // validates against the config as it is on disk; this panel only knows what
  // it last read, which goes stale the moment anything changes elsewhere. A
  // second, staler opinion here turns an IPC call or a keybind into silence
  // instead of an error. The buttons stay disabled in the UI regardless.
  function start() { root.act(["start"]) }
  function cancel() { root.act(["cancel"]) }
  function clearJob() { root.act(["clear"]) }
  function openOutput() { root.act(["open", "output"]) }
  function openLog() { root.act(["open", "log"]) }

  // The widget's settings and the helper's stored config are the same values
  // seen from two places; push them down whenever the shell's copy changes.
  function pushSettings() {
    if (settingsProc.running) return
    settingsProc.command = root.helperArgs(["configure",
      "scriptsDir=" + root.scriptsDirSetting,
      "extensions=" + root.extensionsSetting,
      "fileTimeoutSec=" + (root.fileTimeoutMinutes * 60),
      "notify=" + (root.notifySetting ? "true" : "false")])
    settingsProc.running = true
  }

  onSettingsChanged: pushSettings()

  // Dropdown writes its own `value` when an option is picked, which replaces
  // the binding to the helper's copy. Re-assert it whenever the stored script
  // changes, or the panel would keep showing the first thing ever chosen.
  onScriptPathChanged: scriptDropdown.value = root.scriptPath

  Component.onCompleted: {
    pushSettings()
    reloadConfig()
    reloadScripts()
    refresh()
  }

  onOpenedChanged: {
    if (!opened) return
    reloadConfig()
    reloadScripts()
    refresh()
  }

  // ---- Processes ------------------------------------------------------------
  // Every reply is one line of JSON, read a line at a time under a length
  // ceiling — a collector would buffer whatever a malfunctioning helper felt
  // like producing.
  component Helper: Process {
    property int deadlineSeconds: 20
    property real startedAt: 0
    clearEnvironment: true
    environment: root.helperEnv
    onRunningChanged: startedAt = running ? Date.now() : 0
  }

  readonly property var helpers: [statusProc, configProc, scriptsProc, scanProc,
                                  actionProc, pickProc, settingsProc]

  Helper {
    id: statusProc
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
  }

  Helper {
    id: configProc
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
  }

  Helper {
    id: scriptsProc
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
  }

  Helper {
    id: scanProc
    // A first scan of a large, cold library is slow in a way a status poll
    // never is; the deadline has to allow for the disk, not the helper.
    deadlineSeconds: 180
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
  }

  Helper {
    id: actionProc
    deadlineSeconds: 30
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
    onExited: {
      root.refresh()
      root.reloadConfig()
    }
  }

  Helper {
    id: pickProc
    // The portal dialog stays open for as long as the user wants to browse;
    // the helper gives up on it at 600 seconds, so this has to outlast that.
    deadlineSeconds: 630
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
    onExited: {
      root.reloadScripts()
      // Cancelling the chooser changes nothing, so onScriptPathChanged never
      // fires and the dropdown would sit there reading "Browse…".
      scriptDropdown.value = root.scriptPath
    }
  }

  Helper {
    id: settingsProc
    stdout: SplitParser { onRead: function(line) { root.applyReply(line) } }
    onExited: root.reloadScripts()
  }

  // One watchdog over every helper: Process is not an Item, so it cannot carry
  // a Timer of its own. A call that overruns its deadline is signalled, then
  // killed if that was not enough.
  Timer {
    interval: 1000
    repeat: true
    running: true
    onTriggered: {
      var now = Date.now()
      for (var i = 0; i < root.helpers.length; i++) {
        var proc = root.helpers[i]
        if (!proc.running || proc.startedAt === 0) continue
        var over = (now - proc.startedAt) / 1000 - proc.deadlineSeconds
        if (over > 5) proc.signal(9)
        else if (over > 0) proc.signal(15)
      }
    }
  }

  // Poll hard while a batch runs, gently while someone is watching the panel,
  // and rarely otherwise — the pill still has to notice a batch that was
  // started from a terminal.
  Timer {
    interval: root.running ? 1000 : (root.opened ? 5000 : root.refreshSeconds * 1000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Elapsed and ETA are computed here rather than sent, so they tick smoothly
  // between polls instead of stepping once a second late.
  Timer {
    interval: 1000
    running: root.running || root.opened
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.codemonkey76.batch"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function start(): void { root.start() }
    function cancel(): void { root.cancel() }
    function refresh(): void { root.refresh() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.pillText
    slotSize: Style.bar.statusSlot
    tooltipText: root.opened ? "" : root.tooltipText
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
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
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "s") root.start()
        else if (key === "c") root.cancel()
        else if (key === "o") root.openOutput()
        else if (key === "l") root.openLog()
        else if (key === "r") { root.rescan(); root.refresh() }
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(14)

        // ---------- Hero: icon, name, state, actions ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight,
                                   heroActions.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.barIcon
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: root.running ? 1.0 : 0.6
          }

          Row {
            id: heroActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: ""
              tooltipText: "Open output folder"
              foreground: root.fg
              fontFamily: root.fontFamily
              enabled: root.outputDir !== ""
              opacity: enabled ? 1.0 : 0.35
              onClicked: root.openOutput()
            }

            PanelActionButton {
              iconText: ""
              tooltipText: "Open log"
              foreground: root.fg
              fontFamily: root.fontFamily
              onClicked: root.openLog()
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroActions.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Batch"
              textFormat: Text.PlainText
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: Model.summary(root.job, root.scan, root.nowSec)
              color: root.fg
              opacity: 0.7
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- Folders ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "FOLDERS"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Repeater {
            model: [
              { key: "input", caption: "Input", path: root.inputDir },
              { key: "output", caption: "Output", path: root.outputDir }
            ]

            Item {
              id: folderRow
              required property var modelData
              width: column.width
              implicitHeight: Math.max(caption.implicitHeight, pathButton.implicitHeight)

              Text {
                id: caption
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(52)
                text: folderRow.modelData.caption
                color: root.fg
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                id: pathButton
                anchors.left: caption.right
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                leftAlign: true
                bordered: true
                enabled: !root.running
                opacity: enabled ? 1.0 : 0.5
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                text: folderRow.modelData.path
                  ? Model.shortPath(folderRow.modelData.path, root.home, 38)
                  : "Choose…"
                tooltipText: folderRow.modelData.path || "Nothing chosen yet"
                onClicked: root.pick(folderRow.modelData.key)
              }
            }
          }
        }

        // ---------- Script ----------
        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "SCRIPT"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Dropdown {
            id: scriptDropdown
            width: parent.width
            showLabel: false
            enabled: !root.running
            opacity: enabled ? 1.0 : 0.5
            foreground: root.fg
            fontFamily: root.fontFamily
            options: root.scriptOptions
            value: root.scriptPath
            onChanged: function(v) { root.chooseScript(v) }
          }

          Toggle {
            width: parent.width
            label: "Skip files already in output"
            checked: root.skipExisting
            enabled: !root.running
            opacity: enabled ? 1.0 : 0.5
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.toggleSkip()
          }
        }

        PanelSeparator { width: parent.width; foreground: root.fg }

        // ---------- Progress ----------
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.running || Model.isFinished(root.job)

          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)

            Rectangle {
              width: parent.width * Model.progress(root.job)
              height: parent.height
              radius: parent.radius
              color: (root.job && root.job.failed) ? Color.urgent : root.fg
              Behavior on width { NumberAnimation { duration: 200 } }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: text !== ""
            text: (root.running && root.job && root.job.current)
              ? root.job.current + "  ·  " + Model.fmtDuration(root.nowSec - root.job.fileStarted)
              : ""
            color: root.fg
            opacity: 0.7
            elide: Text.ElideMiddle
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            visible: text !== ""
            text: {
              if (!root.job || !root.job.failures || !root.job.failures.length) return ""
              var shown = root.job.failures.slice(-3).join("\n")
              return root.job.failures.length > 3
                ? shown + "\n… and " + (root.job.failures.length - 3) + " more (see log)"
                : shown
            }
            color: Color.urgent
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // ---------- Message ----------
        Text {
          width: parent.width
          textFormat: Text.PlainText
          visible: root.message !== ""
          text: root.message
          color: Color.urgent
          wrapMode: Text.Wrap
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // ---------- Actions ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            bordered: true
            visible: !root.running
            enabled: root.startable
            opacity: enabled ? 1.0 : 0.4
            foreground: root.fg
            fontFamily: root.fontFamily
            iconText: ""
            text: (root.scan && root.scan.pending > 0)
              ? "Process " + root.scan.pending
              : "Start"
            tooltipText: root.startable ? "" : "Choose folders and a script first"
            onClicked: root.start()
          }

          Button {
            bordered: true
            visible: root.running
            foreground: Color.urgent
            fontFamily: root.fontFamily
            iconText: ""
            text: "Cancel"
            onClicked: root.cancel()
          }

          Button {
            bordered: true
            visible: !root.running && Model.isFinished(root.job)
            foreground: root.fg
            fontFamily: root.fontFamily
            text: "Clear"
            onClicked: root.clearJob()
          }
        }
      }
    }
  }
}
