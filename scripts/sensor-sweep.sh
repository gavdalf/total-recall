#!/usr/bin/env bash
# sensor-sweep.sh — Ambient Intelligence Engine v2 sensor orchestrator
# Loops through all connectors, collects events into the event bus
# Usage: bash sensor-sweep.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

WORKSPACE="$AIE_WORKSPACE"
BUS="$(aie_get "paths.events_bus" "$WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
LOG="$AIE_LOGS_DIR/sensor-sweep.log"
CONNECTOR_DIR="$SCRIPT_DIR/connectors"
DRY_RUN=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="--dry-run" ;;
  esac
done

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"
}

# Ensure directories and files exist (H2 fix)
mkdir -p "$(dirname "$LOG")" "$(dirname "$BUS")" "$AIE_SENSOR_STATE_DIR"
touch "$LOG" "$BUS"

log "=== Sensor sweep START${DRY_RUN:+ (DRY-RUN)} ==="

EVENTS_BEFORE=$(wc -l < "$BUS" 2>/dev/null || echo 0)

run_connector() {
  local name="$1"
  local script="$CONNECTOR_DIR/${name}-connector.sh"
  if [[ ! -f "$script" ]]; then
    log "SKIP $name — connector not found at $script"
    return
  fi
  if ! aie_bool "connectors.${name}.enabled"; then
    log "SKIP $name - disabled in config"
    return
  fi
  log "Running $name connector..."
  bash "$script" ${DRY_RUN:+$DRY_RUN} 2>&1 | while IFS= read -r line; do log "  [$name] $line"; done
  local exit_code="${PIPESTATUS[0]}"
  if [[ "$exit_code" -eq 0 ]]; then
    log "$name OK"
  else
    log "WARN $name exited $exit_code (non-fatal, continuing sweep)"
  fi
}

run_connector "calendar"
run_connector "todoist"
run_connector "ionos"
run_connector "gmail"
run_connector "fitbit"
run_connector "filewatch"

EVENTS_AFTER=$(wc -l < "$BUS" 2>/dev/null || echo 0)
NEW_EVENTS=$((EVENTS_AFTER - EVENTS_BEFORE))

log "New events emitted: $NEW_EVENTS"

# C2 fix: Prune consumed events older than 48h to prevent unbounded growth
if [[ -z "$DRY_RUN" ]]; then
  PRUNE_HOURS="$(aie_get "thresholds.sensor_prune_hours" "48")"
  CUTOFF=$(date -u -d "${PRUNE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  if [[ -n "$CUTOFF" ]]; then
    BUS_LINES_BEFORE=$(wc -l < "$BUS" 2>/dev/null || echo 0)
    TMP_PRUNED=$(mktemp "${BUS}.prune.XXXXXX")
    (
      flock -x 200
      jq -c --arg cutoff "$CUTOFF" \
        'select(.consumed == false or .timestamp > $cutoff)' \
        "$BUS" > "$TMP_PRUNED" 2>/dev/null && mv "$TMP_PRUNED" "$BUS"
    ) 200>"$BUS_LOCK"
    BUS_LINES_AFTER=$(wc -l < "$BUS" 2>/dev/null || echo 0)
    PRUNED=$((BUS_LINES_BEFORE - BUS_LINES_AFTER))
    [[ $PRUNED -gt 0 ]] && log "Pruned $PRUNED consumed events (> ${PRUNE_HOURS}h old)"
    rm -f "$TMP_PRUNED" 2>/dev/null
  fi
fi

if [[ $NEW_EVENTS -gt 0 && -z "$DRY_RUN" ]]; then
  if [[ -f "$SCRIPT_DIR/rumination-engine.sh" ]]; then
    log "Triggering rumination engine (background)..."
    timeout 120 bash "$SCRIPT_DIR/rumination-engine.sh" &
    log "Rumination started (PID=$!)"
  else
    log "SKIP rumination — engine not yet built"
  fi
fi

log "=== Sensor sweep END ==="
