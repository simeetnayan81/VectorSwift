#!/usr/bin/env bash
# Build the VectorSwift *library* only (debug, and optionally release).
# Does not build VectorSwiftExample — use ./scripts/example.sh for that.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
vs_cd_root
vs_setup_macos_developer_dir

RELEASE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) RELEASE=1 ;;
    -h|--help)
      echo "Usage: $0 [--release]"
      echo "  Build target VectorSwift (library). Does not build the example."
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

echo "==> swift --version"
swift --version

echo "==> Resolve package"
swift package resolve

# Use --target, not --product: SwiftPM treats product "VectorSwift" (same name as
# the package) as automatic and ignores --product, then builds the default
# target set — which includes VectorSwiftExample.
echo "==> Build library target VectorSwift (debug)"
swift build --target VectorSwift

if [[ "$RELEASE" -eq 1 ]]; then
  echo "==> Build library target VectorSwift (release)"
  swift build -c release --target VectorSwift
fi

echo "==> Library build passed"
