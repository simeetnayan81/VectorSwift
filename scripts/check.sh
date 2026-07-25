#!/usr/bin/env bash
# Pre-merge / CI gate for VectorSwift.
# Runs the same checks expected to pass before merging to main.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prefer full Xcode on macOS (Command Line Tools alone lack XCTest).
if [[ "$(uname -s)" == "Darwin" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  fi
  if ! xcrun --find xctest >/dev/null 2>&1; then
    echo "error: XCTest not found. Install Xcode and run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
  fi
fi

echo "==> swift --version"
swift --version

echo "==> Resolve package"
swift package resolve

echo "==> Build (debug)"
swift build

echo "==> Build (release)"
swift build -c release

echo "==> Test"
swift test

echo "==> Example binary builds"
swift build --product VectorSwiftExample

echo "==> All checks passed"
