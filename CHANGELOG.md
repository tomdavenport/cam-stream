# Changelog

All notable changes to Cam Stream are documented here.

## 1.1.0 — 2026-08-14

- Add native full-screen, window, and region recording without an OBS scene.
- Add X Live Studio and custom RTMP(S) destinations with secure stream-key
  storage in the desktop keyring.
- Record a local copy by default while sending a live stream, using the same
  encoder and remuxing the result to MP4 after the session.
- Keep camera preview state independent from recording and streaming so the
  camera window can be toggled, moved, and resized naturally during capture.
- Add one unified Camera, Record, and Live Stream control panel with persistent
  capture, audio, quality, destination, and local-copy preferences.
- Own screen-recorder processes through private runtime state and IPC; Cam
  Stream never globally stops another recorder.
- Extend automated coverage for recording, live configuration, secret
  handling, recorder conflicts, and failure recovery.

## 1.0.2 — 2026-08-14

- Stop automatically probing V4L2 devices while a preview is live, avoiding
  recurring camera-driver contention and CPU spikes from each bar instance.
- Follow mpv's documented realtime V4L2 path, including a single decoder
  thread and additive device options that preserve its no-buffer profile.
- Make the smoother mode's latency tradeoff explicit in the control panel.
- Report the active capture format, size, and frame rate in runtime status.

## 1.0.1 — 2026-08-13

- Document standalone Arch Linux installation separately from the Omarchy
  bar-widget plugin.
- Make the asynchronous window-positioning test reliable on slower builders.
- Run the camera helper's behavioral suite in continuous integration.

## 1.0.0 — 2026-08-13

- Package Cam Stream as an Omarchy Quattro bar-widget plugin.
- Add live, stopped, error, and no-camera bar states.
- Add a native panel for camera selection, mirroring, and latency mode.
- Bundle the camera helper so the plugin does not depend on a user-installed
  `cam-stream` command.
- Store camera preferences and runtime data in the user's XDG directories.
