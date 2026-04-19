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

# Portable flock replacement using mkdir-based locking
bus_append() {
  local lockfile="$1" target="$2" data="$3"
  if command -v flock &>/dev/null; then
    ( flock -x 200; printf "%s\n" "$data" >> "$target" ) 200>"$lockfile"
  else
    local lock_dir="${lockfile}.d" retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
      retries=$((retries + 1))
      if ((retries > 50)); then rm -rf "$lock_dir"; mkdir "$lock_dir" 2>/dev/null || true; break; fi
      sleep 0.1
    done
    trap "rm -rf \"$lock_dir\"" INT TERM
    printf "%s\n" "$data" >> "$target"
    rm -rf "$lock_dir"
  fi
}

# Portable sha256
sha256_hash() {
  if command -v sha256sum &>/dev/null; then
    sha256sum | awk "{print \$1}"
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | awk "{print \$1}"
  else
    openssl dgst -sha256 | awk "{print \$NF}"
  fi
}

# ISO timestamp to epoch
iso_to_epoch() {
  local iso="$1"
  if $_IS_MACOS; then
    date -jf "%Y-%m-%dT%H:%M:%S" "${iso%%Z*}" +%s 2>/dev/null || echo 0
  else
    date -u -d "$iso" +%s 2>/dev/null || echo 0
  fi
}

# N days ago as YYYY-MM-DD
date_days_ago() {
  local days="$1"
  if $_IS_MACOS; then
    date -v "-${days}d" +%Y-%m-%d
  else
    date -d "-${days} days" +%Y-%m-%d
  fi
}

# N hours ago as ISO UTC
date_hours_ago() {
  local hours="$1"
  if $_IS_MACOS; then
    date -u -v "-${hours}H" +%Y-%m-%dT%H:%M:%SZ
  else
    date -u -d "${hours} hours ago" +%Y-%m-%dT%H:%M:%SZ
  fi
}

# Date arithmetic for future dates
date_add_days() {
  local days="$1"
  if $_IS_MACOS; then
    date -v "+${days}d" +%Y-%m-%d
  else
    date -d "+${days} days" +%Y-%m-%d
  fi
}
