#!/bin/bash

set -Eeuo pipefail

REPOSITORY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

if (( $# > 1 )); then
  echo "Usage: $0 [repository-root]" >&2
  exit 2
fi

TARGET_ROOT=${1:-$REPOSITORY_ROOT}
if [[ ! -d $TARGET_ROOT ]]; then
  echo "Repository root is not a directory: $TARGET_ROOT" >&2
  exit 2
fi

python3 "$REPOSITORY_ROOT/.github/validate_plugin.py" "$TARGET_ROOT"
