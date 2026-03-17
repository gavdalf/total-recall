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

# Check if fswatch is available (macOS file watcher)
has_fswatch() {
  command -v fswatch &>/dev/null
}

# Check if systemctl --user is available
has_systemd_user() {
  command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1
  return $?
}

# ─── Portable flock ──────────────────────────────────────────────────────────
# macOS has no flock(1). We use mkdir as an atomic lock primitive.
#
# Usage — replaces the fd-redirect flock pattern:
#   BEFORE:  ( flock -x 200; COMMANDS ) 200>"$LOCKFILE"
#   AFTER:   portable_flock_exec "$LOCKFILE" COMMANDS
#
# For non-blocking (flock -n):
#   portable_flock_try "$LOCKFILE"   → returns 0 if lock acquired, 1 if busy
#   portable_flock_release "$LOCKFILE"
portable_flock_exec() {
  local lockdir="$1.d"
  shift
  local wait_max="${PORTABLE_FLOCK_WAIT:-30}"
  local waited=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Stale lock detection: if lock dir is older than 5 minutes, break it
    if $_IS_MACOS; then
      local lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || echo 0) ))
    else
      local lock_age=$(( $(date +%s) - $(stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
    fi
    if [[ $lock_age -gt 300 ]]; then
      rmdir "$lockdir" 2>/dev/null || true
      continue
    fi
    sleep 0.2
    waited=$(( waited + 1 ))
    if [[ $waited -ge $(( wait_max * 5 )) ]]; then
      echo "[_compat] WARN: lock timeout on $lockdir" >&2
      return 1
    fi
  done
  # shellcheck disable=SC2064
  trap "rmdir '$lockdir' 2>/dev/null || true" RETURN
  eval "$@"
}

# Non-blocking lock acquire (replaces flock -n)
portable_flock_try() {
  local lockdir="$1.d"
  if mkdir "$lockdir" 2>/dev/null; then
    return 0
  fi
  # Stale lock detection
  if $_IS_MACOS; then
    local lock_age=$(( $(date +%s) - $(stat -f %m "$lockdir" 2>/dev/null || echo 0) ))
  else
    local lock_age=$(( $(date +%s) - $(stat -c %Y "$lockdir" 2>/dev/null || echo 0) ))
  fi
  if [[ $lock_age -gt 300 ]]; then
    rmdir "$lockdir" 2>/dev/null || true
    mkdir "$lockdir" 2>/dev/null && return 0
  fi
  return 1
}

portable_flock_release() {
  local lockdir="$1.d"
  rmdir "$lockdir" 2>/dev/null || true
}

# ─── Portable timeout ────────────────────────────────────────────────────────
# macOS has no coreutils timeout. Uses perl alarm as fallback.
# Usage: portable_timeout SECONDS COMMAND [ARGS...]
#        portable_timeout --kill-after=K SECONDS COMMAND [ARGS...]
portable_timeout() {
  local kill_after=""
  if [[ "$1" == --kill-after=* ]]; then
    kill_after="${1#--kill-after=}"
    shift
  fi
  local seconds="$1"
  shift
  # Strip trailing 's' if present (timeout accepts "30s")
  seconds="${seconds%s}"

  if command -v timeout >/dev/null 2>&1; then
    if [[ -n "$kill_after" ]]; then
      timeout --kill-after="$kill_after" "${seconds}s" "$@"
    else
      timeout "${seconds}s" "$@"
    fi
  elif $_IS_MACOS && command -v perl >/dev/null 2>&1; then
    perl -e '
      $SIG{ALRM} = sub { kill 9, $pid if $pid; exit 124 };
      alarm shift @ARGV;
      $pid = fork;
      if ($pid == 0) { exec @ARGV; die "exec failed: $!" }
      waitpid($pid, 0);
      alarm 0;
      exit ($? >> 8);
    ' "$seconds" "$@"
  else
    # Last resort: no timeout enforcement
    "$@"
  fi
}

# ─── Portable date helpers ───────────────────────────────────────────────────

# date_days_offset N — date N days from today (negative = past). Format: %Y-%m-%d
date_days_offset() {
  local n="$1"
  if $_IS_MACOS; then
    date -v "${n}d" '+%Y-%m-%d'
  else
    date -d "${n} days" '+%Y-%m-%d'
  fi
}

# date_to_epoch "DATESTRING" — convert an ISO-ish date/datetime to epoch seconds
# Handles: 2026-03-17T14:00:00Z, 2026-03-17T14:00:00+08:00, 2026-03-17T14:00:00-05:00, 2026-03-17
date_to_epoch() {
  local ds="$1"
  if $_IS_MACOS; then
    local bare="$ds" input_offset=0 has_tz=false
    if [[ "$bare" == *Z ]]; then
      bare="${bare%Z}"
      has_tz=true
    elif [[ "$bare" == *[+-][0-9][0-9]:[0-9][0-9] ]]; then
      # Extract timezone suffix using parameter expansion (bash 3.2 compatible)
      local tz_suffix="${bare:$(( ${#bare} - 6 ))}"  # last 6 chars: +08:00 or -05:00
      local sign="${tz_suffix:0:1}"
      local hh="${tz_suffix:1:2}"
      local mm="${tz_suffix:4:2}"
      bare="${bare%[+-][0-9][0-9]:[0-9][0-9]}"
      input_offset=$(( 10#$hh * 3600 + 10#$mm * 60 ))
      [[ "$sign" == "-" ]] && input_offset=$(( -input_offset ))
      has_tz=true
    fi
    local epoch
    if $has_tz; then
      # Parse bare datetime as-if UTC, then subtract input timezone offset
      epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$bare" '+%s' 2>/dev/null) || \
      epoch=$(TZ=UTC date -j -f "%Y-%m-%d" "$bare" '+%s' 2>/dev/null) || \
      { echo 0; return; }
      echo $(( epoch - input_offset ))
    else
      # No timezone info — parse as local time
      epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$bare" '+%s' 2>/dev/null) || \
      epoch=$(date -j -f "%Y-%m-%d" "$bare" '+%s' 2>/dev/null) || \
      { echo 0; return; }
      echo "$epoch"
    fi
  else
    date -d "$ds" '+%s' 2>/dev/null || echo 0
  fi
}

# date_hours_ago N — ISO UTC timestamp N hours ago
date_hours_ago() {
  local n="$1"
  if $_IS_MACOS; then
    date -u -v "-${n}H" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "${n} hours ago" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# date_days_ago N — ISO UTC timestamp N days ago
date_days_ago() {
  local n="$1"
  if $_IS_MACOS; then
    date -u -v "-${n}d" '+%Y-%m-%dT%H:%M:%SZ'
  else
    date -u -d "${n} days ago" '+%Y-%m-%dT%H:%M:%SZ'
  fi
}

# date_future_days N — date N days from today. Format: %Y-%m-%d
date_future_days() {
  local n="$1"
  if $_IS_MACOS; then
    date -v "+${n}d" '+%Y-%m-%d'
  else
    date -d "+${n} days" '+%Y-%m-%d'
  fi
}

# ─── Portable SHA-256 ────────────────────────────────────────────────────────
# SHA-256 hash of stdin (portable). macOS lacks sha256sum.
sha256_hash() {
  if command -v sha256sum &>/dev/null; then
    sha256sum | cut -d' ' -f1
  elif command -v shasum &>/dev/null; then
    shasum -a 256 | cut -d' ' -f1
  else
    openssl dgst -sha256 | sed 's/.*= //'
  fi
}

# ─── Portable tac ────────────────────────────────────────────────────────────
# Reverse lines of file(s). macOS lacks tac.
portable_tac() {
  if command -v tac &>/dev/null; then
    tac "$@"
  else
    tail -r "$@"
  fi
}

# ─── Portable realpath -m ────────────────────────────────────────────────────
# Resolve path without requiring it to exist. macOS realpath lacks -m.
portable_realpath_m() {
  if realpath -m / &>/dev/null; then
    realpath -m "$1"
  else
    python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$1" 2>/dev/null || echo "$1"
  fi
}

# ─── Portable date → ISO UTC ────────────────────────────────────────────────
# Normalize an ISO-ish datetime string to UTC ISO 8601. Returns "null" on failure.
date_format_iso_utc() {
  local epoch
  epoch=$(date_to_epoch "$1")
  if [[ "$epoch" -gt 0 ]] 2>/dev/null; then
    if $_IS_MACOS; then
      date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ'
    else
      date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "null"
    fi
  else
    echo "null"
  fi
}

# ─── Portable jq ascii_upcase ────────────────────────────────────────────────
# jq < 1.7 lacks ascii_upcase. This helper pipes through tr as fallback.
# Usage: echo "$json" | jq_upcase_compat '.field'
#   Returns the value of .field uppercased.
_jq_has_ascii_upcase=""
jq_check_ascii_upcase() {
  if [[ -z "$_jq_has_ascii_upcase" ]]; then
    if echo '""' | jq -e '"a" | ascii_upcase' &>/dev/null; then
      _jq_has_ascii_upcase=yes
    else
      _jq_has_ascii_upcase=no
    fi
  fi
}

# Uppercase a string value — use in pipe: echo "value" | portable_upcase
portable_upcase() {
  tr '[:lower:]' '[:upper:]'
}
