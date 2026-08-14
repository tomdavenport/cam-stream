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

  // Recording and live streaming deliberately share one activity state but
  // remain independent from the camera preview above. A camera may be off
  // while either activity is running; that is a valid streaming setup.
  property bool activityLoaded: false
  property bool activitySettingsLoaded: false
  property string activityMode: "idle"
  property bool activityPaused: false
  property int activityElapsedSeconds: 0
  property string activityOutputPath: ""
  property string activityDestination: ""
  property bool activityLocalCopyActive: false
  property string activityErrorMessage: ""
  property string activityErrorSource: ""

  property string captureMode: "fullscreen"
  property string audioMode: "none"
  property string qualityMode: "1080p60"
  property string liveDestination: "x"
  property bool localCopyEnabled: true
  property bool xConfigured: false
  property bool customConfigured: false
  property string xServer: ""
  property string customServer: ""
  property string selectedTab: "camera"

  property string errorMessage: ""
  property string errorSource: ""
  property bool statusRefreshPending: false
  property bool cameraRefreshPending: false
  property bool settingsRefreshPending: false

  property var actionQueue: []
  property var currentAction: []
  property string actionStdout: ""
  property string actionStderr: ""

  readonly property bool actionBusy: actionProc.running || secretProc.running
    || currentAction.length > 0 || actionQueue.length > 0
  readonly property bool recordActive: activityMode === "record"
  readonly property bool liveActive: activityMode === "live"
  readonly property bool activityActive: recordActive || liveActive
  readonly property bool selectedProfileConfigured: liveDestination === "custom"
    ? customConfigured : xConfigured
  readonly property string selectedProfileServer: liveDestination === "custom"
    ? customServer : xServer
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
    : liveActive ? "\uf519"
    : recordActive ? "\uf111"
    : hasError || activityErrorMessage !== "" ? "\uf071"
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

  function setActivityError(source, message) {
    root.activityErrorSource = source
    root.activityErrorMessage = root.compactError(message, "Cam Stream activity failed")
  }

  function clearActivityError(source) {
    if (root.activityErrorSource !== source) return
    root.activityErrorSource = ""
    root.activityErrorMessage = ""
  }

  function normalizedActivityMode(value) {
    var mode = String(value || "idle").toLowerCase()
    if (mode === "record" || mode === "recording" || mode === "paused") return "record"
    if (mode === "live" || mode === "stream" || mode === "streaming" || mode === "sending") return "live"
    return "idle"
  }

  function normalizedCaptureMode(value) {
    var mode = String(value || "fullscreen").toLowerCase()
    return mode === "window" || mode === "region" ? mode : "fullscreen"
  }

  function normalizedAudioMode(value) {
    var mode = String(value || "none").toLowerCase()
    return mode === "microphone" || mode === "desktop" || mode === "both" ? mode : "none"
  }

  function normalizedQuality(value) {
    var quality = String(value || "1080p60").toLowerCase()
    return quality === "720p30" || quality === "1080p30" ? quality : "1080p60"
  }

  function formatElapsed(value) {
    var total = Math.max(0, Math.floor(Number(value) || 0))
    var hours = Math.floor(total / 3600)
    var minutes = Math.floor((total % 3600) / 60)
    var seconds = total % 60
    var mm = minutes < 10 ? "0" + minutes : String(minutes)
    var ss = seconds < 10 ? "0" + seconds : String(seconds)
    return hours > 0 ? String(hours) + ":" + mm + ":" + ss : mm + ":" + ss
  }

  function destinationLabel(value) {
    return String(value || "x").toLowerCase() === "custom" ? "Custom RTMPS" : "X"
  }

  function panelHasError() {
    return root.selectedTab === "camera" ? root.hasError : root.activityErrorMessage !== ""
  }

  function panelStateTitle() {
    if (root.selectedTab === "camera") return root.stateTitle
    if (root.activityErrorMessage) return "Something went wrong"
    if (root.selectedTab === "record") {
      if (root.recordActive) return root.activityPaused ? "Recording paused" : "Recording your screen"
      if (root.liveActive) return "Live stream is active"
      return "Ready to record"
    }
    if (root.liveActive)
      return "Sending to " + root.destinationLabel(root.activityDestination || root.liveDestination)
    if (root.recordActive) return "Screen recording is active"
    return root.selectedProfileConfigured ? "Ready to send" : "Set up your stream destination"
  }

  function panelStateDetail() {
    if (root.selectedTab === "camera") return root.stateDetail
    if (root.activityErrorMessage) return root.activityErrorMessage
    if (root.recordActive) {
      var recordingState = root.activityPaused ? "Paused" : "Recording"
      return recordingState + " · " + root.formatElapsed(root.activityElapsedSeconds)
        + (root.activityOutputPath ? " · " + root.activityOutputPath : "")
    }
    if (root.liveActive) {
      var copy = root.activityLocalCopyActive ? " · local copy on" : ""
      return root.formatElapsed(root.activityElapsedSeconds) + copy
    }
    if (root.selectedTab === "record")
      return "Uses Omarchy's capture picker and records at native quality."
    if (root.selectedProfileConfigured)
      return root.destinationLabel(root.liveDestination) + " is configured · " + root.qualityMode
    return "Paste the RTMPS server and stream key supplied by your platform."
  }

  function panelStateActive() {
    if (root.selectedTab === "camera") return root.streamRunning
    return root.activityActive
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
    if (root.liveActive)
      return "Cam Stream · Sending to " + root.destinationLabel(root.activityDestination || root.liveDestination)
        + " · Left click toggles camera · Right click for controls"
    if (root.recordActive)
      return "Cam Stream · " + (root.activityPaused ? "Recording paused" : "Recording " + root.formatElapsed(root.activityElapsedSeconds))
        + " · Left click toggles camera · Right click for controls"
    if (root.activityErrorMessage) return "Cam Stream activity error · " + root.activityErrorMessage + " · Right click for details"
    if (root.hasError) return "Cam Stream error · " + root.errorMessage + " · Right click for details"
    if (root.noCamera) return "Cam Stream · No camera found · Right click for settings"
    if (root.streamRunning) return "Cam Stream · Camera on " + root.cameraName(root.activeCamera) + " · Left click to stop"
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

    var wasActivityLoaded = root.activityLoaded
    var activity = data.activity && typeof data.activity === "object" ? data.activity : {}
    var state = String(activity.state || "").toLowerCase()
    var mode = root.normalizedActivityMode(activity.mode || state)
    var running = activity.running === true
      || state === "recording" || state === "paused" || state === "sending"
    root.activityMode = running ? mode : "idle"
    root.activityPaused = root.activityMode === "record"
      && (activity.paused === true || state === "paused")
    root.activityElapsedSeconds = Math.max(0, Math.floor(Number(activity.elapsedSeconds) || 0))
    root.activityOutputPath = String(activity.outputPath || activity.lastOutputPath || "")
    root.activityDestination = String(activity.destination || "")
    root.activityLocalCopyActive = activity.localCopy === true
    root.activityLoaded = true
    if (activity.error) root.setActivityError("activity", activity.error)
    else root.clearActivityError("activity")

    if (activity.captureMode !== undefined)
      root.captureMode = root.normalizedCaptureMode(activity.captureMode)
    if (activity.audioMode !== undefined)
      root.audioMode = root.normalizedAudioMode(activity.audioMode)
    if (activity.quality !== undefined)
      root.qualityMode = root.normalizedQuality(activity.quality)
    if (activity.destination !== undefined && !root.activityActive)
      root.liveDestination = String(activity.destination).toLowerCase() === "custom" ? "custom" : "x"
    if (activity.localCopy !== undefined && !root.activityActive)
      root.localCopyEnabled = activity.localCopy !== false

    root.statusLoaded = true
    root.clearError("status")
    root.clearActivityError("status")
    if (!wasActivityLoaded && root.activityActive && root.opened)
      root.selectedTab = root.liveActive ? "live" : "record"
    Qt.callLater(root.syncCameraChoice)
    return ""
  }

  function applyActivitySettings(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "").trim())
    } catch (e) {
      return "Activity settings returned invalid JSON"
    }
    if (!data || typeof data !== "object")
      return "Activity settings returned an unsupported response"

    var settings = data.settings && typeof data.settings === "object" ? data.settings : data
    root.captureMode = root.normalizedCaptureMode(settings.captureMode || settings.capture)
    root.audioMode = root.normalizedAudioMode(settings.audioMode || settings.audio)
    root.qualityMode = root.normalizedQuality(settings.quality)
    root.liveDestination = String(settings.destination || "x").toLowerCase() === "custom" ? "custom" : "x"
    root.localCopyEnabled = settings.localCopy === undefined
      ? (settings.localCopyEnabled === undefined ? true : settings.localCopyEnabled !== false)
      : settings.localCopy !== false

    var profiles = settings.profiles && typeof settings.profiles === "object" ? settings.profiles : {}
    var xProfile = profiles.x && typeof profiles.x === "object" ? profiles.x
      : (settings.x && typeof settings.x === "object" ? settings.x : {})
    var customProfile = profiles.custom && typeof profiles.custom === "object" ? profiles.custom
      : (settings.custom && typeof settings.custom === "object" ? settings.custom : {})
    root.xConfigured = xProfile.configured === true || settings.xConfigured === true
    root.customConfigured = customProfile.configured === true || settings.customConfigured === true
    root.xServer = String(xProfile.server || xProfile.serverUrl || settings.xServer || "")
    root.customServer = String(customProfile.server || customProfile.serverUrl || settings.customServer || "")
    root.activitySettingsLoaded = true
    root.clearActivityError("settings")
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

  function refreshActivitySettings() {
    if (settingsProc.running) {
      root.settingsRefreshPending = true
      return
    }
    settingsProc.capturedStdout = ""
    settingsProc.capturedStderr = ""
    settingsProc.parseError = ""
    settingsProc.command = root.helperCommand(["activity", "settings", "--json"])
    settingsProc.running = true
  }

  function refresh() {
    root.refreshStatus()
    root.refreshCameras()
    root.refreshActivitySettings()
  }

  function refreshEverywhere() {
    root.broadcast("refresh")
  }

  function refreshStatusEverywhere() {
    root.broadcast("refreshStatus")
  }

  function isActivityCommand(action) {
    if (!action || action.length === 0) return false
    return action[0] === "activity" || action[0] === "record" || action[0] === "live"
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
      root.clearActivityError("action")
      root.refreshStatusEverywhere()
      root.refreshActivitySettings()
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
      var message = root.actionStderr || root.actionStdout
        || ("Command failed: " + failedAction.join(" "))
      if (root.isActivityCommand(failedAction)) root.setActivityError("action", message)
      else root.setError("action", message)
      root.refreshStatusEverywhere()
      if (root.isActivityCommand(failedAction)) root.refreshActivitySettings()
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

  function setActivitySetting(name, value) {
    if (root.actionBusy || root.activityActive) return
    var normalized = String(value)
    if (name === "capture") root.captureMode = root.normalizedCaptureMode(normalized)
    else if (name === "audio") root.audioMode = root.normalizedAudioMode(normalized)
    else if (name === "quality") root.qualityMode = root.normalizedQuality(normalized)
    else if (name === "destination") {
      root.liveDestination = normalized.toLowerCase() === "custom" ? "custom" : "x"
      if (streamKeyField) streamKeyField.text = ""
      Qt.callLater(root.syncProfileEditor)
    } else if (name === "local-copy") root.localCopyEnabled = normalized === "true"
    root.runActions([["activity", "set", name, normalized]])
  }

  function syncProfileEditor() {
    if (!serverField || serverField.activeFocus || (streamKeyField && streamKeyField.activeFocus)) return
    serverField.text = root.selectedProfileServer
  }

  function configureLive() {
    if (root.actionBusy || root.activityActive) return
    var server = String(serverField.text || "").trim()
    var key = String(streamKeyField.text || "")
    if (!server) {
      root.setActivityError("configure", "Enter the RTMPS server URL")
      return
    }
    if (!key) {
      root.setActivityError("configure", "Enter the stream key")
      return
    }
    root.clearActivityError("configure")
    secretProc.capturedStdout = ""
    secretProc.capturedStderr = ""
    secretProc.secret = key
    secretProc.command = root.helperCommand([
      "live", "configure", root.liveDestination,
      "--server", server,
      "--key-stdin"
    ])
    // The masked field is cleared before the child starts. The transient
    // Process property is cleared immediately after writing to stdin.
    streamKeyField.text = ""
    secretProc.running = true
  }

  function clearLiveProfile() {
    if (root.actionBusy || root.activityActive) return
    serverField.text = ""
    streamKeyField.text = ""
    if (root.liveDestination === "custom") root.customConfigured = false
    else root.xConfigured = false
    root.runActions([["live", "clear", root.liveDestination]])
  }

  function startRecording() {
    if (root.actionBusy || root.activityActive) return
    root.close()
    root.runActions([["record", "start"]])
  }

  function toggleRecordingPause() {
    if (root.actionBusy || !root.recordActive) return
    root.runActions([["record", root.activityPaused ? "resume" : "pause"]])
  }

  function stopRecording() {
    if (root.actionBusy || !root.recordActive) return
    root.runActions([["record", "stop"]])
  }

  function toggleLive() {
    if (root.actionBusy) return
    if (root.liveActive) {
      root.runActions([["live", "stop"]])
      return
    }
    if (root.activityActive || !root.selectedProfileConfigured) return
    root.close()
    root.runActions([["live", "start", root.liveDestination]])
  }

  function openXLiveStudio() {
    if (urlProc.running) return
    urlProc.command = ["xdg-open", "https://x.com/i/live-studio"]
    urlProc.running = true
  }

  function open(payloadJson) {
    root.opened = true
    root.refreshStatus()
    root.refreshActivitySettings()
    if (!root.streamRunning) root.refreshCameras()
    if (root.activityActive) root.selectedTab = root.liveActive ? "live" : "record"
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
        root.activityLoaded = true
        if (code !== 0) {
          var message = statusProc.capturedStderr || statusProc.capturedStdout || "Could not read Cam Stream status"
          root.setError("status", message)
          root.setActivityError("status", message)
        } else if (statusProc.parseError) {
          root.setError("status", statusProc.parseError)
          root.setActivityError("status", statusProc.parseError)
        }
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
    id: settingsProc
    command: []

    property string capturedStdout: ""
    property string capturedStderr: ""
    property string parseError: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        settingsProc.capturedStdout = String(text || "")
        settingsProc.parseError = root.applyActivitySettings(settingsProc.capturedStdout)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: settingsProc.capturedStderr = String(text || "")
    }
    onExited: function(exitCode) {
      var code = exitCode
      Qt.callLater(function() {
        if (code !== 0) root.setActivityError("settings", settingsProc.capturedStderr
          || settingsProc.capturedStdout || "Could not read recording and live settings")
        else if (settingsProc.parseError) root.setActivityError("settings", settingsProc.parseError)
        if (root.settingsRefreshPending) {
          root.settingsRefreshPending = false
          Qt.callLater(root.refreshActivitySettings)
        }
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

  Process {
    id: secretProc
    command: []
    property string secret: ""
    property string capturedStdout: ""
    property string capturedStderr: ""
    stdinEnabled: true

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: secretProc.capturedStdout = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: secretProc.capturedStderr = String(text || "")
    }
    onStarted: {
      write(secret + "\n")
      secret = ""
    }
    onExited: function(exitCode) {
      var code = exitCode
      Qt.callLater(function() {
        secretProc.secret = ""
        if (code !== 0) root.setActivityError("configure", secretProc.capturedStderr
          || secretProc.capturedStdout || "Could not save the stream profile")
        else {
          root.clearActivityError("configure")
          root.refreshActivitySettings()
          root.refreshStatusEverywhere()
        }
      })
    }
  }

  Process {
    id: urlProc
    command: []
    onExited: function(exitCode) {
      if (exitCode !== 0) root.setActivityError("url", "Could not open X Live Studio")
      else root.clearActivityError("url")
    }
  }

  Timer {
    interval: root.activityActive ? 1000 : (root.opened ? 1800 : 4000)
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

  Timer {
    interval: root.opened ? 12000 : 30000
    running: !root.activityActive
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshActivitySettings()
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
    active: root.activityActive || root.streamRunning || root.hasError || root.activityErrorMessage !== ""
    activeColor: root.hasError || root.activityErrorMessage !== "" || root.activityActive
      ? (root.bar ? root.bar.urgent : Color.urgent)
      : Color.accent
    dimmed: root.noCamera && !root.hasError && !root.activityActive
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
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(700))

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

      Flickable {
        id: panelScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: panelColumn.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: panelColumn
          width: panelScroll.width
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
                text: "Camera, recording and live streaming"
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
              tooltipText: "Refresh Cam Stream state (R)"
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !root.actionBusy
              onClicked: root.refreshEverywhere()
            }
          }

          ButtonGroup {
            id: modeTabs
            width: parent.width
            value: root.selectedTab
            options: [
              { value: "camera", label: "Camera" },
              { value: "record", label: "Record" },
              { value: "live", label: "Live Stream" }
            ]
            foreground: Color.popups.text
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            enabled: !root.actionBusy
            onChanged: function(value) {
              root.selectedTab = value
              panelScroll.contentY = 0
              if (value === "live") Qt.callLater(root.syncProfileEditor)
            }
          }

          BorderSurface {
            width: parent.width
            implicitHeight: statusContent.implicitHeight + Style.spacing.rowPaddingX * 2
            radius: Style.cornerRadius
            color: root.panelHasError()
              ? Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.10)
              : root.panelStateActive()
                ? Util.alpha(root.selectedTab === "camera" ? Color.accent : (root.bar ? root.bar.urgent : Color.urgent), 0.10)
                : Util.alpha(Color.popups.text, 0.045)
            borderSpec: Border.flat(root.panelHasError()
              ? Util.alpha(root.bar ? root.bar.urgent : Color.urgent, 0.45)
              : root.panelStateActive()
                ? Util.alpha(root.selectedTab === "camera" ? Color.accent : (root.bar ? root.bar.urgent : Color.urgent), 0.38)
                : Util.alpha(Color.popups.text, 0.14), 1)

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
                text: root.panelStateTitle()
                color: root.panelHasError()
                  ? (root.bar ? root.bar.urgent : Color.urgent)
                  : Color.popups.text
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.panelStateDetail()
                color: Qt.darker(Color.popups.text, 1.35)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 3
              }
            }
          }

          Column {
            id: cameraTab
            visible: root.selectedTab === "camera"
            width: parent.width
            spacing: Style.spacing.panelGap

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
          }

          Column {
            id: activityCaptureControls
            visible: root.selectedTab !== "camera"
            width: parent.width
            spacing: Style.spacing.panelGap

            PanelSeparator {
              foreground: Color.popups.text
            }

            PanelSectionHeader {
              text: "CAPTURE"
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Dropdown {
              width: parent.width
              label: "Area"
              value: root.captureMode
              options: [
                { value: "fullscreen", label: "Full screen (focused monitor)" },
                { value: "window", label: "Window picker" },
                { value: "region", label: "Region picker" }
              ]
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              onChanged: function(value) { root.setActivitySetting("capture", value) }
            }

            Dropdown {
              width: parent.width
              label: "Audio"
              value: root.audioMode
              options: [
                { value: "none", label: "No audio" },
                { value: "microphone", label: "Microphone" },
                { value: "desktop", label: "Desktop audio" },
                { value: "both", label: "Desktop + microphone" }
              ]
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              onChanged: function(value) { root.setActivitySetting("audio", value) }
            }
          }

          Column {
            id: recordTab
            visible: root.selectedTab === "record"
            width: parent.width
            spacing: Style.spacing.panelGap

            BorderSurface {
              width: parent.width
              implicitHeight: recordQualityText.implicitHeight + Style.spacing.rowPaddingX * 2
              radius: Style.cornerRadius
              color: Util.alpha(Color.popups.text, 0.035)
              borderSpec: Border.flat(Util.alpha(Color.popups.text, 0.12), 1)

              Text {
                id: recordQualityText
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                text: "Native capture quality · 60 fps · MP4"
                color: Qt.darker(Color.popups.text, 1.3)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Text {
              visible: root.activityOutputPath !== ""
              width: parent.width
              text: (root.recordActive ? "Output: " : "Last output: ") + root.activityOutputPath
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 2
              elide: Text.ElideMiddle
            }

            Row {
              visible: root.recordActive
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.activityPaused ? "Resume" : "Pause"
                iconText: root.activityPaused ? "\uf04b" : "\uf04c"
                bordered: true
                focusable: true
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                enabled: !root.actionBusy
                onClicked: root.toggleRecordingPause()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Stop recording"
                iconText: "\uf04d"
                selected: true
                bordered: true
                focusable: true
                foreground: root.bar ? root.bar.urgent : Color.urgent
                accent: root.bar ? root.bar.urgent : Color.urgent
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                enabled: !root.actionBusy
                onClicked: root.stopRecording()
              }
            }

            Button {
              visible: !root.recordActive
              width: parent.width
              text: root.liveActive ? "Stop live stream before recording"
                : root.actionBusy ? "Starting…"
                : "Start recording"
              iconText: root.actionBusy ? "\uf110" : "\uf111"
              iconSpinning: root.actionBusy
              bordered: true
              focusable: true
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              onClicked: root.startRecording()
            }

            Text {
              width: parent.width
              text: "The camera preview keeps its current state and position."
              color: Qt.darker(Color.popups.text, 1.5)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }

          Column {
            id: liveTab
            visible: root.selectedTab === "live"
            width: parent.width
            spacing: Style.spacing.panelGap

            PanelSeparator {
              foreground: Color.popups.text
            }

            PanelSectionHeader {
              text: "DESTINATION"
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            ButtonGroup {
              width: parent.width
              value: root.liveDestination
              options: [
                { value: "x", label: "X" },
                { value: "custom", label: "Custom RTMPS" }
              ]
              foreground: Color.popups.text
              background: Color.popups.background
              accent: Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              onChanged: function(value) { root.setActivitySetting("destination", value) }
            }

            BorderSurface {
              width: parent.width
              implicitHeight: profileStatusRow.implicitHeight + Style.spacing.rowPaddingX * 2
              radius: Style.cornerRadius
              color: root.selectedProfileConfigured
                ? Util.alpha(Color.accent, 0.08)
                : Util.alpha(Color.popups.text, 0.035)
              borderSpec: Border.flat(root.selectedProfileConfigured
                ? Util.alpha(Color.accent, 0.32)
                : Util.alpha(Color.popups.text, 0.12), 1)

              Row {
                id: profileStatusRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.controlGap

                Text {
                  text: root.selectedProfileConfigured ? "\uf058" : "\uf05a"
                  color: root.selectedProfileConfigured ? Color.accent : Qt.darker(Color.popups.text, 1.35)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width - x - Style.spacing.controlGap
                  text: root.destinationLabel(root.liveDestination)
                    + (root.selectedProfileConfigured ? " is configured" : " needs a server and stream key")
                  color: Color.popups.text
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }

            Dropdown {
              width: parent.width
              label: "Stream quality"
              value: root.qualityMode
              options: [
                { value: "720p30", label: "720p · 30 fps · 6 Mbps" },
                { value: "1080p30", label: "1080p · 30 fps · 8 Mbps" },
                { value: "1080p60", label: "1080p · 60 fps · 12 Mbps (recommended)" }
              ]
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              onChanged: function(value) { root.setActivitySetting("quality", value) }
            }

            Toggle {
              width: parent.width
              label: "Save a local copy"
              description: "Record the same encoded stream locally. Enabled by default."
              checked: root.localCopyEnabled
              foreground: Color.popups.text
              enabled: root.activitySettingsLoaded && !root.actionBusy && !root.activityActive
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              onClicked: root.setActivitySetting("local-copy", root.localCopyEnabled ? "false" : "true")
            }

            PanelSeparator {
              foreground: Color.popups.text
            }

            PanelSectionHeader {
              text: "RTMPS PROFILE"
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Text {
              width: parent.width
              text: "Server URL"
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            TextField {
              id: serverField
              width: parent.width
              placeholderText: root.selectedProfileConfigured
                ? "Configured — paste a new URL to replace"
                : "rtmps://…"
              foreground: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !root.actionBusy && !root.activityActive
              onAccepted: if (streamKeyField.text.length > 0) root.configureLive()
            }

            Text {
              width: parent.width
              text: "Stream key"
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            TextField {
              id: streamKeyField
              width: parent.width
              password: true
              placeholderText: root.selectedProfileConfigured
                ? "Stored in keyring — paste a new key to replace"
                : "Paste once — stored in your system keyring"
              foreground: Color.popups.text
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !root.actionBusy && !root.activityActive
              onAccepted: root.configureLive()
            }

            Row {
              width: parent.width
              spacing: Style.spacing.controlGap

              Button {
                width: (parent.width - parent.spacing) / 2
                text: root.actionBusy ? "Saving…" : "Save profile"
                iconText: root.actionBusy ? "\uf110" : "\uf0c7"
                iconSpinning: root.actionBusy
                bordered: true
                focusable: true
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                enabled: !root.actionBusy && !root.activityActive
                  && serverField.text.trim().length > 0 && streamKeyField.text.length > 0
                onClicked: root.configureLive()
              }

              Button {
                width: (parent.width - parent.spacing) / 2
                text: "Clear profile"
                iconText: "\uf2ed"
                bordered: true
                focusable: true
                foreground: Color.popups.text
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                enabled: root.selectedProfileConfigured && !root.actionBusy && !root.activityActive
                onClicked: root.clearLiveProfile()
              }
            }

            Button {
              visible: root.liveDestination === "x"
              width: parent.width
              text: "Open X Live Studio"
              iconText: "\uf35d"
              bordered: true
              focusable: true
              foreground: Color.popups.text
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !urlProc.running
              onClicked: root.openXLiveStudio()
            }

            Text {
              visible: root.liveDestination === "x"
              width: parent.width
              text: "Cam Stream sends the video. Publishing and ending the broadcast still happen in X."
              color: Qt.darker(Color.popups.text, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Button {
              width: parent.width
              text: root.liveActive ? "Stop sending"
                : root.recordActive ? "Stop recording before streaming"
                : root.actionBusy ? "Starting…"
                : "Start sending to " + root.destinationLabel(root.liveDestination)
              iconText: root.actionBusy ? "\uf110" : root.liveActive ? "\uf04d" : "\uf519"
              iconSpinning: root.actionBusy
              selected: root.liveActive
              bordered: true
              focusable: true
              foreground: root.liveActive ? (root.bar ? root.bar.urgent : Color.urgent) : Color.popups.text
              accent: root.liveActive ? (root.bar ? root.bar.urgent : Color.urgent) : Color.accent
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              enabled: !root.actionBusy && (root.liveActive
                || (!root.activityActive && root.activitySettingsLoaded && root.selectedProfileConfigured))
              onClicked: root.toggleLive()
            }
          }

          Text {
            width: parent.width
            text: "Left click the bar icon always toggles the camera · Right click opens this panel"
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
}
