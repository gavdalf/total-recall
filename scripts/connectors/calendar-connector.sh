#!/usr/bin/env bash
# calendar-connector.sh — Google Calendar sensor for AIE v2
# Fetches events for next 48 hours, diffs against state, emits events to bus
# Usage: bash calendar-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/calendar.json"
mkdir -p "$(dirname "$STATE_FILE")"
LOG="$AIE_LOGS_DIR/sensor-sweep.log"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)
CALENDAR_ACCOUNT="$(aie_get "connectors.calendar.account" "")"
CALENDAR_ID="$(aie_get "connectors.calendar.calendar_id" "primary")"
LOOKAHEAD_DAYS="$(aie_get "connectors.calendar.lookahead_days" "2")"
MAX_EVENTS="$(aie_get "connectors.calendar.max_events" "50")"
KEYRING_PASSWORD="$(aie_get "connectors.calendar.keyring_password" "")"

# Parse flags
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"
done

if ! aie_bool "connectors.calendar.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

if [[ -z "$CALENDAR_ACCOUNT" || -z "$KEYRING_PASSWORD" ]]; then
  log "SKIP missing calendar account or keyring password in config"
  exit 0
fi

log() {
  echo "[calendar] $*"
}

health_check() {
  if ! GOG_KEYRING_PASSWORD="$KEYRING_PASSWORD" GOG_ACCOUNT="$CALENDAR_ACCOUNT" \
      gog calendar events "$CALENDAR_ID" --days 1 --max 1 --json >/dev/null 2>&1; then
    log "ERROR: health_check failed — gog calendar not reachable (auth expiry?)"
    exit 1
  fi
  log "health_check OK"
}

emit_event() {
  local id="$1" type="$2" importance="$3" actionable="$4" payload="$5" expires_at="$6"
  local event
  event=$(jq -cn \
    --arg id "$id" \
    --arg source "calendar" \
    --arg type "$type" \
    --arg timestamp "$NOW" \
    --arg expires_at "$expires_at" \
    --argjson importance "$importance" \
    --argjson actionable "$actionable" \
    --argjson payload "$payload" \
    '{id: $id, source: $source, type: $type, timestamp: $timestamp,
      expires_at: (if $expires_at == "null" then null else $expires_at end),
      importance: $importance, actionable: $actionable,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.title // "?"') @ $(echo "$payload" | jq -r '.start // "?"')"
  fi
}

# Source env for auth
aie_load_env

health_check

# Load previous state (JSON object mapping event_id -> hash)
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")

# Fetch events for next 48 hours (--days 2)
RAW=$(GOG_KEYRING_PASSWORD="$KEYRING_PASSWORD" GOG_ACCOUNT="$CALENDAR_ACCOUNT" \
      gog calendar events "$CALENDAR_ID" --days "$LOOKAHEAD_DAYS" --max "$MAX_EVENTS" --json 2>/dev/null || echo '{"events":[]}')

# Handle both array and object wrapper formats
EVENTS=$(echo "$RAW" | jq -c 'if type == "array" then .[] else .events[]? end' 2>/dev/null || echo "")

if [[ -z "$EVENTS" ]]; then
  log "No events returned (empty calendar or parse issue)"
  echo "$PREV_STATE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  exit 0
fi

NEW_STATE="$PREV_STATE"
COUNT=0

while IFS= read -r ev; do
  [[ -z "$ev" ]] && continue

  ev_id=$(echo "$ev" | jq -r '.id // ""')
  [[ -z "$ev_id" ]] && continue

  ev_title=$(echo "$ev" | jq -r '.summary // "Untitled"')
  ev_start=$(echo "$ev" | jq -r '.start.dateTime // .start.date // ""')
  ev_end=$(echo "$ev" | jq -r '.end.dateTime // .end.date // ""')
  ev_location=$(echo "$ev" | jq -r '.location // ""')
  ev_status=$(echo "$ev" | jq -r '.status // "confirmed"')

  # Create a content hash for change detection
  ev_hash=$(echo "${ev_title}|${ev_start}|${ev_end}|${ev_location}|${ev_status}" | md5sum | cut -d' ' -f1)

  # Hours until event starts
  hours_until=999
  if [[ -n "$ev_start" ]]; then
    ev_start_epoch=$(date -d "$ev_start" +%s 2>/dev/null || echo 0)
    if [[ "$ev_start_epoch" -gt 0 ]]; then
      hours_until=$(( (ev_start_epoch - NOW_EPOCH) / 3600 ))
    fi
  fi

  # Determine event type
  prev_hash=$(echo "$PREV_STATE" | jq -r --arg id "$ev_id" '.[$id] // ""')

  if [[ "$ev_status" == "cancelled" && -n "$prev_hash" ]]; then
    event_type="event_cancelled"
  elif [[ -z "$prev_hash" ]]; then
    # New event — only emit if within 24h window OR newly discovered
    event_type="event_new"
  elif [[ "$prev_hash" != "$ev_hash" ]]; then
    event_type="event_changed"
  else
    # Known event, unchanged — emit as upcoming only if within 24h
    event_type="event_upcoming"
  fi

  # Skip unchanged events outside the 24h window
  if [[ "$event_type" == "event_upcoming" && $hours_until -gt 24 ]]; then
    NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$ev_id" --arg hash "$ev_hash" '.[$id] = $hash')
    continue
  fi

  # Skip events in the past (started > 1hr ago)
  if [[ $hours_until -lt -1 ]]; then
    NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$ev_id" --arg hash "$ev_hash" '.[$id] = $hash')
    continue
  fi

  # Set importance based on proximity
  importance=0.5
  if [[ $hours_until -le 2 ]]; then
    importance=0.95
  elif [[ $hours_until -le 6 ]]; then
    importance=0.8
  elif [[ $hours_until -le 24 ]]; then
    importance=0.65
  fi

  # Build event ID (stable across re-fetches for same event)
  bus_id="cal-${ev_id:0:20}-${ev_hash:0:6}"

  # Build payload
  payload=$(jq -cn \
    --arg title "$ev_title" \
    --arg start "$ev_start" \
    --arg end "$ev_end" \
    --arg location "$ev_location" \
    --argjson hours_until "$hours_until" \
    '{title: $title, start: $start, end: $end, location: $location, hours_until: $hours_until}')

  # Expires_at = event start time (event becomes irrelevant once it starts)
  expires_at="null"
  if [[ -n "$ev_end" ]]; then
    expires_at=$(date -u -d "$ev_end" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "null")
  fi

  emit_event "$bus_id" "$event_type" "$importance" "true" "$payload" "$expires_at"
  COUNT=$((COUNT + 1))

  NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$ev_id" --arg hash "$ev_hash" '.[$id] = $hash')

done <<< "$EVENTS"

# Atomic write of state (skip in dry-run mode)
if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "Calendar connector complete. Emitted $COUNT event(s)."
