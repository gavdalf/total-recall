#!/usr/bin/env bash
# linkedin-connector.sh — LinkedIn message sensor for AIE v2
# Runs headless Playwright on Mac Studio via openclaw node invoke
# READ-ONLY: only checks messages, never sends anything
# Usage: bash linkedin-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/_compat.sh"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/linkedin.json"
mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$BUS")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
LOCK_WAIT_SEC=10

# Config
NODE_NAME="$(aie_get "connectors.linkedin.node_name" "Mac Studio")"
SCRIPT_PATH="$(aie_get "connectors.linkedin.script_path" "/Users/gavinwhittaker/playwright-social/scripts/linkedin-messages.py")"
MAX_MESSAGES="$(aie_get "connectors.linkedin.max_messages" "10")"
WAIT_SECONDS="$(aie_get "connectors.linkedin.wait_seconds" "25")"
OUTPUT_FILE="/tmp/linkedin-messages.json"

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[linkedin] $*"; }

load_json_object_file() {
  local file="$1"
  if [[ -s "$file" ]]; then
    cat "$file" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

safe_write_json_atomic() {
  local target="$1" data="$2"
  local tmp="${target}.tmp.$$"
  printf '%s\n' "$data" > "$tmp" && mv "$tmp" "$target"
}

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "linkedin", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: true,
      payload: $payload, consumed: false, consumer_watermark: null}') || return 0

  _emit_to_bus() { echo "$event" >> "$BUS"; }
  if [[ -z "$DRY_RUN" ]]; then
    if ! PORTABLE_FLOCK_WAIT="$LOCK_WAIT_SEC" portable_flock_exec "$BUS_LOCK" _emit_to_bus; then
      log "WARN: Failed to write event to bus"
      return 0
    fi
    log "Emitted: $type -> $id"
  else
    log "[DRY-RUN] Would emit: $type | $(printf '%s' "$payload" | jq -r '.name // "?"' 2>/dev/null)"
  fi
}

# Check if connector is enabled
if ! aie_bool "connectors.linkedin.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

# Step 1: Fire the headless scraper on Mac Studio (fire-and-forget + sleep + collect)
log "Launching headless LinkedIn check on $NODE_NAME..."
LAUNCH_JSON=$(openclaw nodes invoke \
  --node "$NODE_NAME" \
  --command system.run \
  --params "{\"command\": [\"bash\", \"-c\", \"rm -f $OUTPUT_FILE && nohup python3 $SCRIPT_PATH --json --limit $MAX_MESSAGES > $OUTPUT_FILE 2>&1 &\"]}" \
  --invoke-timeout 15000 \
  --timeout 20000 \
  --json 2>&1 || echo '{"error":"launch_failed"}')

if echo "$LAUNCH_JSON" | jq -e '.error // empty' >/dev/null 2>&1; then
  ERROR=$(echo "$LAUNCH_JSON" | jq -r '.error' 2>/dev/null || echo "unknown")
  log "ERROR: Failed to launch scraper: $ERROR"
  exit 1
fi

# Step 2: Wait for Playwright to load LinkedIn and scrape
log "Waiting ${WAIT_SECONDS}s for scraper..."
sleep "$WAIT_SECONDS"

# Step 3: Retrieve results
RESULT_JSON=$(openclaw nodes invoke \
  --node "$NODE_NAME" \
  --command system.run \
  --params "{\"command\": [\"bash\", \"-c\", \"cat $OUTPUT_FILE 2>/dev/null || echo '{\\\"error\\\": \\\"no output\\\"}'\"]}" \
  --invoke-timeout 15000 \
  --timeout 20000 \
  --json 2>&1 || echo '{"error":"retrieve_failed"}')

# Extract stdout from node response
MESSAGES=""
if echo "$RESULT_JSON" | jq -e '.stdout' >/dev/null 2>&1; then
  MESSAGES=$(echo "$RESULT_JSON" | jq -r '.stdout' 2>/dev/null)
elif echo "$RESULT_JSON" | jq -e '.payload.stdout' >/dev/null 2>&1; then
  MESSAGES=$(echo "$RESULT_JSON" | jq -r '.payload.stdout' 2>/dev/null)
else
  MESSAGES="$RESULT_JSON"
fi

# Validate JSON array
if ! echo "$MESSAGES" | jq -e 'type == "array"' >/dev/null 2>&1; then
  ERROR=$(echo "$MESSAGES" | jq -r '.error // empty' 2>/dev/null || true)
  if [[ -n "$ERROR" ]]; then
    log "ERROR from scraper: $ERROR"
  else
    log "ERROR: Invalid response from scraper"
  fi
  exit 1
fi

MSG_COUNT=$(echo "$MESSAGES" | jq 'length' 2>/dev/null || echo 0)
log "Retrieved $MSG_COUNT conversations"

# Load previous state
PREV_STATE=$(load_json_object_file "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

# Process each conversation
while IFS= read -r msg; do
  [[ -z "$msg" ]] && continue

  name=$(echo "$msg" | jq -r '.name // "Unknown"')
  snippet=$(echo "$msg" | jq -r '.snippet // ""')
  time_str=$(echo "$msg" | jq -r '.time // ""')
  unread=$(echo "$msg" | jq -r '.unread // false')

  # Create a stable ID from name+snippet
  bus_id="linkedin-$(echo "${name}|${snippet}" | md5_hash | cut -c1-16)"

  # Check if already processed
  prev=$(echo "$PREV_STATE" | jq -r --arg id "$bus_id" '.[$id] // empty' 2>/dev/null || true)
  [[ -n "$prev" ]] && continue

  # Score importance
  importance="0.5"
  if [[ "$unread" == "true" ]]; then
    importance="0.75"
  fi

  # VFX industry / job-relevant messages get higher importance
  if echo "$snippet" | grep -qiE "(compositor|VFX|studio|project|booking|available|contract|rate|role|position|hire|outpost|dneg|framestore|ilm|mpc|cinesite)"; then
    importance="0.8"
  fi

  payload=$(jq -cn \
    --arg name "$name" --arg snippet "$snippet" --arg time "$time_str" \
    --argjson unread "$unread" \
    '{name: $name, snippet: $snippet, time: $time, unread: $unread, platform: "linkedin"}')

  # Emit for: unread messages OR VFX-relevant snippets
  if [[ "$unread" == "true" ]] || echo "$snippet" | grep -qiE "(compositor|VFX|studio|project|booking|available|contract|rate|role|position|hire|outpost|dneg|framestore|ilm|mpc|cinesite)"; then
    emit_event "$bus_id" "linkedin_message" "$importance" "$payload"
    COUNT=$((COUNT + 1))
  fi

  NEW_STATE=$(echo "$NEW_STATE" | jq -c --arg id "$bus_id" --arg ts "$NOW" '.[$id] = $ts' 2>/dev/null || echo "$NEW_STATE")
done < <(echo "$MESSAGES" | jq -c '.[]' 2>/dev/null)

# Persist state
if [[ -z "$DRY_RUN" ]]; then
  safe_write_json_atomic "$STATE_FILE" "$NEW_STATE"
fi

log "LinkedIn connector complete. $MSG_COUNT conversations, emitted $COUNT event(s)."
