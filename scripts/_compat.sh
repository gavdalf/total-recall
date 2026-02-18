#!/usr/bin/env bash
# Cross-platform compatibility helpers (Linux + macOS)
# Sourced by other scripts — not run directly

# Detect OS
_IS_MACOS=false
[[ "$(uname -s)" == "Darwin" ]] && _IS_MACOS=true

# Get file modification time as epoch seconds (portable)
file_mtime() {
  if $_IS_MACOS; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

# Get date N minutes ago as ISO UTC (portable)
date_minutes_ago() {
  local mins="$1"
  if $_IS_MACOS; then
    date -u -v "-${mins}M" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "${mins} minutes ago" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# MD5 hash of stdin (portable)
md5_hash() {
  if command -v md5sum &>/dev/null; then
    md5sum | cut -d' ' -f1
  elif command -v md5 &>/dev/null; then
    md5 -q
  else
    # Last resort: use shasum
    shasum | cut -d' ' -f1
  fi
}

# Check if inotifywait is available (Linux only)
has_inotify() {
  command -v inotifywait &>/dev/null
}

# Check if systemctl --user is available
has_systemd_user() {
  command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1
  return $?
}
