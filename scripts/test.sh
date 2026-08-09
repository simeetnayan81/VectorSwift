#!/usr/bin/env bash
# Unit / integration tests only (VectorSwiftTests).
# Does not build VectorSwiftExample. Mandatory before every commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
vs_cd_root
vs_require_xctest

echo "==> swift --version"
swift --version

echo "==> Test (VectorSwiftTests; example product is not built)"
swift test "$@"

echo "==> Unit tests passed"
