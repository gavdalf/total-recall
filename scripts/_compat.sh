#!/usr/bin/env bash
# Cross-platform compatibility helpers (Linux + macOS)
# Sourced by other scripts — not run directly

if [[ -n "${_COMPAT_SH_LOADED:-}" ]]; then
  return 0
fi
readonly _COMPAT_SH_LOADED=1

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

# Get date N days ago as YYYY-MM-DD (portable)
date_days_ago() {
  local days="$1"
  if $_IS_MACOS; then
    date -u -v "-${days}d" '+%Y-%m-%d'
  else
    date -u -d "-${days} days" '+%Y-%m-%d' 2>/dev/null || echo ""
  fi
}

# Get date N days ahead as YYYY-MM-DD (portable)
date_days_ahead() {
  local days="$1"
  if $_IS_MACOS; then
    date -u -v "+${days}d" '+%Y-%m-%d'
  else
    date -u -d "+${days} days" '+%Y-%m-%d' 2>/dev/null || echo ""
  fi
}

# Get date N hours ago as ISO UTC (portable)
date_hours_ago() {
  local hours="$1"
  if $_IS_MACOS; then
    date -u -v "-${hours}H" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "${hours} hours ago" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""
  fi
}

# Convert ISO timestamp to epoch seconds (portable)
iso_to_epoch() {
  local iso="$1"
  if $_IS_MACOS; then
    # Strip trailing Z, parse with -jf
    local clean="${iso%Z}"
    date -jf '%Y-%m-%dT%H:%M:%S' "$clean" '+%s' 2>/dev/null || echo ""
  else
    date -u -d "$iso" '+%s' 2>/dev/null || echo ""
  fi
}

# Convert ISO date (YYYY-MM-DD) to epoch seconds (portable)
iso_date_to_epoch() {
  local iso="$1"
  if $_IS_MACOS; then
    date -jf '%Y-%m-%d' "$iso" '+%s' 2>/dev/null || echo 0
  else
    date -d "$iso" '+%s' 2>/dev/null || echo 0
  fi
}

# Convert date string to ISO UTC (portable, best-effort)
date_to_iso_utc() {
  local input="$1"
  if $_IS_MACOS; then
    # Try common formats
    date -juf '%Y-%m-%dT%H:%M:%S%z' "$input" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || date -juf '%Y-%m-%dT%H:%M:%SZ' "$input" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
      || echo ""
  else
    date -u -d "$input" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo ""
  fi
}

# SHA-256 hash of stdin (portable)
sha256_hash() {
  if command -v sha256sum &>/dev/null; then
    sha256sum | awk '{print $1}'
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | awk '{print $1}'
  else
    # Last resort: openssl
    openssl dgst -sha256 | awk '{print $NF}'
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

# Portable exclusive file lock wrapper
# Usage: portable_flock <lockfile> <command...>
# Replaces: ( flock -x 200; cmd ) 200>lockfile
portable_flock() {
  local lockfile="$1"
  shift
  if command -v flock &>/dev/null; then
    ( flock -x 200; "$@" ) 200>"$lockfile"
  else
    # macOS fallback: mkdir-based atomic lock with retry
    local lock_dir="${lockfile}.d"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
      retries=$((retries + 1))
      if ((retries > 50)); then
        # Stale lock — remove and retry
        rm -rf "$lock_dir"
        if mkdir "$lock_dir" 2>/dev/null; then
          break
        fi
        # Another process grabbed it — keep waiting
        retries=0
        continue
      fi
      sleep 0.1
    done
    # Save existing signal traps before overwriting
    local _prev_int_cmd _prev_term_cmd
    _prev_int_cmd=$(trap -p INT | sed "s/^trap -- '//;s/' INT$//" 2>/dev/null)
    _prev_term_cmd=$(trap -p TERM | sed "s/^trap -- '//;s/' TERM$//" 2>/dev/null)
    trap "rm -rf \"$lock_dir\"; ${_prev_int_cmd:-:}; exit 130" INT
    trap "rm -rf \"$lock_dir\"; ${_prev_term_cmd:-:}; exit 143" TERM
    "$@"
    local rc=$?
    # Restore original traps
    if [[ -n "$_prev_int_cmd" ]]; then eval "trap -- '$_prev_int_cmd' INT"; else trap - INT; fi
    if [[ -n "$_prev_term_cmd" ]]; then eval "trap -- '$_prev_term_cmd' TERM"; else trap - TERM; fi
    rm -rf "$lock_dir"
    return $rc
  fi
}

# Portable exclusive flock with file-descriptor redirection
# Usage: portable_flock_fd <fd_num> <lockfile>
# For use in: ( portable_flock_fd 200 "$LOCK"; echo "$data" >> "$FILE" ) 200>"$LOCK"
# On macOS this is a no-op (caller should use portable_flock instead)
portable_flock_fd() {
  if command -v flock &>/dev/null; then
    flock -x "$1"
  else
    # macOS without flock: warn caller so they know locking is not happening
    echo "[_compat] WARNING: portable_flock_fd is a no-op on macOS (no flock). Use portable_flock instead." >&2
    return 1
  fi
}

# Atomically append a line to a file with exclusive locking (portable)
# Usage: bus_append <lockfile> <target_file> <data>
bus_append() {
  local lockfile="$1" target="$2" data="$3"
  if command -v flock &>/dev/null; then
    ( flock -x 200; printf '%s\n' "$data" >> "$target" ) 200>"$lockfile"
  else
    local lock_dir="${lockfile}.d"
    local retries=0
    while ! mkdir "$lock_dir" 2>/dev/null; do
      retries=$((retries + 1))
      if ((retries > 50)); then rm -rf "$lock_dir"; mkdir "$lock_dir" 2>/dev/null || true; break; fi
      sleep 0.1
    done
    printf '%s\n' "$data" >> "$target"
    rm -rf "$lock_dir"
  fi
}

# Non-blocking lock attempt (portable)
# Usage: if try_lock <lockfile> <fd_num>; then ...; fi
# Returns 0 if lock acquired, 1 if another instance holds it
try_lock() {
  local lockfile="$1" fd="${2:-9}"
  if command -v flock &>/dev/null; then
    eval "exec ${fd}>\"${lockfile}\""
    flock -n "$fd" 2>/dev/null
  else
    local lock_dir="${lockfile}.d"
    if ! mkdir "$lock_dir" 2>/dev/null; then
      return 1
    fi
    # Ensure lock dir is cleaned up on signals
    # Store in module-level vars so release_lock can restore them
    _OPENCLAW_LOCK_PREV_INT=$(trap -p INT | sed "s/^trap -- '//;s/' INT$//" 2>/dev/null)
    _OPENCLAW_LOCK_PREV_TERM=$(trap -p TERM | sed "s/^trap -- '//;s/' TERM$//" 2>/dev/null)
    trap "rm -rf \"$lock_dir\"; ${_OPENCLAW_LOCK_PREV_INT:-:}; exit 130" INT
    trap "rm -rf \"$lock_dir\"; ${_OPENCLAW_LOCK_PREV_TERM:-:}; exit 143" TERM
  fi
}

# Release a lock acquired by try_lock (portable)
# Usage: release_lock <lockfile>
# On Linux with flock this is a no-op (lock auto-releases on fd close).
# On macOS this removes the mkdir-based lock directory.
release_lock() {
  local lockfile="$1"
  if ! command -v flock &>/dev/null; then
    rm -rf "${lockfile}.d"
    # Restore original signal traps
    if [[ -n "${_OPENCLAW_LOCK_PREV_INT:-}" ]]; then
      eval "trap -- '$_OPENCLAW_LOCK_PREV_INT' INT"
    else
      trap - INT
    fi
    if [[ -n "${_OPENCLAW_LOCK_PREV_TERM:-}" ]]; then
      eval "trap -- '$_OPENCLAW_LOCK_PREV_TERM' TERM"
    else
      trap - TERM
    fi
    unset _OPENCLAW_LOCK_PREV_INT _OPENCLAW_LOCK_PREV_TERM
  fi
}

# Rotate a log file if it exceeds a size limit (default 1MB)
# Usage: rotate_log <logfile> [max_bytes]
rotate_log() {
  local logfile="$1"
  local max_bytes="${2:-1048576}"  # 1MB default
  [ -f "$logfile" ] || return 0
  local size
  if $_IS_MACOS; then
    size=$(stat -f %z "$logfile" 2>/dev/null || echo 0)
  else
    size=$(stat -c %s "$logfile" 2>/dev/null || echo 0)
  fi
  if (( size > max_bytes )); then
    # Keep last 500 lines, rotate the rest
    local tmp
    tmp="$(mktemp)"
    tail -500 "$logfile" > "$tmp" 2>/dev/null
    mv "$tmp" "$logfile"
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
