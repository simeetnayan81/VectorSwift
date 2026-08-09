#!/usr/bin/env bash
# Local convenience: run the three *separate* checks in order.
# CI runs the same scripts as independent jobs (build / test / example × OS).
#
#   1. Library build (debug + release)  — ./scripts/build.sh --release
#   2. Unit tests                       — ./scripts/test.sh   (mandatory before commit)
#   3. Example executable               — ./scripts/example.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$(cd "${SCRIPT_DIR}/.." && pwd)"

"${SCRIPT_DIR}/build.sh" --release
"${SCRIPT_DIR}/test.sh"
"${SCRIPT_DIR}/example.sh"

echo "==> All checks passed"
