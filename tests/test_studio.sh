#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAM_STREAM="$ROOT/bin/cam-stream"
TEST_ROOT="$(mktemp -d -t cam-stream-studio-test.XXXXXXXX)"
ORIGINAL_PATH="$PATH"
PASS=0
FAIL=0
CASE_ROOT=""

cleanup_processes() {
  local pid_file pid cmdline
  while IFS= read -r pid_file; do
    [[ -r $pid_file ]] || continue
    read -r pid < "$pid_file" || true
    [[ ${pid:-} =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || continue
    cmdline="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ $cmdline == *"$TEST_ROOT"* ]]; then
      kill "$pid" 2>/dev/null || true
    fi
  done < <(find "$TEST_ROOT" -type f -name '*.pid' 2>/dev/null || true)
}

cleanup() {
  cleanup_processes
  if [[ ${CAM_STREAM_KEEP_TEST_ROOT:-false} == "true" ]]; then
    printf 'Keeping test root: %s\n' "$TEST_ROOT" >&2
  elif [[ -n $TEST_ROOT && -d $TEST_ROOT && $TEST_ROOT == /tmp/cam-stream-studio-test.* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

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
  if [[ $actual == "$expected" ]]; then
    pass "$message"
  else
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" message="$3"
  if [[ $haystack == *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (missing '$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" message="$3"
  if [[ $haystack != *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (unexpected '$needle')"
  fi
}

assert_status() {
  local expected="$1" message="$2"
  shift 2
  local status=0
  "$@" >/dev/null 2>&1 || status=$?
  assert_eq "$expected" "$status" "$message"
}

assert_file_contains() {
  local file="$1" needle="$2" message="$3" contents=""
  [[ -r $file ]] && contents="$(<"$file")"
  assert_contains "$contents" "$needle" "$message"
}

assert_file_not_contains() {
  local file="$1" needle="$2" message="$3" contents=""
  [[ -r $file ]] && contents="$(<"$file")"
  assert_not_contains "$contents" "$needle" "$message"
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
  cleanup_processes
  CASE_ROOT="$TEST_ROOT/case-$RANDOM-$RANDOM"
  STUB_BIN="$CASE_ROOT/bin"
  DEV_DIR="$CASE_ROOT/dev"
  V4L_DIR="$CASE_ROOT/v4l"
  mkdir -p "$STUB_BIN" "$DEV_DIR" "$V4L_DIR/by-id" \
    "$CASE_ROOT/config" "$CASE_ROOT/state" "$CASE_ROOT/runtime" \
    "$CASE_ROOT/home" "$CASE_ROOT/videos" "$CASE_ROOT/secrets"

  export PATH="$STUB_BIN:$ORIGINAL_PATH"
  export HOME="$CASE_ROOT/home"
  export XDG_CONFIG_HOME="$CASE_ROOT/config"
  export XDG_STATE_HOME="$CASE_ROOT/state"
  export XDG_RUNTIME_DIR="$CASE_ROOT/runtime"
  export XDG_VIDEOS_DIR="$CASE_ROOT/videos"
  export CAM_STREAM_DEV_GLOB="$DEV_DIR/video*"
  export CAM_STREAM_V4L_DIR="$V4L_DIR"
  export CAM_STREAM_STUDIO_GSR_LOG="$CASE_ROOT/gsr.args"
  export CAM_STREAM_STUDIO_GSR_CLI_LOG="$CASE_ROOT/gsr-cli.args"
  export CAM_STREAM_STUDIO_PICKER_LOG="$CASE_ROOT/picker.args"
  export CAM_STREAM_STUDIO_FFMPEG_LOG="$CASE_ROOT/ffmpeg.args"
  export CAM_STREAM_STUDIO_NOTIFY_LOG="$CASE_ROOT/notify.args"
  export CAM_STREAM_STUDIO_OPEN_LOG="$CASE_ROOT/open.args"
  export CAM_STREAM_STUDIO_SECRET_DIR="$CASE_ROOT/secrets"
  export CAM_STREAM_STUDIO_STUB_PID="$CASE_ROOT/gsr-stub.pid"
  export CAM_STREAM_STUDIO_STUB_OUTPUT="$CASE_ROOT/gsr-output"
  export CAM_STREAM_STUDIO_STUB_REPLAY_DIR="$CASE_ROOT/gsr-replay-dir"
  export CAM_STREAM_STUDIO_STUB_PAUSED="$CASE_ROOT/gsr-paused"
  export CAM_STREAM_STUDIO_EXTERNAL_PID="$CASE_ROOT/external-gsr.pid"
  export CAM_STREAM_MPV_PID_FILE="$CASE_ROOT/mpv-stub.pid"
  export CAM_STREAM_MPV_IPC_MARKER="$CASE_ROOT/mpv-started"
  export CAM_STREAM_GSR_BIN="$STUB_BIN/gpu-screen-recorder"
  export CAM_STREAM_GSR_CLI_BIN="$STUB_BIN/gsr-cli"
  export CAM_STREAM_SECRET_TOOL_BIN="$STUB_BIN/secret-tool"
  export CAM_STREAM_FFMPEG_BIN="$STUB_BIN/ffmpeg"
  export CAM_STREAM_CAPTURE_PICKER_BIN="$STUB_BIN/missing-capture-picker"
  export CAM_STREAM_FOCUSED_MONITOR_BIN="$STUB_BIN/omarchy-hyprland-monitor-focused"
  export CAM_STREAM_HYPRCTL_BIN="$STUB_BIN/hyprctl"
  CAM_STREAM_JQ_BIN="$(command -v jq)"
  export CAM_STREAM_JQ_BIN
  export CAM_STREAM_SLURP_BIN="$STUB_BIN/slurp"
  export CAM_STREAM_XDG_USER_DIR_BIN="$STUB_BIN/missing-xdg-user-dir"
  export CAM_STREAM_OUTPUT_DIR="$CASE_ROOT/videos"
  unset CAM_STREAM_CAMERA CAM_STREAM_WINDOW_SIZE HYPRLAND_INSTANCE_SIGNATURE
  unset CAM_STREAM_CAPTURE_TARGET
  unset CAM_STREAM_STUDIO_FAIL_GSR CAM_STREAM_STUDIO_FAIL_GSR_CLI
  unset CAM_STREAM_STUDIO_FAIL_SECRET CAM_STREAM_STUDIO_FAIL_FFMPEG
  unset CAM_STREAM_STUDIO_SKIP_RECORD_OUTPUT

  # Camera discovery remains isolated from the host's /dev and udev state.
  # shellcheck disable=SC2016
  write_stub v4l2-ctl '
dev=""
while (( $# > 0 )); do
  case "$1" in -d) dev="$2"; shift ;; esac
  shift
done
case "$(basename "$dev")" in
  video0)
    cat <<EOF
Driver Info:
        Card type        : Studio Test Camera
        Bus info         : usb-studio-test
        Device Caps
                Video Capture
EOF
    ;;
  *) exit 1 ;;
esac'
  write_stub fuser 'exit 1'

  # shellcheck disable=SC2016
  write_stub mpv '
printf "%s\n" "$$" > "${CAM_STREAM_MPV_PID_FILE:?}"
for arg in "$@"; do
  case "$arg" in --input-ipc-server=*) : > "${CAM_STREAM_MPV_IPC_MARKER:?}" ;; esac
done
trap "exit 0" TERM INT
while :; do sleep 0.1; done'

  # The fake recorder binds only an isolated Unix socket and creates no capture.
  # shellcheck disable=SC2016
  write_stub gpu-screen-recorder '
set -euo pipefail
if [[ ${1:-} == --help ]]; then printf "usage: gpu-screen-recorder -ipc socket\n"; exit 0; fi
printf "call" >> "${CAM_STREAM_STUDIO_GSR_LOG:?}"
original_args=("$@")
ipc=""; output=""; replay_dir=""
while (( $# > 0 )); do
  printf "\t%s" "$1" >> "${CAM_STREAM_STUDIO_GSR_LOG:?}"
  case "$1" in
    -ipc) ipc="${2:-}" ;;
    -o) output="${2:-}" ;;
    -ro) replay_dir="${2:-}" ;;
  esac
  shift
done
printf "\n" >> "${CAM_STREAM_STUDIO_GSR_LOG:?}"
[[ ${CAM_STREAM_STUDIO_FAIL_GSR:-false} != true ]] || exit 41
[[ -n $ipc ]] || exit 42
printf "%s\n" "$$" > "${CAM_STREAM_STUDIO_STUB_PID:?}"
printf "%s\n" "$output" > "${CAM_STREAM_STUDIO_STUB_OUTPUT:?}"
printf "%s\n" "$replay_dir" > "${CAM_STREAM_STUDIO_STUB_REPLAY_DIR:?}"
exec -a "$0" python3 - "$ipc" -- "${original_args[@]}" <<PY
import os
import signal
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen(1)
running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while running:
    time.sleep(0.02)
server.close()
try:
    os.unlink(path)
except FileNotFoundError:
    pass
PY'

  # shellcheck disable=SC2016
  write_stub gsr-cli '
set -euo pipefail
if [[ ${1:-} == --help ]]; then printf "usage: gsr-cli -ipc socket command\n"; exit 0; fi
printf "call" >> "${CAM_STREAM_STUDIO_GSR_CLI_LOG:?}"
for arg in "$@"; do printf "\t%s" "$arg" >> "${CAM_STREAM_STUDIO_GSR_CLI_LOG:?}"; done
printf "\n" >> "${CAM_STREAM_STUDIO_GSR_CLI_LOG:?}"
[[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != all ]] || exit 51
command=""
while (( $# > 0 )); do
  case "$1" in -ipc) shift ;; *) command="$1"; shift; break ;; esac
  shift
done
pid=""
[[ -r ${CAM_STREAM_STUDIO_STUB_PID:?} ]] && read -r pid < "${CAM_STREAM_STUDIO_STUB_PID:?}" || true
pid_is_live() {
  local state=""
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
  [[ -n $state && $state != Z* ]]
}
case "$command" in
  status)
    pid_is_live && { printf "running\n"; exit 0; }
    printf "not running\n"
    exit 1
    ;;
  set-paused)
    [[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != pause ]] || exit 52
    printf "%s\n" "${1:-true}" > "${CAM_STREAM_STUDIO_STUB_PAUSED:?}"
    ;;
  toggle-pause)
    [[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != pause ]] || exit 52
    if [[ -r ${CAM_STREAM_STUDIO_STUB_PAUSED:?} && $(<"${CAM_STREAM_STUDIO_STUB_PAUSED:?}") == true ]]; then
      printf "false\n" > "${CAM_STREAM_STUDIO_STUB_PAUSED:?}"
    else
      printf "true\n" > "${CAM_STREAM_STUDIO_STUB_PAUSED:?}"
    fi
    ;;
  start-replay-recording)
    [[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != replay-start ]] || exit 53
    ;;
  stop-replay-recording)
    [[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != replay-stop ]] || exit 54
    replay_dir=""
    [[ -r ${CAM_STREAM_STUDIO_STUB_REPLAY_DIR:?} ]] && read -r replay_dir < "${CAM_STREAM_STUDIO_STUB_REPLAY_DIR:?}" || true
    [[ -n $replay_dir ]] || exit 55
    mkdir -p "$replay_dir"
    replay_file="$replay_dir/cam-stream-stub.flv"
    printf "fake flv\n" > "$replay_file"
    printf "%s\n" "$replay_file"
    ;;
  stop)
    [[ ${CAM_STREAM_STUDIO_FAIL_GSR_CLI:-false} != stop ]] || exit 56
    output=""
    [[ -r ${CAM_STREAM_STUDIO_STUB_OUTPUT:?} ]] && read -r output < "${CAM_STREAM_STUDIO_STUB_OUTPUT:?}" || true
    if [[ -n $output && $output != *://* && ${CAM_STREAM_STUDIO_SKIP_RECORD_OUTPUT:-false} != true ]]; then
      mkdir -p "$(dirname "$output")"
      printf "fake recording\n" > "$output"
    fi
    if [[ $pid =~ ^[0-9]+$ ]]; then
      kill "$pid" 2>/dev/null || true
      for _ in {1..100}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.01; done
    fi
    [[ -n $output && $output != *://* ]] && printf "%s\n" "$output"
    ;;
  *) exit 57 ;;
esac'

  # Report only explicitly-created, isolated fake recorder processes.
  # shellcheck disable=SC2016
  write_stub pgrep '
for pid_file in "${CAM_STREAM_STUDIO_EXTERNAL_PID:?}" "${CAM_STREAM_STUDIO_STUB_PID:?}"; do
  [[ -r $pid_file ]] || continue
  read -r pid < "$pid_file" || continue
  [[ $pid =~ ^[0-9]+$ ]] || continue
  state="$(ps -o stat= -p "$pid" 2>/dev/null || true)"
  [[ -n $state && $state != Z* ]] && printf "%s\n" "$pid"
done'

  # shellcheck disable=SC2016
  write_stub secret-tool '
set -euo pipefail
action="${1:-}"; shift || true
profile="default"; previous=""
for arg in "$@"; do
  if [[ $previous == profile || $previous == destination ]]; then profile="$arg"; fi
  previous="$arg"
done
secret_file="${CAM_STREAM_STUDIO_SECRET_DIR:?}/$profile"
case "$action" in
  store)
    IFS= read -r secret || true
    [[ ${CAM_STREAM_STUDIO_FAIL_SECRET:-false} != true ]] || exit 61
    (umask 077; printf "%s" "$secret" > "$secret_file")
    ;;
  lookup)
    [[ ${CAM_STREAM_STUDIO_FAIL_SECRET:-false} != true ]] || exit 61
    [[ -r $secret_file ]] || exit 1
    cat "$secret_file"
    ;;
  clear)
    [[ ${CAM_STREAM_STUDIO_FAIL_SECRET:-false} != true ]] || exit 61
    rm -f -- "$secret_file"
    ;;
  *) exit 62 ;;
esac'

  # shellcheck disable=SC2016
  write_stub ffmpeg '
set -euo pipefail
printf "call" >> "${CAM_STREAM_STUDIO_FFMPEG_LOG:?}"
input=""; output=""; previous=""
for arg in "$@"; do
  printf "\t%s" "$arg" >> "${CAM_STREAM_STUDIO_FFMPEG_LOG:?}"
  [[ $previous == -i ]] && input="$arg"
  previous="$arg"
  output="$arg"
done
printf "\n" >> "${CAM_STREAM_STUDIO_FFMPEG_LOG:?}"
[[ ${CAM_STREAM_STUDIO_FAIL_FFMPEG:-false} != true ]] || exit 71
[[ -r $input ]] || exit 72
mkdir -p "$(dirname "$output")"
cp -- "$input" "$output"'

  # shellcheck disable=SC2016
  write_stub omarchy-hyprland-monitor-focused 'printf "DP-TEST\n"'
  # shellcheck disable=SC2016
  write_stub hyprctl '
case "${1:-}" in
  clients)
    printf "%s\n" '\''[{"at":[100,200],"size":[1280,720],"mapped":true,"hidden":false,"monitor":0,"workspace":{"id":1}}]'\''
    ;;
  monitors)
    printf "%s\n" '\''[{"id":0,"name":"DP-TEST","focused":true,"x":0,"y":0,"width":1920,"height":1080,"scale":1,"transform":0,"activeWorkspace":{"id":1}}]'\''
    ;;
  *) exit 1 ;;
esac'
  # shellcheck disable=SC2016
  write_stub slurp '
printf "call" >> "${CAM_STREAM_STUDIO_PICKER_LOG:?}"
for arg in "$@"; do printf "\t%s" "$arg" >> "${CAM_STREAM_STUDIO_PICKER_LOG:?}"; done
printf "\n" >> "${CAM_STREAM_STUDIO_PICKER_LOG:?}"
cat >/dev/null || true
printf "100,200 1280x720\n"'
  # shellcheck disable=SC2016
  write_stub pactl 'case "${1:-}" in get-default-source) printf "studio_source\n" ;; get-default-sink) printf "studio_sink\n" ;; esac'
  write_stub wpctl 'exit 0'
  # shellcheck disable=SC2016
  write_stub notify-send 'printf "%s\n" "$*" >> "${CAM_STREAM_STUDIO_NOTIFY_LOG:?}"'
  # shellcheck disable=SC2016
  write_stub xdg-open 'printf "%s\n" "$*" >> "${CAM_STREAM_STUDIO_OPEN_LOG:?}"'
}

json_value() {
  local json="$1" expression="$2"
  jq -r "$expression" <<< "$json"
}

assert_json_eq() {
  local json="$1" expression="$2" expected="$3" message="$4" actual="__invalid_json__"
  actual="$(json_value "$json" "$expression" 2>/dev/null || true)"
  assert_eq "$expected" "$actual" "$message"
}

wait_for_file() {
  local file="$1"
  for _ in {1..100}; do
    [[ -e $file ]] && return 0
    sleep 0.02
  done
  return 1
}

start_fake_external_gsr() {
  # shellcheck disable=SC2016
  write_stub external-gsr '
exec -a gpu-screen-recorder python3 - "$0" <<PY
import signal
import time

running = True

def stop(_signum, _frame):
    global running
    running = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while running:
    time.sleep(0.02)
PY'
  "$STUB_BIN/external-gsr" >/dev/null 2>&1 &
  local pid=$!
  printf '%s\n' "$pid" > "$CAM_STREAM_STUDIO_EXTERNAL_PID"
  printf '%s\n' "$pid"
}

configure_live() {
  local profile="$1" server="$2" key="$3"
  printf '%s\n' "$key" | "$CAM_STREAM" live configure "$profile" --server "$server" --key-stdin
}

find_output() {
  local suffix="$1"
  find "$CASE_ROOT" -type f -name "*$suffix" -print -quit 2>/dev/null || true
}

# Defaults and additive status preserve the stable camera API.
setup_case
status_json="$($CAM_STREAM status --json)"
assert_json_eq "$status_json" '.schemaVersion' '1' "camera status keeps schema version 1"
assert_json_eq "$status_json" '.running' 'false' "camera status keeps the preview running flag"
assert_json_eq "$status_json" '.pid' 'null' "camera status keeps the preview PID field"
assert_json_eq "$status_json" '.appId' 'io.github.tomdavenport.cam-stream' "camera status keeps the preview app ID"
assert_json_eq "$status_json" '.activity.running' 'false' "camera status adds idle activity"
assert_json_eq "$status_json" '.activity.mode' 'idle' "idle activity reports idle mode"
assert_json_eq "$status_json" '.activity.state' 'idle' "idle activity reports its state"
assert_json_eq "$status_json" '.activity.paused' 'false' "idle activity is not paused"
assert_json_eq "$status_json" '.activity.elapsedSeconds' '0' "idle activity has zero elapsed seconds"
assert_json_eq "$status_json" '.activity.outputPath' 'null' "idle activity has no active output"
assert_json_eq "$status_json" '.activity.error' 'null' "idle activity starts without an error"

settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.captureMode' 'fullscreen' "capture defaults to fullscreen"
assert_json_eq "$settings_json" '.audioMode' 'none' "audio has an explicit privacy-safe default"
assert_json_eq "$settings_json" '.quality' '1080p60' "live quality defaults to 1080p60"
assert_json_eq "$settings_json" '.destination' 'x' "live destination defaults to X"
assert_json_eq "$settings_json" '.localCopy' 'true' "live local copy defaults on"
assert_json_eq "$settings_json" '.profiles.x.configured' 'false' "X starts unconfigured"
assert_json_eq "$settings_json" '.profiles.custom.configured' 'false' "custom streaming starts unconfigured"

# Every non-secret activity setting persists across helper processes.
$CAM_STREAM activity set capture window >/dev/null
$CAM_STREAM activity set audio both >/dev/null
$CAM_STREAM activity set quality 720p30 >/dev/null
$CAM_STREAM activity set destination custom >/dev/null
$CAM_STREAM activity set local-copy false >/dev/null
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.captureMode' 'window' "capture setting persists"
assert_json_eq "$settings_json" '.audioMode' 'both' "audio setting persists"
assert_json_eq "$settings_json" '.quality' '720p30' "quality setting persists"
assert_json_eq "$settings_json" '.destination' 'custom' "destination setting persists"
assert_json_eq "$settings_json" '.localCopy' 'false' "local-copy setting persists"

assert_status 2 "invalid capture mode is rejected" "$CAM_STREAM" activity set capture desktop
assert_status 2 "invalid audio mode is rejected" "$CAM_STREAM" activity set audio system
assert_status 2 "invalid quality is rejected" "$CAM_STREAM" activity set quality 4k120
assert_status 2 "invalid destination is rejected" "$CAM_STREAM" activity set destination youtube
assert_status 2 "invalid local-copy value is rejected" "$CAM_STREAM" activity set local-copy maybe

# A record session is owned through its PID and IPC and never changes camera state.
setup_case
: > "$DEV_DIR/video0"
ln -s "$DEV_DIR/video0" "$V4L_DIR/by-id/studio-camera-video-index0"
$CAM_STREAM start >/dev/null
camera_pid="$(json_value "$($CAM_STREAM status --json)" '.pid')"
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
record_start="$($CAM_STREAM record start)"
assert_contains "$record_start" 'record' "record start reports the operation"
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.running' 'true' "record status reports running"
assert_json_eq "$activity_json" '.mode' 'record' "record status reports record mode"
assert_json_eq "$activity_json" '.state' 'recording' "record status reports recording"
assert_json_eq "$activity_json" '.paused' 'false' "fresh recording is not paused"
activity_pid="$(json_value "$activity_json" '.pid')"
if [[ $activity_pid =~ ^[0-9]+$ && $activity_pid != "$camera_pid" ]]; then
  pass "recording has an independently-owned PID"
else
  fail "recording has an independently-owned PID"
fi
if [[ -S $XDG_RUNTIME_DIR/cam-stream/gsr.sock ]]; then
  pass "recording owns an isolated GSR IPC socket"
else
  fail "recording owns an isolated GSR IPC socket"
fi
status_json="$($CAM_STREAM status --json)"
assert_json_eq "$status_json" '.running' 'true' "record start leaves camera running"
assert_json_eq "$status_json" '.pid' "$camera_pid" "record start preserves the camera PID"

$CAM_STREAM record pause >/dev/null
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.state' 'paused' "record pause updates activity state"
assert_json_eq "$activity_json" '.paused' 'true' "record pause exposes the paused boolean"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'set-paused' "pause uses the owned GSR IPC client"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'true' "pause explicitly sets paused state"

$CAM_STREAM record resume >/dev/null
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.state' 'recording' "record resume restores recording state"
assert_json_eq "$activity_json" '.paused' 'false' "record resume clears the paused boolean"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'false' "resume explicitly clears paused state"

record_stop="$($CAM_STREAM record stop)"
assert_contains "$record_stop" '.mp4' "record stop reports the saved MP4"
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.running' 'false' "record stop returns activity to idle"
status_json="$($CAM_STREAM status --json)"
assert_json_eq "$status_json" '.running' 'true' "record stop leaves camera running"
assert_json_eq "$status_json" '.pid' "$camera_pid" "record stop preserves the camera PID"
$CAM_STREAM stop >/dev/null

# Fullscreen is immediate; window and region use the matching Omarchy picker mode.
for capture_mode in fullscreen window region; do
  setup_case
  $CAM_STREAM activity set capture "$capture_mode" >/dev/null
  $CAM_STREAM record start >/dev/null
  gsr_args="$(<"$CAM_STREAM_STUDIO_GSR_LOG")"
  case "$capture_mode" in
    fullscreen)
      assert_contains "$gsr_args" 'DP-TEST' "fullscreen captures the focused monitor"
      if [[ ! -e $CAM_STREAM_STUDIO_PICKER_LOG ]]; then
        pass "fullscreen does not open a picker"
      else
        fail "fullscreen does not open a picker"
      fi
      ;;
    window)
      assert_file_contains "$CAM_STREAM_STUDIO_PICKER_LOG" '-r' "window capture invokes slurp with window rectangles"
      assert_contains "$gsr_args" '1280x720+100+200' "window picker geometry reaches GSR"
      ;;
    region)
      assert_file_contains "$CAM_STREAM_STUDIO_PICKER_LOG" 'call' "region capture invokes slurp"
      assert_file_not_contains "$CAM_STREAM_STUDIO_PICKER_LOG" '-r' "region capture remains freeform"
      assert_contains "$gsr_args" '1280x720+100+200' "region picker geometry reaches GSR"
      ;;
  esac
  $CAM_STREAM record stop >/dev/null
done

# A user-dirs file is data, not shell code; malformed content falls back safely.
setup_case
unset CAM_STREAM_OUTPUT_DIR XDG_VIDEOS_DIR
user_dirs_marker="$CASE_ROOT/user-dirs-was-executed"
# shellcheck disable=SC2016 # Command substitution belongs to the malicious fixture.
printf 'XDG_VIDEOS_DIR="$(touch %s)"\n' "$user_dirs_marker" > "$XDG_CONFIG_HOME/user-dirs.dirs"
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM record start >/dev/null
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" "$HOME/Videos/cam-stream-recording-" "malicious user-dirs content falls back to HOME/Videos"
if [[ ! -e $user_dirs_marker ]]; then
  pass "user-dirs content is never sourced or executed"
else
  fail "user-dirs content is never sourced or executed"
fi
$CAM_STREAM record stop >/dev/null

# X requires encrypted RTMPS; custom destinations may deliberately use RTMP.
setup_case
status=0
reject_output="$(printf '%s\n' 'reject-me' | "$CAM_STREAM" live configure x --server 'rtmp://x.example.test/live' --key-stdin 2>&1)" || status=$?
if (( status != 0 )); then pass "X rejects an unencrypted RTMP server"; else fail "X rejects an unencrypted RTMP server"; fi
assert_not_contains "$reject_output" 'reject-me' "rejected X configuration never echoes the key"

# Server URLs must be structural endpoints, never credential or option carriers.
malicious_profiles=(x custom x)
malicious_servers=(
  'rtmps://user@x.example.test/live'
  'rtmp://custom.example.test/live?token=unsafe'
  'rtmps://x.example.test/live#fragment'
)
malicious_labels=('userinfo' 'query string' 'fragment')
for index in "${!malicious_servers[@]}"; do
  setup_case
  malicious_key="server-validation-secret-$index"
  status=0
  malicious_output="$(printf '%s\n' "$malicious_key" | "$CAM_STREAM" live configure "${malicious_profiles[index]}" --server "${malicious_servers[index]}" --key-stdin 2>&1)" || status=$?
  assert_eq 2 "$status" "live server rejects ${malicious_labels[index]}"
  assert_not_contains "$malicious_output" "$malicious_key" "${malicious_labels[index]} rejection never echoes the key"
  assert_not_contains "$malicious_output" "${malicious_servers[index]}" "${malicious_labels[index]} rejection never echoes the server"
  assert_file_not_contains "$XDG_CONFIG_HOME/cam-stream/config" "${malicious_servers[index]}" "${malicious_labels[index]} server is not persisted"
done

# Keys are opaque single tokens; surrounding or embedded whitespace is rejected.
whitespace_keys=(' leading-whitespace-secret' 'trailing-whitespace-secret ' $'internal\twhitespace-secret')
for whitespace_key in "${whitespace_keys[@]}"; do
  setup_case
  status=0
  whitespace_output="$(printf '%s\n' "$whitespace_key" | "$CAM_STREAM" live configure x --server 'rtmps://x.example.test/live' --key-stdin 2>&1)" || status=$?
  assert_eq 1 "$status" "stream key whitespace is rejected"
  assert_not_contains "$whitespace_output" 'whitespace-secret' "whitespace rejection never echoes key material"
  settings_json="$($CAM_STREAM activity settings --json)"
  assert_json_eq "$settings_json" '.profiles.x.configured' 'false' "rejected whitespace key does not configure X"
done

custom_key='custom-secret-42'
custom_output="$(configure_live custom 'rtmp://custom.example.test/live' "$custom_key")"
assert_contains "$custom_output" 'custom' "custom RTMP configuration succeeds"
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.profiles.custom.configured' 'true' "custom destination reports configured"
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM live start custom --no-local-copy >/dev/null
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" 'rtmp://custom.example.test/live' "custom RTMP server reaches GSR"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" "$custom_key" "custom key reaches only the recorder process"
$CAM_STREAM live stop >/dev/null
$CAM_STREAM live clear custom >/dev/null
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.profiles.custom.configured' 'false' "clearing custom removes its saved credential"

# Clearing a profile clears its non-secret server even if Secret Service vanished.
setup_case
configure_live x 'rtmps://x.example.test/live' 'clear-without-keyring-secret' >/dev/null
assert_file_contains "$XDG_CONFIG_HOME/cam-stream/config" 'live_server_x=rtmps://x.example.test/live' "configured X server is present before clear"
export CAM_STREAM_SECRET_TOOL_BIN="$STUB_BIN/missing-secret-tool"
status=0
clear_output="$($CAM_STREAM live clear x 2>&1)" || status=$?
assert_eq 0 "$status" "live clear succeeds when Secret Service is unavailable"
assert_not_contains "$clear_output" 'clear-without-keyring-secret' "keyring-unavailable clear never echoes the key"
assert_file_contains "$XDG_CONFIG_HOME/cam-stream/config" 'live_server_x=' "keyring-unavailable clear writes an empty X server"
assert_file_not_contains "$XDG_CONFIG_HOME/cam-stream/config" 'x.example.test' "keyring-unavailable clear removes the X server value"

# A keyring failure is fatal and never falls back to plaintext configuration.
setup_case
export CAM_STREAM_STUDIO_FAIL_SECRET=true
keyring_key='never-plaintext-99'
status=0
keyring_output="$(configure_live x 'rtmps://x.example.test/live' "$keyring_key" 2>&1)" || status=$?
if (( status != 0 )); then pass "keyring failure rejects live configuration"; else fail "keyring failure rejects live configuration"; fi
assert_not_contains "$keyring_output" "$keyring_key" "keyring failure never echoes the key"
assert_file_not_contains "$XDG_CONFIG_HOME/cam-stream/config" "$keyring_key" "keyring failure never writes the key to config"
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.profiles.x.configured' 'false' "failed key storage does not mark X configured"

# X live sends over RTMPS, records locally by default, remuxes losslessly, and leaks no key.
setup_case
x_key='x-super-secret-314159'
configure_output="$(configure_live x 'rtmps://x.example.test/live' "$x_key")"
assert_not_contains "$configure_output" "$x_key" "configure output never echoes the X key"
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.profiles.x.configured' 'true' "X reports configured after keyring storage"
assert_not_contains "$settings_json" 'x.example.test' "settings JSON excludes the X server"
assert_not_contains "$settings_json" "$x_key" "settings JSON excludes the X key"
assert_file_not_contains "$XDG_CONFIG_HOME/cam-stream/config" "$x_key" "config excludes the X key"

export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
live_start="$($CAM_STREAM live start x)"
assert_not_contains "$live_start" "$x_key" "live start output never echoes the key"
activity_json="$($CAM_STREAM live status --json)"
assert_json_eq "$activity_json" '.running' 'true' "live status reports running"
assert_json_eq "$activity_json" '.mode' 'live' "live status reports live mode"
assert_json_eq "$activity_json" '.state' 'sending' "live status says sending"
assert_json_eq "$activity_json" '.destination' 'x' "live status names X without exposing its endpoint"
assert_json_eq "$activity_json" '.localCopy' 'true' "live status reports the default local copy"
assert_not_contains "$activity_json" 'x.example.test' "live status excludes the RTMPS server"
assert_not_contains "$activity_json" "$x_key" "live status excludes the X key"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" 'rtmps://x.example.test/live' "X uses its RTMPS server"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" "$x_key" "X key is delivered to the recorder"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_LOG" '-ro' "live local copy uses GSR's recording output"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'start-replay-recording' "live local copy starts through GSR IPC"

live_stop="$($CAM_STREAM live stop)"
assert_not_contains "$live_stop" "$x_key" "live stop output never echoes the key"
assert_file_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'stop-replay-recording' "live stop finalizes the local copy first"
assert_file_contains "$CAM_STREAM_STUDIO_FFMPEG_LOG" '-c' "local copy invokes FFmpeg"
assert_file_contains "$CAM_STREAM_STUDIO_FFMPEG_LOG" 'copy' "local copy is remuxed without re-encoding"
mp4_output="$(find_output '.mp4')"
if [[ -n $mp4_output && -s $mp4_output ]]; then pass "live local copy produces a playable MP4 artifact"; else fail "live local copy produces a playable MP4 artifact"; fi
assert_file_not_contains "$XDG_STATE_HOME/cam-stream/activity.log" "$x_key" "activity log excludes the X key"
assert_file_not_contains "$XDG_STATE_HOME/cam-stream/activity.log" 'x.example.test' "activity log excludes the X server"
state_contents="$(find "$XDG_STATE_HOME/cam-stream" -maxdepth 1 -type f -print0 2>/dev/null | xargs -0r sed -n '1,240p' 2>/dev/null || true)"
assert_not_contains "$state_contents" "$x_key" "activity state excludes the X key"

# Recorder startup failures also redact live credentials from every user-facing surface.
setup_case
failure_key='failed-start-secret-2718'
configure_live x 'rtmps://x.example.test/live' "$failure_key" >/dev/null
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
export CAM_STREAM_STUDIO_FAIL_GSR=true
status=0
failure_output="$($CAM_STREAM live start x 2>&1)" || status=$?
if (( status != 0 )); then pass "recorder startup failure is reported"; else fail "recorder startup failure is reported"; fi
assert_not_contains "$failure_output" "$failure_key" "startup failure output excludes the X key"
assert_file_not_contains "$XDG_STATE_HOME/cam-stream/activity.log" "$failure_key" "startup failure log excludes the X key"
activity_json="$($CAM_STREAM live status --json)"
assert_not_contains "$activity_json" "$failure_key" "startup failure status excludes the X key"

# The per-launch --no-local-copy override wins without changing the saved default.
setup_case
configure_live x 'rtmps://x.example.test/live' 'no-copy-key' >/dev/null
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM live start x --no-local-copy >/dev/null
activity_json="$($CAM_STREAM live status --json)"
assert_json_eq "$activity_json" '.localCopy' 'false' "--no-local-copy disables only this live session"
assert_file_not_contains "$CAM_STREAM_STUDIO_GSR_LOG" '-ro' "no-copy live omits GSR local recording"
assert_file_not_contains "$CAM_STREAM_STUDIO_GSR_CLI_LOG" 'start-replay-recording' "no-copy live does not start replay recording"
$CAM_STREAM live stop >/dev/null
settings_json="$($CAM_STREAM activity settings --json)"
assert_json_eq "$settings_json" '.localCopy' 'true' "--no-local-copy leaves the saved default enabled"

# Failed remux retains the source FLV as a recovery artifact.
setup_case
configure_live x 'rtmps://x.example.test/live' 'recovery-key' >/dev/null
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM live start x >/dev/null
export CAM_STREAM_STUDIO_FAIL_FFMPEG=true
status=0
remux_output="$($CAM_STREAM live stop 2>&1)" || status=$?
if (( status != 0 )); then pass "a failed live remux is reported"; else fail "a failed live remux is reported"; fi
assert_contains "${remux_output,,}" 'flv' "remux failure reports the recovery format"
flv_output="$(find_output '.flv')"
if [[ -n $flv_output && -s $flv_output ]]; then pass "failed remux preserves the FLV recovery file"; else fail "failed remux preserves the FLV recovery file"; fi

# A successful IPC stop is not a successful recording unless the MP4 exists.
setup_case
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM record start >/dev/null
expected_recording="$(json_value "$($CAM_STREAM record status --json)" '.outputPath')"
export CAM_STREAM_STUDIO_SKIP_RECORD_OUTPUT=true
status=0
missing_recording_output="$($CAM_STREAM record stop 2>&1)" || status=$?
if (( status != 0 )); then pass "record stop fails when GSR creates no MP4"; else fail "record stop fails when GSR creates no MP4"; fi
assert_not_contains "$missing_recording_output" 'Saved recording' "missing MP4 is never reported as saved"
assert_contains "${missing_recording_output,,}" 'record' "missing MP4 failure is explained"
if [[ ! -e $expected_recording ]]; then pass "missing MP4 remains absent"; else fail "missing MP4 remains absent"; fi
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.running' 'false' "missing MP4 clears active recorder state"
assert_json_eq "$activity_json" '.state' 'error' "missing MP4 remains visible as an activity error"
assert_json_eq "$activity_json" '.error != null and (.error | length > 0)' 'true' "missing MP4 stores a diagnostic"

# An unrelated GSR process blocks startup and is never signalled or stopped.
setup_case
external_pid="$(start_fake_external_gsr)"
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
status=0
external_output="$($CAM_STREAM record start 2>&1)" || status=$?
if (( status != 0 )); then pass "an external GSR process blocks record start"; else fail "an external GSR process blocks record start"; fi
assert_contains "${external_output,,}" 'recorder' "external-recorder refusal is explained"
if kill -0 "$external_pid" 2>/dev/null; then pass "external GSR is never killed"; else fail "external GSR is never killed"; fi
if [[ ! -e $CAM_STREAM_STUDIO_GSR_CLI_LOG ]]; then pass "external GSR never receives an IPC command"; else fail "external GSR never receives an IPC command"; fi

# A crashed owned recorder is recognized as stale, cleaned, and can be restarted.
setup_case
export CAM_STREAM_CAPTURE_TARGET='monitor:DP-TEST'
$CAM_STREAM record start >/dev/null
stale_pid="$(<"$XDG_STATE_HOME/cam-stream/activity.pid")"
kill "$stale_pid"
for _ in {1..100}; do
  process_state="$(ps -o stat= -p "$stale_pid" 2>/dev/null || true)"
  [[ -z $process_state || $process_state == Z* ]] && break
  sleep 0.02
done
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.running' 'false' "stale activity is reported stopped"
assert_json_eq "$activity_json" '.state' 'error' "stale activity surfaces a recoverable error"
assert_contains "$(json_value "$activity_json" '.error')" 'exited unexpectedly' "stale activity explains the recorder exit"
if [[ ! -e $XDG_STATE_HOME/cam-stream/activity.pid ]]; then pass "stale PID state is removed"; else fail "stale PID state is removed"; fi
$CAM_STREAM record start >/dev/null
activity_json="$($CAM_STREAM record status --json)"
assert_json_eq "$activity_json" '.running' 'true' "recording restarts after stale-state recovery"
$CAM_STREAM record stop >/dev/null

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
