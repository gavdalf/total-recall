#!/usr/bin/env bash
# gmail-connector.sh — Gmail sensor for AIE v2
# Checks for recent important/unread emails via gog CLI
# Usage: bash gmail-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/gmail.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GMAIL_ACCOUNT="$(aie_get "connectors.gmail.account" "")"
GMAIL_QUERY="$(aie_get "connectors.gmail.unread_query" "is:unread")"
GMAIL_MAX_MESSAGES="$(aie_get "connectors.gmail.max_messages" "10")"
GMAIL_KEYRING_PASSWORD="$(aie_get "connectors.gmail.keyring_password" "")"

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[gmail] $*"; }

if ! aie_bool "connectors.gmail.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

if [[ -z "$GMAIL_ACCOUNT" || -z "$GMAIL_KEYRING_PASSWORD" ]]; then
  log "SKIP missing Gmail account or keyring password in config"
  exit 0
fi

aie_load_env

health_check() {
  if ! GOG_KEYRING_PASSWORD="$GMAIL_KEYRING_PASSWORD" GOG_ACCOUNT="$GMAIL_ACCOUNT" gog gmail messages search "$GMAIL_QUERY" --max 1 --json >/dev/null 2>&1; then
    log "ERROR: health_check failed — gog gmail unreachable"
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
    '{id: $id, source: "gmail", type: $type, timestamp: $timestamp,
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

# Fetch recent unread emails
EMAILS_RAW=$(GOG_KEYRING_PASSWORD="$GMAIL_KEYRING_PASSWORD" GOG_ACCOUNT="$GMAIL_ACCOUNT" \
  gog gmail messages search "$GMAIL_QUERY" --max "$GMAIL_MAX_MESSAGES" --json 2>/dev/null || echo '{"messages":[]}')
EMAILS=$(echo "$EMAILS_RAW" | jq '.messages // []' 2>/dev/null || echo "[]")

# Process emails
TMP_EMAILS=$(mktemp)
echo "$EMAILS" | jq -c '.[]' 2>/dev/null > "$TMP_EMAILS" || true

while IFS= read -r email; do
  [[ -z "$email" ]] && continue

  msg_id=$(echo "$email" | jq -r '.id // ""')
  [[ -z "$msg_id" ]] && continue

  subject=$(echo "$email" | jq -r '.subject // "No subject"' | head -c 200)
  from=$(echo "$email" | jq -r '.from // ""' | head -c 100)
  date_str=$(echo "$email" | jq -r '.date // ""')
  labels=$(echo "$email" | jq -r '.labels // [] | join(",")' 2>/dev/null || echo "")

  bus_id="gmail-${msg_id:0:20}"

  # Skip if already seen
  prev=$(echo "$PREV_STATE" | jq -r --arg id "$bus_id" '.[$id] // ""')
  [[ -n "$prev" ]] && continue

  # Set importance based on sender patterns
  importance=0.5
  if aie_sender_matches_importance "$from"; then
    importance=0.8
  fi
  # Lower for newsletters/automated
  echo "$from" | grep -qiE "(noreply|newsletter|marketing|notification)" && importance=0.3

  payload=$(jq -cn \
    --arg subject "$subject" --arg from "$from" --arg date "$date_str" --arg msg_id "$msg_id" \
    '{subject: $subject, from: $from, date: $date, msg_id: $msg_id}')

  # Only emit if importance > 0.4 (skip obvious noise)
  if [[ $(awk "BEGIN{print ($importance > 0.4) ? 1 : 0}") -eq 1 ]]; then
    emit_event "$bus_id" "email_important" "$importance" "$payload"
    COUNT=$((COUNT + 1))
  fi

  NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$bus_id" --arg ts "$NOW" '.[$id] = $ts')
done < "$TMP_EMAILS"
rm -f "$TMP_EMAILS"

if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "Gmail connector complete. Emitted $COUNT event(s)."
