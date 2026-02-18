#!/usr/bin/env bash
# observer-watcher.sh — inotify-based reactive observer trigger
# Part of Total Recall skill
# Linux only — requires inotifywait. On macOS, use cron-only mode.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

# Check inotify availability
if ! has_inotify; then
  echo "ERROR: inotifywait not found. The reactive watcher requires Linux with inotify-tools."
  echo "On macOS, use cron-only mode (observer runs every 15 min via cron)."
  exit 1
fi

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.openclaw/agents/main/sessions}"
SESSIONS_INDEX="$SESSIONS_DIR/sessions.json"
MARKER_FILE="/tmp/observer-watcher-lastrun"
COOLDOWN_SECS="${OBSERVER_COOLDOWN_SECS:-300}"
LINE_THRESHOLD="${OBSERVER_LINE_THRESHOLD:-40}"
LOG="$WORKSPACE/logs/observer-watcher.log"
PIDFILE="/tmp/total-recall-watcher-$(id -u).pid"
ACCUMULATED_LINES=0

# Safe env loading
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$WORKSPACE/.env" | grep -v '^#' > /tmp/.total-recall-env-$$ 2>/dev/null || true
  source /tmp/.total-recall-env-$$ 2>/dev/null || true
  rm -f /tmp/.total-recall-env-$$
  set +a
fi

mkdir -p "$WORKSPACE/logs"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# --- PID management ---
if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Watcher already running (PID $OLD_PID). Exiting."
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; log "Watcher stopped (PID $$)"; exit 0' EXIT INT TERM

# --- Validate sessions directory ---
if [ ! -d "$SESSIONS_DIR" ]; then
  log "Sessions directory does not exist: $SESSIONS_DIR — waiting for it to appear"
  # Wait up to 5 min for directory to appear (fresh installs)
  for i in $(seq 1 30); do
    [ -d "$SESSIONS_DIR" ] && break
    sleep 10
  done
  if [ ! -d "$SESSIONS_DIR" ]; then
    log "Sessions directory still missing after 5 min, exiting"
    exit 1
  fi
fi

get_main_session_ids() {
  if [ -f "$SESSIONS_INDEX" ]; then
    jq -r 'to_entries[]
      | select(.key | test("subagent|cron|topic") | not)
      | .value.sessionId' "$SESSIONS_INDEX" 2>/dev/null | sort -u
  fi
}

is_main_session() {
  local filename="$1"
  local session_id="${filename%.jsonl}"
  if [ -z "${MAIN_IDS:-}" ] || [ $(( $(date +%s) - ${CACHE_TIME:-0} )) -gt 60 ]; then
    MAIN_IDS=$(get_main_session_ids || true)
    CACHE_TIME=$(date +%s)
  fi
  [ -n "${MAIN_IDS:-}" ] && echo "$MAIN_IDS" | grep -qF "$session_id"
}

in_cooldown() {
  if [ ! -f "$MARKER_FILE" ]; then
    return 1
  fi
  local last_run=$(file_mtime "$MARKER_FILE")
  local now=$(date +%s)
  local elapsed=$(( now - last_run ))
  [ "$elapsed" -lt "$COOLDOWN_SECS" ]
}

trigger_observer() {
  if in_cooldown; then
    log "Cooldown active (${COOLDOWN_SECS}s). Skipping trigger. Lines accumulated: $ACCUMULATED_LINES"
    return
  fi

  log "TRIGGER: $ACCUMULATED_LINES lines accumulated. Firing observer."
  touch "$MARKER_FILE"
  ACCUMULATED_LINES=0

  "$SKILL_DIR/scripts/observer-agent.sh" >> "$LOG" 2>&1 &
  local obs_pid=$!
  log "Observer started (PID $obs_pid)"
}

check_cron_ran() {
  if [ -f "$MARKER_FILE" ]; then
    local marker_time=$(file_mtime "$MARKER_FILE")
    if [ "${LAST_MARKER_TIME:-0}" != "$marker_time" ] && [ "${LAST_MARKER_TIME:-0}" != "0" ]; then
      log "External observer run detected. Resetting line counter from $ACCUMULATED_LINES to 0."
      ACCUMULATED_LINES=0
    fi
    LAST_MARKER_TIME="$marker_time"
  fi
}

log "Watcher started (PID $$). Threshold: ${LINE_THRESHOLD} lines, Cooldown: ${COOLDOWN_SECS}s"
log "Watching: $SESSIONS_DIR"

MAIN_IDS=$(get_main_session_ids || true)
CACHE_TIME=$(date +%s)
log "Tracking $(echo "${MAIN_IDS:-}" | grep -c "." || echo 0) main session files"

inotifywait -m -e modify --format '%f' "$SESSIONS_DIR" 2>/dev/null | while read -r FILENAME; do
  [[ "$FILENAME" == *.jsonl ]] || continue
  is_main_session "$FILENAME" || continue
  ACCUMULATED_LINES=$(( ACCUMULATED_LINES + 1 ))
  check_cron_ran
  if [ "$ACCUMULATED_LINES" -ge "$LINE_THRESHOLD" ]; then
    trigger_observer
  fi
done
