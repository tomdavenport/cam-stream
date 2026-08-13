# Changelog

All notable changes to Cam Stream are documented here.

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
