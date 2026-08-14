import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Cam Stream is deliberately self-contained: every process call resolves the
// helper shipped beside this file, so the widget never depends on a command in
// ~/.local/bin or another mutable PATH location.
BarWidget {
  id: root

  moduleName: "io.github.tomdavenport.cam-stream"

  readonly property url helperUrl: Qt.resolvedUrl("bin/cam-stream")
  readonly property string helperPath: root.localPath(helperUrl)

  property bool opened: false
  property bool popoutSwitchClosing: false

  property bool statusLoaded: false
  property bool camerasLoaded: false
  property bool streamRunning: false
  property string activeCamera: ""
  property string preferredCamera: ""
  property bool mirrorEnabled: false
  property string latencyMode: "untimed"
  property string captureFormat: ""
  property string captureSize: ""
  property string captureFps: ""
  property var cameras: []
  property int cameraRevision: 0
  property string cameraChoice: ""

  property string errorMessage: ""
  property string errorSource: ""
  property bool statusRefreshPending: false
  property bool cameraRefreshPending: false

  property var actionQueue: []
  property var currentAction: []
  property string actionStdout: ""
  property string actionStderr: ""

  readonly property bool actionBusy: actionProc.running || currentAction.length > 0 || actionQueue.length > 0
  readonly property bool noCamera: camerasLoaded && cameraOptions.length === 0
  readonly property bool hasError: errorMessage !== ""
  readonly property bool firstLoad: !statusLoaded
  readonly property string stateName: hasError ? "error"
    : noCamera ? "no-camera"
    : streamRunning ? "running"
    : "stopped"
  readonly property string stateTitle: hasError ? "Something went wrong"
    : noCamera ? "No camera found"
    : streamRunning ? "Camera preview is live"
    : "Camera preview is stopped"
  readonly property string stateDetail: hasError ? errorMessage
    : noCamera ? "Connect a V4L2 camera or capture device, then refresh."
    : streamRunning ? root.runningDetail()
    : "Choose an input, then start the preview."
  readonly property string cameraButtonText: firstLoad ? "\uf110"
    : hasError ? "\uf071"
    : noCamera ? "\uf05e"
    : streamRunning ? "\uf03d"
    : "\uf030"
  readonly property string tooltipText: root.tooltipForState()
  readonly property var cameraOptions: {
    root.cameraRevision
    return root.buildCameraOptions()
  }
  readonly property real openPanelIndicatorWidth: Style.bar.iconSlot

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function localPath(value) {
    var text = String(value || "")
    if (text.slice(0, 7) === "file://") text = text.slice(7)
    try { return decodeURIComponent(text) } catch (e) { return text }
  }

  function helperCommand(argumentsList) {
    return [root.helperPath].concat(argumentsList || [])
  }

  function compactError(value, fallback) {
    var text = String(value || "").trim()
    if (!text) text = String(fallback || "Cam Stream command failed")
    text = text.split("\n")[0].replace(/^cam-stream:\s*/, "")
    return text.length > 180 ? text.slice(0, 177) + "…" : text
  }

  function setError(source, message) {
    root.errorSource = source
    root.errorMessage = root.compactError(message, "Cam Stream command failed")
  }

  function clearError(source) {
    if (root.errorSource !== source) return
    root.errorSource = ""
    root.errorMessage = ""
  }

  function cameraName(value) {
    var target = String(value || "")
    if (!target) return "Automatic camera"
    for (var i = 0; i < root.cameras.length; i++) {
      var camera = root.cameras[i]
      if (String(camera.device || "") === target || String(camera.stablePath || "") === target)
        return String(camera.card || camera.device || target)
    }
    var parts = target.split("/")
    return parts[parts.length - 1] || target
  }

  function runningDetail() {
    var mode = root.latencyMode === "smooth" ? "smooth playback" : "realtime"
    var capture = root.captureSize
      ? " · " + root.captureSize + (root.captureFps ? "@" + root.captureFps : "")
      : ""
    return root.cameraName(root.activeCamera) + " · " + mode + capture
      + (root.mirrorEnabled ? " · mirrored" : "")
  }

  function tooltipForState() {
    if (root.firstLoad) return "Cam Stream · Checking camera state"
    if (root.hasError) return "Cam Stream error · " + root.errorMessage + " · Right click for details"
    if (root.noCamera) return "Cam Stream · No camera found · Right click for settings"
    if (root.streamRunning) return "Cam Stream · Live on " + root.cameraName(root.activeCamera) + " · Left click to stop"
    return "Cam Stream · Stopped · Left click to start · Right click for settings"
  }

  function buildCameraOptions() {
    var result = []
    for (var i = 0; i < root.cameras.length; i++) {
      var camera = root.cameras[i]
      if (String(camera.role || "") === "metadata") continue
      var target = String(camera.stablePath || camera.device || "")
      if (!target) continue
      var detail = String(camera.device || target)
      var label = String(camera.card || "Camera") + " · " + detail
      if (camera.busyPids && camera.busyPids.length > 0) label += " (in use)"
      result.push({ value: target, label: label })
    }
    return result
  }

  function selectedCameraTarget() {
    for (var i = 0; i < root.cameras.length; i++) {
      var camera = root.cameras[i]
      if (camera.selected === true) return String(camera.stablePath || camera.device || "")
    }
    if (root.preferredCamera) return root.preferredCamera
    var options = root.buildCameraOptions()
    return options.length > 0 ? String(options[0].value) : ""
  }

  function syncCameraChoice() {
    root.cameraChoice = root.selectedCameraTarget()
    if (cameraDropdown) cameraDropdown.value = root.cameraChoice
    if (latencyDropdown) latencyDropdown.value = root.latencyMode
  }

  function applyStatus(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "").trim())
    } catch (e) {
      return "Status returned invalid JSON"
    }
    if (!data || data.schemaVersion !== 1 || typeof data.running !== "boolean")
      return "Status returned an unsupported response"

    root.streamRunning = data.running === true
    root.activeCamera = data.camera === null || data.camera === undefined ? "" : String(data.camera)
    root.preferredCamera = data.preferredCamera === null || data.preferredCamera === undefined
      ? "" : String(data.preferredCamera)
    root.mirrorEnabled = data.mirror === true
    root.latencyMode = String(data.latencyMode || "untimed") === "smooth" ? "smooth" : "untimed"
    root.captureFormat = data.captureFormat === null || data.captureFormat === undefined
      ? "" : String(data.captureFormat)
    root.captureSize = data.captureSize === null || data.captureSize === undefined
      ? "" : String(data.captureSize)
    root.captureFps = data.captureFps === null || data.captureFps === undefined
      ? "" : String(data.captureFps)
    root.statusLoaded = true
    root.clearError("status")
    Qt.callLater(root.syncCameraChoice)
    return ""
  }

  function applyCameras(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "").trim())
    } catch (e) {
      return "Camera list returned invalid JSON"
    }
    if (!data || data.schemaVersion !== 1 || !Array.isArray(data.cameras))
      return "Camera list returned an unsupported response"

    root.cameras = data.cameras
    root.cameraRevision++
    root.camerasLoaded = true
    root.clearError("cameras")
    Qt.callLater(root.syncCameraChoice)
    return ""
  }

  function refreshStatus() {
    if (statusProc.running) {
      root.statusRefreshPending = true
      return
    }
    statusProc.capturedStdout = ""
    statusProc.capturedStderr = ""
    statusProc.parseError = ""
    statusProc.command = root.helperCommand(["status", "--json"])
    statusProc.running = true
  }

  function refreshCameras() {
    if (camerasProc.running) {
      root.cameraRefreshPending = true
      return
    }
    camerasProc.capturedStdout = ""
    camerasProc.capturedStderr = ""
    camerasProc.parseError = ""
    camerasProc.command = root.helperCommand(["camera", "list", "--json"])
    camerasProc.running = true
  }

  function refresh() {
    root.refreshStatus()
    root.refreshCameras()
  }

  function refreshEverywhere() {
    root.broadcast("refresh")
  }

  function refreshStatusEverywhere() {
    root.broadcast("refreshStatus")
  }

  function runActions(sequence) {
    if (root.actionBusy || !sequence || sequence.length === 0) return
    var queued = []
    for (var i = 0; i < sequence.length; i++) queued.push(sequence[i].slice())
    root.actionQueue = queued
    root.runNextAction()
  }

  function runNextAction() {
    if (actionProc.running || root.currentAction.length > 0) return
    if (root.actionQueue.length === 0) {
      root.clearError("action")
      root.refreshStatusEverywhere()
      return
    }

    var remaining = root.actionQueue.slice()
    root.currentAction = remaining.shift()
    root.actionQueue = remaining
    root.actionStdout = ""
    root.actionStderr = ""
    actionProc.command = root.helperCommand(root.currentAction)
    actionProc.running = true
  }

  function finishAction(exitCode) {
    var failedAction = root.currentAction.slice()
    root.currentAction = []
    if (exitCode !== 0) {
      root.actionQueue = []
      root.setError("action", root.actionStderr || root.actionStdout
        || ("Command failed: " + failedAction.join(" ")))
      root.refreshStatusEverywhere()
      return
    }
    if (failedAction[0] === "start" || failedAction[0] === "restart")
      root.streamRunning = true
    else if (failedAction[0] === "stop")
      root.streamRunning = false
    root.runNextAction()
  }

  function toggleStream() {
    if (root.actionBusy) return
    if (!root.streamRunning && root.noCamera) {
      root.open("{}")
      return
    }
    root.runActions([[root.streamRunning ? "stop" : "start"]])
  }

  function selectCamera(target) {
    if (!target || root.actionBusy || target === root.selectedCameraTarget()) return
    var sequence = [["camera", "select", String(target)]]
    if (root.streamRunning) sequence.push(["restart"])
    root.runActions(sequence)
  }

  function setMirror(enabled) {
    if (root.actionBusy || enabled === root.mirrorEnabled) return
    root.runActions(root.streamRunning
      ? [["restart", enabled ? "--mirror" : "--no-mirror"]]
      : [["settings", "set", "mirror", enabled ? "true" : "false"]])
  }

  function setLatency(mode) {
    var normalized = mode === "smooth" ? "smooth" : "untimed"
    if (root.actionBusy || normalized === root.latencyMode) return
    root.runActions(root.streamRunning
      ? [["restart", normalized === "smooth" ? "--smooth" : "--untimed"]]
      : [["settings", "set", "latency", normalized]])
  }

  function open(payloadJson) {
    root.opened = true
    root.refreshStatus()
    if (!root.streamRunning) root.refreshCameras()
  }

  function close() {
    root.opened = false
  }

  function togglePanel() {
    root.opened ? root.close() : root.open("{}")
  }

  function closeForPopoutSwitch() {
    root.popoutSwitchClosing = true
    root.close()
    Qt.callLater(function() { root.popoutSwitchClosing = false })
  }

  Process {
    id: statusProc
    command: []

    property string capturedStdout: ""
    property string capturedStderr: ""
    property string parseError: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        statusProc.capturedStdout = String(text || "")
        statusProc.parseError = root.applyStatus(statusProc.capturedStdout)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: statusProc.capturedStderr = String(text || "")
    }
    onExited: function(exitCode) {
      var code = exitCode
      Qt.callLater(function() {
        root.statusLoaded = true
        if (code !== 0) root.setError("status", statusProc.capturedStderr || statusProc.capturedStdout || "Could not read Cam Stream status")
        else if (statusProc.parseError) root.setError("status", statusProc.parseError)
        if (root.statusRefreshPending) {
          root.statusRefreshPending = false
          Qt.callLater(root.refreshStatus)
        }
      })
    }
  }

  Process {
    id: camerasProc
    command: []

    property string capturedStdout: ""
    property string capturedStderr: ""
    property string parseError: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        camerasProc.capturedStdout = String(text || "")
        camerasProc.parseError = root.applyCameras(camerasProc.capturedStdout)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: camerasProc.capturedStderr = String(text || "")
    }
    onExited: function(exitCode) {
      var code = exitCode
      Qt.callLater(function() {
        root.camerasLoaded = true
        if (code !== 0) root.setError("cameras", camerasProc.capturedStderr || camerasProc.capturedStdout || "Could not list cameras")
        else if (camerasProc.parseError) root.setError("cameras", camerasProc.parseError)
        var rerun = root.cameraRefreshPending && !root.streamRunning
        root.cameraRefreshPending = false
        if (rerun) Qt.callLater(root.refreshCameras)
      })
    }
  }

  Process {
    id: actionProc
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStdout = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionStderr = String(text || "")
    }
    onExited: function(exitCode) {
      var code = exitCode
      Qt.callLater(function() { root.finishAction(code) })
    }
  }

  Timer {
    interval: root.opened ? 1800 : 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    interval: root.opened ? 6000 : 12000
    running: root.statusLoaded && !root.streamRunning
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshCameras()
  }

  IpcHandler {
    target: "io.github.tomdavenport.cam-stream"

    function open(): void { root.open("{}") }
    function close(): void { root.close() }
    function show(): void { root.open("{}") }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.broadcast("refresh") }
    function start(): void { if (!root.streamRunning) root.toggleStream() }
    function stop(): void { if (root.streamRunning) root.toggleStream() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.cameraButtonText
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.body
    active: root.streamRunning || root.hasError
    activeColor: root.hasError
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : Color.accent
    dimmed: root.noCamera && !root.hasError
    tooltipText: root.tooltipText

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePanel()
      else if (buttonCode === Qt.MiddleButton) root.refreshEverywhere()
      else root.toggleStream()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panelFocus
    contentWidth: panel.fittedContentWidth(Style.space(370))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    Item {
      id: panelFocus
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.close()
      Keys.onPressed: function(event) {
        if (event.text === "r" || event.text === "R") {
          root.refreshEverywhere()
          event.accepted = true
        }
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.spacing.panelGap

        Item {
          width: parent.width
          implicitHeight: Math.max(titleColumn.implicitHeight, refreshButton.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.right: refreshButton.left
            anchors.rightMargin: Style.spacing.controlGap
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: "CAM STREAM"
              color: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: "Low-latency camera preview"
              color: Qt.darker(Color.popups.text, 1.45)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "\uf021"
            tooltipText: "Refresh camera state (R)"
            foreground: Color.popups.text
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            enabled: !root.actionBusy
            onClicked: root.refreshEverywhere()
          }
        }

        BorderSurface {
          width: parent.width
          implicitHeight: statusContent.implicitHeight + Style.spacing.rowPaddingX * 2
          radius: Style.cornerRadius
          color: root.hasError
            ? Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.10)
            : root.streamRunning
              ? Util.alpha(Color.accent, 0.10)
              : Util.alpha(Color.popups.text, 0.045)
          borderSpec: Border.flat(root.hasError
            ? Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.45)
            : root.streamRunning ? Util.alpha(Color.accent, 0.38) : Util.alpha(Color.popups.text, 0.14), 1)

          Column {
            id: statusContent
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.rightMargin: Style.spacing.rowPaddingX
            spacing: Style.spacing.xs

            Text {
              width: parent.width
              text: root.stateTitle
              color: root.hasError
                ? (root.bar ? root.bar.urgent : Color.urgent)
                : Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.stateDetail
              color: Qt.darker(Color.popups.text, 1.35)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }
        }

        PanelSeparator {
          foreground: Color.popups.text
        }

        PanelSectionHeader {
          text: "CAMERA"
          foreground: Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Dropdown {
          id: cameraDropdown
          width: parent.width
          label: "Input"
          value: root.cameraChoice
          options: root.cameraOptions
          foreground: Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          enabled: !root.actionBusy && root.cameraOptions.length > 0
          onChanged: function(value) {
            root.cameraChoice = value
            root.selectCamera(value)
          }
        }

        Text {
          visible: root.camerasLoaded && root.cameraOptions.length === 0
          width: parent.width
          text: "No video-capable input is available. Cam Stream ignores metadata-only camera nodes."
          color: Qt.darker(Color.popups.text, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        PanelSeparator {
          foreground: Color.popups.text
        }

        PanelSectionHeader {
          text: "PLAYBACK"
          foreground: Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Toggle {
          width: parent.width
          label: "Mirror preview"
          description: "Flip the image horizontally, like a familiar self-view."
          checked: root.mirrorEnabled
          foreground: Color.popups.text
          enabled: !root.actionBusy
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          onClicked: root.setMirror(!root.mirrorEnabled)
        }

        Dropdown {
          id: latencyDropdown
          width: parent.width
          label: "Latency"
          value: root.latencyMode
          options: [
            { value: "untimed", label: "Realtime (no buffer)" },
            { value: "smooth", label: "Smoother (adds latency)" }
          ]
          foreground: Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          enabled: !root.actionBusy
          onChanged: function(value) { root.setLatency(value) }
        }

        Button {
          width: parent.width
          text: root.actionBusy ? "Applying…"
            : root.streamRunning ? "Stop camera preview"
            : "Start camera preview"
          iconText: root.actionBusy ? "\uf110" : root.streamRunning ? "\uf04d" : "\uf04b"
          iconSpinning: root.actionBusy
          selected: root.streamRunning
          bordered: true
          focusable: true
          foreground: Color.popups.text
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          enabled: !root.actionBusy && (!root.noCamera || root.streamRunning)
          onClicked: root.toggleStream()
        }

        Text {
          width: parent.width
          text: "Left click the bar icon to toggle · Right click for this panel"
          color: Qt.darker(Color.popups.text, 1.55)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
