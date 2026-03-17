#!/usr/bin/env bash
# fitbit-connector.sh — Fitbit sensor for AIE v2
# Reads daily health data JSON files for sleep, steps, heart rate
# Usage: bash fitbit-connector.sh [--dry-run]
#
# Watch-off detection:
#   < 3h sleep logged = likely watch off (not worn), don't flag as poor sleep
#   3-5h = possibly short sleep, flag cautiously
#   > 5h = real data, flag normally
#   Sleep and health thresholds are configurable in config/aie.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/_compat.sh"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/fitbit.json"
mkdir -p "$(dirname "$STATE_FILE")"
HEALTH_DIR="$(aie_get "paths.health_data_dir" "$AIE_WORKSPACE/health/data")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)
SLEEP_TARGET_HOURS="$(aie_get "connectors.fitbit.sleep_target_hours" "7.5")"
SHORT_SLEEP_MINUTES="$(aie_get "connectors.fitbit.short_sleep_minutes" "360")"
GREAT_SLEEP_MINUTES="$(aie_get "connectors.fitbit.great_sleep_minutes" "480")"
WATCH_OFF_MINUTES="$(aie_get "connectors.fitbit.watch_off_minutes" "180")"
WATCH_UNCERTAIN_MINUTES="$(aie_get "connectors.fitbit.watch_uncertain_minutes" "300")"
RESTING_HR_THRESHOLD="$(aie_get "connectors.fitbit.resting_hr_threshold" "65")"
WEIGHT_TARGET_LBS="$(aie_get "connectors.fitbit.weight_target_lbs" "157")"
STEPS_MILESTONE="$(aie_get "connectors.fitbit.steps_milestone" "10000")"

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[fitbit] $*"; }

if ! aie_bool "connectors.fitbit.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4" expires="${5:-null}"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --arg expires_at "$expires" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "fitbit", type: $type, timestamp: $timestamp,
      expires_at: $expires_at, importance: $importance, actionable: false,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    portable_flock_exec "$BUS_LOCK" "echo '$event' >> '$BUS'"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -c '.')"
  fi
}

PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

# Check today's and yesterday's health data
for DAY in "$TODAY" "$YESTERDAY"; do
  DATA_FILE="$HEALTH_DIR/${DAY}.json"
  [[ -f "$DATA_FILE" ]] || continue

  # Skip if already processed this version
  FILE_HASH=$(md5sum "$DATA_FILE" 2>/dev/null | cut -d' ' -f1 || echo "")
  STATE_KEY="fitbit-${DAY}"
  PREV_HASH=$(echo "$PREV_STATE" | jq -r --arg k "$STATE_KEY" '.[$k] // ""')
  [[ "$FILE_HASH" == "$PREV_HASH" ]] && continue

  # Read health data
  SLEEP_MINS=$(jq -r '.sleep.totalMinutesAsleep // 0' "$DATA_FILE" 2>/dev/null || echo 0)
  SLEEP_HOURS=$(awk "BEGIN{printf \"%.1f\", $SLEEP_MINS / 60}" 2>/dev/null || echo 0)
  STEPS=$(jq -r '.activity.steps // 0' "$DATA_FILE" 2>/dev/null || echo 0)
  CALORIES=$(jq -r '.activity.caloriesOut // 0' "$DATA_FILE" 2>/dev/null || echo 0)
  RESTING_HR=$(jq -r '.heartRate.restingHeartRate // 0' "$DATA_FILE" 2>/dev/null || echo 0)
  WEIGHT=$(jq -r '.weight.weight // null' "$DATA_FILE" 2>/dev/null || echo "null")

  # Watch-off detection for sleep
  WATCH_STATUS="worn"
  if [[ "$SLEEP_MINS" -lt "$WATCH_OFF_MINUTES" ]]; then
    WATCH_STATUS="likely_off"
  elif [[ "$SLEEP_MINS" -lt "$WATCH_UNCERTAIN_MINUTES" ]]; then
    WATCH_STATUS="possibly_short"
  fi

  # Sleep events
  if [[ "$WATCH_STATUS" == "worn" ]]; then
    if [[ "$SLEEP_MINS" -lt "$SHORT_SLEEP_MINUTES" ]]; then
      payload=$(jq -cn --arg hours "$SLEEP_HOURS" --arg day "$DAY" --arg status "$WATCH_STATUS" \
        --arg target "$SLEEP_TARGET_HOURS" \
        '{sleep_hours: ($hours|tonumber), day: $day, watch_status: $status, target_hours: ($target|tonumber)}')
      emit_event "fitbit-sleep-poor-${DAY}" "sleep_poor" "0.7" "$payload"
      COUNT=$((COUNT + 1))
    elif [[ "$SLEEP_MINS" -gt "$GREAT_SLEEP_MINUTES" ]]; then
      payload=$(jq -cn --arg hours "$SLEEP_HOURS" --arg day "$DAY" --arg status "$WATCH_STATUS" \
        --arg target "$SLEEP_TARGET_HOURS" \
        '{sleep_hours: ($hours|tonumber), day: $day, watch_status: $status, target_hours: ($target|tonumber)}')
      emit_event "fitbit-sleep-great-${DAY}" "sleep_great" "0.3" "$payload"
      COUNT=$((COUNT + 1))
    fi
  elif [[ "$WATCH_STATUS" == "possibly_short" ]]; then
    payload=$(jq -cn --arg hours "$SLEEP_HOURS" --arg day "$DAY" --arg status "$WATCH_STATUS" \
      '{sleep_hours: ($hours|tonumber), day: $day, watch_status: $status, note: "Between 3-5h logged. May be short sleep or partial watch wear."}')
    emit_event "fitbit-sleep-uncertain-${DAY}" "sleep_poor" "0.4" "$payload"
    COUNT=$((COUNT + 1))
  fi
  # Watch likely off: no sleep event emitted (intentional)

  # Steps milestone
  if (( STEPS >= STEPS_MILESTONE )); then
    payload=$(jq -cn --argjson steps "$STEPS" --arg day "$DAY" \
      --arg milestone "$STEPS_MILESTONE" \
      '{steps: $steps, day: $day, milestone: $milestone}')
    emit_event "fitbit-steps-10k-${DAY}" "steps_milestone" "0.3" "$payload"
    COUNT=$((COUNT + 1))
  fi

  # Resting HR spike
  if [[ "$RESTING_HR" != "0" ]] && (( RESTING_HR > RESTING_HR_THRESHOLD )); then
    payload=$(jq -cn --argjson hr "$RESTING_HR" --arg day "$DAY" \
      --arg threshold "$RESTING_HR_THRESHOLD" \
      '{resting_hr: $hr, day: $day, threshold: ($threshold|tonumber)}')
    emit_event "fitbit-hr-spike-${DAY}" "resting_hr_spike" "0.6" "$payload"
    COUNT=$((COUNT + 1))
  fi

  # Weight log
  if [[ "$WEIGHT" != "null" && "$WEIGHT" != "0" ]]; then
    payload=$(jq -cn --arg weight "$WEIGHT" --arg day "$DAY" \
      --arg target "$WEIGHT_TARGET_LBS" \
      '{weight_lbs: ($weight|tonumber), day: $day, target: ($target|tonumber)}')
    emit_event "fitbit-weight-${DAY}" "weight_logged" "0.4" "$payload"
    COUNT=$((COUNT + 1))
  fi

  # Update state with file hash
  NEW_STATE=$(echo "$NEW_STATE" | jq --arg k "$STATE_KEY" --arg v "$FILE_HASH" '.[$k] = $v')
done

if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "Fitbit connector complete. Emitted $COUNT event(s)."
