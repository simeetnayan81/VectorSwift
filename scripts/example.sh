#!/usr/bin/env bash
# Build the sample executable only (product VectorSwiftExample).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
vs_cd_root
vs_setup_macos_developer_dir

echo "==> swift --version"
swift --version

echo "==> Build product VectorSwiftExample"
swift build --product VectorSwiftExample

echo "==> Example build passed"
