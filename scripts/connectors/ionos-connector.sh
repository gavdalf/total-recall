#!/usr/bin/env bash
# ionos-connector.sh — IONOS email sensor for AIE v2
# Checks for recent unread emails via himalaya CLI
# Usage: bash ionos-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/ionos.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
IONOS_ACCOUNT="$(aie_get "connectors.ionos.account" "ionos")"
IONOS_LIMIT="$(aie_get "connectors.ionos.unread_limit" "10")"

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[ionos] $*"; }

if ! aie_bool "connectors.ionos.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

aie_load_env

health_check() {
  if ! himalaya envelope list --account "$IONOS_ACCOUNT" --max-width 200 -s 1 >/dev/null 2>&1; then
    log "ERROR: health_check failed — himalaya ionos unreachable"
    exit 1
  fi
  log "health_check OK"
}

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "ionos", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: true,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.subject // "?"')"
  fi
}

health_check

PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

# Fetch recent envelopes (unread)
# himalaya outputs table format; use JSON if available, else parse table
ENVELOPES=$(himalaya envelope list --account "$IONOS_ACCOUNT" --max-width 500 -s "$IONOS_LIMIT" 2>/dev/null || echo "")

if [[ -z "$ENVELOPES" ]]; then
  log "No envelopes returned or error"
  exit 0
fi

# Parse himalaya table output (ID | FLAGS | FROM | SUBJECT)
# Skip header lines — use temp file to avoid subshell variable scope loss (C1 fix)
TMP_ENV=$(mktemp)
echo "$ENVELOPES" | tail -n +3 > "$TMP_ENV"
while IFS='│' read -r id flags from subject rest; do
  id=$(echo "$id" | xargs)
  flags=$(echo "$flags" | xargs)
  from=$(echo "$from" | xargs | head -c 100)
  subject=$(echo "$subject" | xargs | head -c 200)

  [[ -z "$id" || "$id" == "─"* ]] && continue

  # Only process unseen emails
  echo "$flags" | grep -qi "seen" && continue

  bus_id="ionos-${id}"

  # Skip if already seen
  prev=$(echo "$PREV_STATE" | jq -r --arg id "$bus_id" '.[$id] // ""')
  [[ -n "$prev" ]] && continue

  # Set importance
  importance=0.5
  if aie_sender_matches_importance "$from"; then
    importance=0.8
  fi
  echo "$from" | grep -qiE "(noreply|newsletter|marketing|notification|promo)" && importance=0.3

  payload=$(jq -cn \
    --arg subject "$subject" --arg from "$from" --arg msg_id "$id" \
    '{subject: $subject, from: $from, msg_id: $msg_id}')

  if [[ $(awk "BEGIN{print ($importance > 0.4) ? 1 : 0}") -eq 1 ]]; then
    emit_event "$bus_id" "email_important" "$importance" "$payload"
    COUNT=$((COUNT + 1))
  fi

  NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$bus_id" --arg ts "$NOW" '.[$id] = $ts')
done < "$TMP_ENV"
rm -f "$TMP_ENV"

if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "IONOS connector complete. Emitted $COUNT event(s)."
