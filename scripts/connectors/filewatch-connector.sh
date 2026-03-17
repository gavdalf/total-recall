#!/usr/bin/env bash
# filewatch-connector.sh — File change sensor for AIE v2
# Watches key memory files for modifications since last sweep
# Usage: bash filewatch-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/_compat.sh"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/filewatch.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[filewatch] $*"; }

if ! aie_bool "connectors.filewatch.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "filewatch", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: false,
      payload: $payload, consumed: false, consumer_watermark: null}')
  _emit_to_bus() { echo "$event" >> "$BUS"; }
  if [[ -z "$DRY_RUN" ]]; then
    portable_flock_exec "$BUS_LOCK" _emit_to_bus
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.file // "?"')"
  fi
}

PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

WATCH_FILES=()
while IFS= read -r filepath; do
  [[ -n "$filepath" ]] && WATCH_FILES+=("$filepath")
done < <(python3 <<'PY'
import json
import os

data = json.loads(os.environ["AIE_CONFIG_JSON"])
for item in data.get("connectors", {}).get("filewatch", {}).get("watch_files", []):
    print(item)
PY
)

for filepath in "${WATCH_FILES[@]}"; do
  [[ -f "$filepath" ]] || continue

  filename=$(basename "$filepath")
  file_mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
  file_size=$(stat -c %s "$filepath" 2>/dev/null || stat -f %z "$filepath" 2>/dev/null || echo 0)
  file_key="fw-${filename}"

  # Check against previous state
  prev_mtime=$(echo "$PREV_STATE" | jq -r --arg k "$file_key" '.[$k].mtime // "0"')

  if [[ "$file_mtime" != "$prev_mtime" && "$prev_mtime" != "0" ]]; then
    # File changed since last sweep
    prev_size=$(echo "$PREV_STATE" | jq -r --arg k "$file_key" '.[$k].size // "0"')
    size_delta=$((file_size - prev_size))

    # Determine importance based on file
    importance=0.4
    [[ "$filename" == "observations.md" ]] && importance=0.5
    [[ "$filename" == "favorites.md" ]] && importance=0.6

    payload=$(jq -cn \
      --arg file "$filename" --arg path "$filepath" \
      --argjson size "$file_size" --argjson delta "$size_delta" \
      '{file: $file, path: $path, size_bytes: $size, size_delta: $delta}')

    bus_id="fw-${filename}-${file_mtime}"
    emit_event "$bus_id" "observations_updated" "$importance" "$payload"
    COUNT=$((COUNT + 1))
  fi

  # Update state
  NEW_STATE=$(echo "$NEW_STATE" | jq \
    --arg k "$file_key" --arg mt "$file_mtime" --arg sz "$file_size" \
    '.[$k] = {mtime: $mt, size: $sz}')
done

if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "Filewatch connector complete. Emitted $COUNT event(s)."
