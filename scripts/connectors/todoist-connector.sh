#!/usr/bin/env bash
# todoist-connector.sh — Todoist sensor for AIE v2
# Tracks overdue and due-today tasks, emits events to bus
# Usage: bash todoist-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/todoist.json"
mkdir -p "$(dirname "$STATE_FILE")"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date +%Y-%m-%d)

# Parse flags
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"
done

log() {
  echo "[todoist] $*"
}

if ! aie_bool "connectors.todoist.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

health_check() {
  if ! todoist tasks --all --json >/dev/null 2>&1; then
    log "ERROR: health_check failed — todoist CLI unreachable (auth?)"
    exit 1
  fi
  log "health_check OK"
}

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" \
    --arg type "$type" \
    --arg timestamp "$NOW" \
    --argjson importance "$importance" \
    --argjson payload "$payload" \
    '{id: $id, source: "todoist", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: true,
      payload: $payload, consumed: false, consumer_watermark: null}')
  if [[ -z "$DRY_RUN" ]]; then
    ( flock -x 200; echo "$event" >> "$BUS" ) 200>"$BUS_LOCK"
    log "Emitted: $type → $id"
  else
    log "[DRY-RUN] Would emit: $type | $(echo "$payload" | jq -r '.content // "?"') (due: $(echo "$payload" | jq -r '.due // "?"'))"
  fi
}

# Source env
aie_load_env

health_check

# Load previous state (JSON object mapping bus_id -> first_seen_timestamp)
PREV_STATE="{}"
[[ -f "$STATE_FILE" ]] && PREV_STATE=$(cat "$STATE_FILE")

NEW_STATE="$PREV_STATE"
COUNT=0

process_tasks() {
  local tasks="$1"
  local event_type="$2"
  local importance="$3"
  local tmp_tasks
  tmp_tasks=$(mktemp)

  # Write tasks to temp file to avoid subshell/pipe scope issues
  echo "$tasks" | jq -c '.[]' 2>/dev/null > "$tmp_tasks" || true

  while IFS= read -r task; do
    [[ -z "$task" ]] && continue

    task_id=$(echo "$task" | jq -r '.id // ""')
    [[ -z "$task_id" ]] && continue

    task_content=$(echo "$task" | jq -r '.content // "Untitled"')
    task_due=$(echo "$task" | jq -r '.due.date // ""')
    task_priority=$(echo "$task" | jq -r '.priority // 1')

    bus_id="todo-${event_type}-${task_id}"

    # Only emit if not already seen in this state
    prev=$(echo "$PREV_STATE" | jq -r --arg id "$bus_id" '.[$id] // ""')
    if [[ -n "$prev" ]]; then
      continue
    fi

    payload=$(jq -cn \
      --arg content "$task_content" \
      --arg due "$task_due" \
      --arg task_id "$task_id" \
      --argjson priority "$task_priority" \
      '{content: $content, due: $due, task_id: $task_id, priority: $priority}')

    emit_event "$bus_id" "$event_type" "$importance" "$payload"
    NEW_STATE=$(echo "$NEW_STATE" | jq --arg id "$bus_id" --arg ts "$NOW" '.[$id] = $ts')
    COUNT=$((COUNT + 1))
  done < "$tmp_tasks"

  rm -f "$tmp_tasks"
}

# Fetch all tasks and filter locally (more reliable than --filter flag)
ALL_TASKS=$(todoist tasks --all --json 2>/dev/null || echo "[]")

# Overdue: has a due date before today, not completed
OVERDUE=$(echo "$ALL_TASKS" | jq --arg today "$TODAY" \
  '[.[] | select(.due.date != null and .due.date < $today and .checked == false)]' 2>/dev/null || echo "[]")

# Due today: has a due date of today, not completed
DUE_TODAY=$(echo "$ALL_TASKS" | jq --arg today "$TODAY" \
  '[.[] | select(.due.date != null and .due.date == $today and .checked == false)]' 2>/dev/null || echo "[]")

OVERDUE_COUNT=$(echo "$OVERDUE" | jq 'length' 2>/dev/null || echo 0)
DUE_TODAY_COUNT=$(echo "$DUE_TODAY" | jq 'length' 2>/dev/null || echo 0)

log "Found $OVERDUE_COUNT overdue, $DUE_TODAY_COUNT due today"

process_tasks "$OVERDUE" "task_overdue" "0.85"
process_tasks "$DUE_TODAY" "task_due_today" "0.65"

# Atomic write of state (skip in dry-run mode)
if [[ -z "$DRY_RUN" ]]; then
  echo "$NEW_STATE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi

log "Todoist connector complete. Emitted $COUNT event(s)."
