#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAM_STREAM="$ROOT/bin/cam-stream"
TEST_ROOT="$(mktemp -d)"
if [[ ${CAM_STREAM_KEEP_TEST_ROOT:-false} == "true" ]]; then
  printf 'Keeping test root: %s\n' "$TEST_ROOT" >&2
else
  trap 'rm -rf "$TEST_ROOT"' EXIT
fi

PASS=0
FAIL=0

pass() {
  printf 'ok - %s\n' "$1"
  ((PASS += 1))
}

fail() {
  printf 'not ok - %s\n' "$1" >&2
  ((FAIL += 1))
}

assert_eq() {
  local expected="$1" actual="$2" message="$3"
  if [[ $actual == "$expected" ]]; then pass "$message"; else fail "$message (expected '$expected', got '$actual')"; fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  if [[ $haystack == *"$needle"* ]]; then pass "$message"; else fail "$message (missing '$needle')"; fi
}

assert_status() {
  local expected="$1" message="$2"
  shift 2
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  assert_eq "$expected" "$status" "$message"
}

write_stub() {
  local name="$1"
  shift
  local target="$STUB_BIN/$name"
  {
    printf '#!/bin/bash\n'
    printf '%s\n' "$@"
  } > "$target"
  chmod +x "$target"
}

setup_case() {
  CASE_ROOT="$TEST_ROOT/case-$RANDOM-$RANDOM"
  STUB_BIN="$CASE_ROOT/bin"
  DEV_DIR="$CASE_ROOT/dev"
  V4L_DIR="$CASE_ROOT/v4l"
  mkdir -p "$STUB_BIN" "$DEV_DIR" "$V4L_DIR/by-id" "$CASE_ROOT/config" "$CASE_ROOT/state" "$CASE_ROOT/runtime" "$CASE_ROOT/home"
  export PATH="$STUB_BIN:$ORIGINAL_PATH"
  export HOME="$CASE_ROOT/home"
  export XDG_CONFIG_HOME="$CASE_ROOT/config"
  export XDG_STATE_HOME="$CASE_ROOT/state"
  export XDG_RUNTIME_DIR="$CASE_ROOT/runtime"
  export CAM_STREAM_DEV_GLOB="$DEV_DIR/video*"
  export CAM_STREAM_V4L_DIR="$V4L_DIR"
  unset CAM_STREAM_CAMERA CAM_STREAM_WINDOW_SIZE HYPRLAND_INSTANCE_SIGNATURE
  # shellcheck disable=SC2016 # Stub bodies intentionally expand when invoked.
  write_stub v4l2-ctl '
dev=""
while (( $# > 0 )); do
  case "$1" in -d) dev="$2"; shift ;; esac
  shift
done
name="$(basename "$dev")"
if [[ "${*: -1}" == "--list-formats-ext" ]]; then :; fi
case "$name" in
  video0)
    cat <<EOF
Driver Info:
        Card type        : Test Camera
        Bus info         : usb-test-1
        Device Caps
                Video Capture
EOF
    ;;
  video1)
    cat <<EOF
Driver Info:
        Card type        : Test Metadata
        Bus info         : usb-test-2
        Device Caps
                Metadata Capture
EOF
    ;;
  *) exit 1 ;;
esac'
  write_stub fuser 'exit 1'
  # shellcheck disable=SC2016 # Stub body intentionally expands when invoked.
  write_stub hyprctl '
case "$1" in
  clients)
    pid="$(<"$XDG_STATE_HOME/cam-stream/cam-stream.pid")"
    printf "[{\\\"address\\\":\\\"0xabc\\\",\\\"pid\\\":%s,\\\"monitor\\\":0}]\\n" "$pid"
    ;;
  monitors)
    printf "[{\\\"id\\\":0,\\\"x\\\":0,\\\"y\\\":0,\\\"width\\\":1920,\\\"height\\\":1080,\\\"scale\\\":1,\\\"transform\\\":0}]\\n"
    ;;
  dispatch) printf "%s\\n" "$*" >> "${CAM_STREAM_HYPR_LOG:?}" ;;
esac
exit 0'
  # shellcheck disable=SC2016 # Stub body intentionally expands when invoked.
  write_stub mpv '
ipc=""
for arg in "$@"; do
  case "$arg" in --input-ipc-server=*) ipc="${arg#*=}" ;; esac
done
[[ -n "$ipc" ]] && : > "${CAM_STREAM_MPV_IPC_MARKER:?}"
trap "exit 0" TERM INT
while :; do sleep 0.1; done'
  export CAM_STREAM_HYPR_LOG="$CASE_ROOT/hypr.log"
  export CAM_STREAM_MPV_IPC_MARKER="$CASE_ROOT/mpv-started"
}

ORIGINAL_PATH="$PATH"

setup_case
output="$($CAM_STREAM camera list --json)"
assert_eq '{"schemaVersion":1,"cameras":[]}' "$output" "camera JSON is valid when no cameras exist"

setup_case
: > "$DEV_DIR/video0"
: > "$DEV_DIR/video1"
ln -s "$DEV_DIR/video0" "$V4L_DIR/by-id/test-camera-video-index0"
output="$($CAM_STREAM camera list --json)"
assert_contains "$output" '"index":1' "camera JSON includes a 1-based index"
assert_contains "$output" '"stablePath":"'"$V4L_DIR"'/by-id/test-camera-video-index0"' "camera JSON exposes a stable path"
assert_contains "$output" '"role":"capture"' "camera JSON identifies capture nodes"
assert_contains "$output" '"role":"metadata"' "camera JSON identifies metadata nodes"

output="$($CAM_STREAM camera select 1)"
assert_contains "$output" 'Selected camera:' "camera selection succeeds"
config="$(<"$XDG_CONFIG_HOME/cam-stream/config")"
assert_contains "$config" "camera=$V4L_DIR/by-id/test-camera-video-index0" "camera selection persists stable path"
output="$($CAM_STREAM camera list --json)"
assert_contains "$output" '"selected":true' "camera JSON marks the selected camera"

assert_status 1 "metadata-only selection is rejected" "$CAM_STREAM" camera select 2
output="$($CAM_STREAM camera select 2 --force)"
assert_contains "$output" '(metadata)' "forced metadata selection is retained for compatibility"

setup_case
: > "$DEV_DIR/video1"
assert_status 1 "automatic selection never launches a metadata-only node" "$CAM_STREAM" start

setup_case
: > "$DEV_DIR/video0"
output="$($CAM_STREAM settings set mirror true)"
assert_contains "$output" 'Saved mirror=true' "mirror setting is accepted"
$CAM_STREAM settings set latency smooth >/dev/null
output="$($CAM_STREAM settings show --json)"
assert_eq '{"schemaVersion":1,"mirror":true,"latencyMode":"smooth","windowSize":"480x270"}' "$output" "settings JSON reports persisted values"

output="$($CAM_STREAM status --json)"
assert_contains "$output" '"running":false' "status JSON reports stopped"
assert_contains "$output" '"pid":null' "stopped status has a null PID"
assert_contains "$output" '"mirror":true' "stopped status reports configured mirror default"
assert_contains "$output" '"latencyMode":"smooth"' "stopped status reports configured latency default"
assert_contains "$output" '"appId":"io.github.tomdavenport.cam-stream"' "status exposes the non-colliding app ID"

output="$($CAM_STREAM start)"
assert_contains "$output" 'Started camera preview' "explicit start launches the preview"
if [[ -f $CAM_STREAM_MPV_IPC_MARKER ]]; then pass "mpv stub was invoked"; else fail "mpv stub was invoked"; fi
pid="$(<"$XDG_STATE_HOME/cam-stream/cam-stream.pid")"
if kill -0 "$pid" 2>/dev/null; then pass "started process remains alive"; else fail "started process remains alive"; fi
cmdline="$(tr '\0' '\n' < "/proc/$pid/cmdline")"
assert_contains "$cmdline" '--wayland-app-id=io.github.tomdavenport.cam-stream' "launch uses the unique Wayland app ID"
assert_contains "$cmdline" '--title=Cam Stream Camera Preview' "launch uses the unique window title"
assert_contains "$cmdline" '--focus-on=never' "launch uses the current mpv non-focus option"
assert_contains "$cmdline" 'lavfi=[setpts=PTS-STARTPTS],hflip' "persisted mirror is applied"
assert_contains "$cmdline" '--video-sync=display-resample' "persisted smooth mode is applied"
output="$($CAM_STREAM status --json)"
assert_contains "$output" '"running":true' "status JSON reports running"
assert_contains "$output" '"camera":"'"$DEV_DIR"'/video0"' "status reports the active camera"

output="$($CAM_STREAM start)"
assert_contains "$output" 'already running' "start is idempotent"
pid_after="$(<"$XDG_STATE_HOME/cam-stream/cam-stream.pid")"
assert_eq "$pid" "$pid_after" "idempotent start does not replace the process"

output="$($CAM_STREAM restart --untimed --no-mirror)"
assert_contains "$output" 'Started camera preview' "restart replaces the preview"
new_pid="$(<"$XDG_STATE_HOME/cam-stream/cam-stream.pid")"
if [[ $new_pid != "$pid" ]]; then pass "restart creates a new process"; else fail "restart creates a new process"; fi
new_cmdline="$(tr '\0' '\n' < "/proc/$new_pid/cmdline")"
if [[ $new_cmdline != *hflip* ]]; then pass "--no-mirror removes the filter"; else fail "--no-mirror removes the filter"; fi
assert_contains "$new_cmdline" '--untimed' "--untimed reaches mpv"
settings="$($CAM_STREAM settings show --json)"
assert_contains "$settings" '"mirror":false' "explicit launch mirror is persisted"
assert_contains "$settings" '"latencyMode":"untimed"' "explicit launch latency is persisted"

output="$($CAM_STREAM stop)"
assert_contains "$output" 'Stopped camera preview' "explicit stop terminates the preview"
output="$($CAM_STREAM stop)"
assert_contains "$output" 'already stopped' "stop is idempotent"

output="$($CAM_STREAM toggle)"
assert_contains "$output" 'Started camera preview' "explicit toggle starts when stopped"
output="$($CAM_STREAM toggle)"
assert_contains "$output" 'Stopped camera preview' "explicit toggle stops when running"

setup_case
: > "$DEV_DIR/video0"
export HYPRLAND_INSTANCE_SIGNATURE="test"
$CAM_STREAM start >/dev/null
for _ in {1..100}; do
  [[ -s $CAM_STREAM_HYPR_LOG ]] && break
  sleep 0.05
done
hypr_calls=""
if [[ -r $CAM_STREAM_HYPR_LOG ]]; then
  hypr_calls="$(<"$CAM_STREAM_HYPR_LOG")"
fi
assert_contains "$hypr_calls" 'hl.dsp.window.float' "Quattro floating dispatch is attempted"
assert_contains "$hypr_calls" 'hl.dsp.window.resize' "Quattro numeric resize dispatch is attempted"
assert_contains "$hypr_calls" 'x = 1400, y = 770' "Quattro positioning uses monitor geometry"
$CAM_STREAM stop >/dev/null

setup_case
: > "$DEV_DIR/video0"
output="$($CAM_STREAM doctor --json)"
assert_contains "$output" '"ok":true' "doctor JSON passes with required dependencies and a camera"
assert_contains "$output" '"name":"mpv","status":"pass"' "doctor checks mpv"

setup_case
status=0
output="$($CAM_STREAM doctor --json)" || status=$?
assert_eq 1 "$status" "doctor fails when no camera is present"
assert_contains "$output" '"ok":false' "failing doctor JSON remains machine readable"

setup_case
assert_status 2 "unknown command returns usage status" "$CAM_STREAM" wat
assert_status 2 "missing option value returns usage status" "$CAM_STREAM" start --fps
assert_status 2 "invalid setting returns usage status" "$CAM_STREAM" settings set mirror maybe
assert_status 2 "invalid log count returns usage status" "$CAM_STREAM" logs zero

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
