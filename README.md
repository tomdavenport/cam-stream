# Cam Stream

<p align="center">
  <strong>A native, one-click camera preview for Omarchy 4 / Quattro.</strong><br>
  Open a realtime floating preview, switch inputs, mirror the image, and get
  back to work.
</p>

<p align="center">
  <img
    src="assets/cam-stream-hero.png"
    alt="Cam Stream running on an Omarchy Quattro desktop, with a live streamer camera preview and the native control panel open"
    width="100%"
  >
</p>

<p align="center">
  <a href="#install"><strong>Install the Quattro plugin</strong></a>
  ·
  <a href="https://aur.archlinux.org/packages/cam-stream"><strong>Get the standalone AUR command</strong></a>
  ·
  <a href="LICENSE"><strong>MIT licensed</strong></a>
</p>

Cam Stream puts a camera-preview control in the Omarchy bar. Left click the
camera icon to start or stop the preview. Right click it to choose a camera,
mirror the picture, or deliberately trade realtime response for smoother
playback.

The widget follows the active Omarchy theme and shows distinct live, stopped,
error, and no-camera states. Its camera helper is bundled in this repository;
the widget does not look for a separately installed `cam-stream` command.

## Install

### Omarchy 4 / Quattro plugin

Install the native bar widget and enable it immediately:

```bash
omarchy plugin add https://github.com/tomdavenport/cam-stream.git --enable
```

No AUR package is needed for the widget: the plugin includes its own helper.
Left click the new camera icon to toggle the preview, or right click it for the
camera, mirror, and latency controls.

### Arch Linux / AUR command

Install the standalone command without the Quattro widget:

```bash
yay -S cam-stream
```

This installs `cam-stream` at `/usr/bin/cam-stream`. It is useful on Arch and
other Wayland desktops, but it does not add the native Omarchy bar control.

## Omarchy plugin gallery

Cam Stream is live in the project-recommended community gallery. Open the
[Cam Stream marketplace listing](https://omarchyplugins.com/plugin.html?id=io.github.tomdavenport.cam-stream)
to review it or copy the install command. Its
[submission issue](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/129)
passed automated Quattro validation and maintainer review; the marketplace
tracks the current validated `main` branch for later versions and preview
updates.

Plugin authors can submit another public Quattro plugin by following the
marketplace's [submission guide](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/blob/main/SUBMISSION.md).

## Requirements

The native bar widget requires **Omarchy 4 (Quattro)** and its
Quickshell-based shell and plugin commands. It is not a Waybar module and does
not support Omarchy 3.

The bundled `cam-stream` command also works on its own on Arch Linux and other
Wayland desktops with V4L2 camera support. Standalone use does not require
Omarchy, but it does not install the bar widget.

Runtime dependencies:

- Bash 5
- `mpv`
- `v4l-utils` (`v4l2-ctl`)
- `util-linux` (`flock`)
- the coreutils and procps tools included in the Omarchy base system

`hyprctl` and `jq` are optional for best-effort Quattro window positioning;
the preview still works without automatic positioning. `fuser` from `psmisc`
is optional for reporting which process has a busy camera.

Install any missing packages through Omarchy's standard package workflow before
enabling the plugin. Add `psmisc` if you want busy-camera process reporting.
Omarchy already ships `hyprctl` as part of its desktop.

## Standalone AUR details

The [`cam-stream` AUR package](https://aur.archlinux.org/packages/cam-stream)
builds the latest stable release and installs the command at
`/usr/bin/cam-stream`. Using the standard manual AUR workflow:

```bash
git clone https://aur.archlinux.org/cam-stream.git
cd cam-stream
makepkg -si
```

Then inspect the available cameras and start a preview:

```bash
cam-stream camera list
cam-stream doctor
cam-stream start
cam-stream stop
```

The AUR package is intentionally command-only. To add the native Quattro bar
control, use the Omarchy installation below; that plugin remains self-contained
and does not depend on the AUR package.

## Review-first Omarchy installation

Omarchy plugins are unsandboxed code. The review-first path is to add Cam
Stream, inspect the checkout, and then enable it:

```bash
omarchy plugin add https://github.com/tomdavenport/cam-stream.git
cd "$HOME/.config/omarchy/plugins/io.github.tomdavenport.cam-stream"
less manifest.json
less BarWidget.qml
less bin/cam-stream
omarchy plugin enable io.github.tomdavenport.cam-stream --section right
```

To add and enable it in one command after reviewing the repository online:

```bash
omarchy plugin add https://github.com/tomdavenport/cam-stream.git --enable
```

The manifest requests the right side of the bar by default. Omarchy's bar
settings can move it later.

## Use

- **Left click** the bar icon to start or stop the camera preview.
- **Right click** to open the control panel.
- **Middle click** to refresh camera and runtime state.
- Press **R** while the panel has focus to refresh it.

The selected camera, mirror preference, and latency preference persist in Cam
Stream's own XDG configuration directory. Changing the camera or playback mode
while the preview is live restarts that preview so the change takes effect.

**Realtime (no buffer)** is the default and follows mpv's low-latency V4L2
path. **Smoother (adds latency)** is an explicit opt-in for steadier frame
pacing. Automatic camera discovery pauses while the preview is live so the bar
never repeatedly probes the active capture device; status checks continue.

The bundled command also works directly:

```bash
cam_stream="$HOME/.config/omarchy/plugins/io.github.tomdavenport.cam-stream/bin/cam-stream"
"$cam_stream" status
"$cam_stream" camera list
"$cam_stream" start
"$cam_stream" stop
```

Run `"$cam_stream" --help` for the complete command reference.

## Update

```bash
omarchy plugin update io.github.tomdavenport.cam-stream
```

Omarchy fetches the repository, shows the incoming diff for review, and only
accepts a fast-forward update that still passes plugin validation. The shell
rescans updated plugins automatically.

## Disable or remove

Disable the widget without deleting its checkout:

```bash
omarchy plugin disable io.github.tomdavenport.cam-stream
```

Stop a live preview before removing the plugin, because the preview process is
separate from the shell:

```bash
cam_stream="$HOME/.config/omarchy/plugins/io.github.tomdavenport.cam-stream/bin/cam-stream"
"$cam_stream" stop
omarchy plugin remove io.github.tomdavenport.cam-stream
```

Removal deletes the git-managed plugin checkout. It intentionally leaves Cam
Stream's user preferences and diagnostic history in place.

### Remove residual data

After stopping the preview and removing the plugin, its residual data is
limited to its own XDG locations:

- `${XDG_CONFIG_HOME:-$HOME/.config}/cam-stream/config` — selected camera and
  playback preferences, stored as plain data and never sourced as shell code
- `${XDG_STATE_HOME:-$HOME/.local/state}/cam-stream/` — the runtime log, PID,
  and active-launch record
- `${XDG_RUNTIME_DIR}/cam-stream/` — transient lock and local `mpv` IPC files
  when `XDG_RUNTIME_DIR` is secure; otherwise Cam Stream uses an owner-only
  directory below `${TMPDIR:-/tmp}/cam-stream-runtime-$(id -u)/`

If you do not want to keep preferences or logs, those exact locations can be
deleted manually. This is optional and irreversible; do it only after the
preview is stopped.

## Security and trust

Omarchy loads plugins as unsandboxed code inside its long-lived shell. Review
this repository and every update before enabling it. A marketplace listing is
discovery metadata, not a security review or endorsement.

Cam Stream's runtime behavior is local:

- The QML widget launches only the `bin/cam-stream` file bundled in the plugin
  checkout.
- The helper reads local V4L2 camera devices and starts a local `mpv` preview.
- It requires no elevated privileges, system service, or network connection.
- It writes only to its own XDG config, state, and runtime paths.

Installing and updating through `omarchy plugin` does use git and the network
to retrieve this public repository.

## Troubleshooting

Define the helper path once before running the checks below:

```bash
cam_stream="$HOME/.config/omarchy/plugins/io.github.tomdavenport.cam-stream/bin/cam-stream"
```

### The widget is missing

Confirm that Omarchy discovered and enabled it, then rescan if needed:

```bash
omarchy plugin list
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.tomdavenport.cam-stream --section right
```

Cam Stream requires the Quattro shell. A Waybar session cannot load
`BarWidget.qml`.

### No camera appears

```bash
"$cam_stream" camera list
"$cam_stream" camera diagnose
"$cam_stream" doctor
```

The panel offers video-capable or otherwise unclassified V4L2 nodes and
ignores nodes identified as metadata-only. Reconnect the camera, press **R**
in the panel, and check that your login session has read and write access to
the relevant `/dev/video*` device. Fix device access through the system's
udev/logind policy rather than making the device world-writable.

### The preview feels delayed

Switch back to the realtime path and inspect the mode Cam Stream actually
opened:

```bash
"$cam_stream" restart --untimed
"$cam_stream" status
```

`status` reports the active camera plus its capture format, size, and frame
rate. A camera opened at a low frame rate can feel delayed even when the player
is not buffering. If delay remains, send the `status` output and the final
`start camera=...` line from `"$cam_stream" logs 20`; those contain no image or
video data and make device-specific problems reproducible.

### The camera is busy

Only one application can open many camera devices at a time. Close video-call,
recording, or browser software using that input, then retry. When optional
`fuser` is installed, `camera list` and `camera diagnose` report detected users
of each device.

### The preview fails or immediately closes

```bash
"$cam_stream" status
"$cam_stream" logs 100
"$cam_stream" doctor
```

Check that `mpv` and `v4l2-ctl` are installed, then use the reported device and
format errors to choose a different camera in the panel. Cam Stream rotates its
own log when it grows; it does not collect Omarchy or application logs.

### A saved camera was unplugged

Cam Stream falls back to automatic camera selection when possible. Choose
another input in the panel to replace the saved preference.

## License

[MIT](LICENSE) © 2026 Tom Davenport.
