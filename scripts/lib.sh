# Shared helpers for scripts/ in this repo. Source from sibling scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib.sh
#   source "${SCRIPT_DIR}/lib.sh"
#   vs_cd_root

vs_cd_root() {
  cd "$(cd "$(dirname "${BASH_SOURCE[1]}")/.." && pwd)"
}

# Point macOS at full Xcode so `swift` / XCTest match CI. No-op on Linux.
vs_setup_macos_developer_dir() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
      export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
    fi
  fi
}

# Unit tests need XCTest. Library/example *builds* do not.
vs_require_xctest() {
  vs_setup_macos_developer_dir
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if ! xcrun --find xctest >/dev/null 2>&1; then
      echo "error: XCTest not found. Install Xcode and run:" >&2
      echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
      exit 1
    fi
  fi
}
