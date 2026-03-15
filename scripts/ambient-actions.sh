#!/usr/bin/env bash
# ambient-actions.sh — AIE v2 Phase 7A stub: read enriched rumination insights, emit summary
# Formerly contained: classification → lookup → enrichment pipeline (moved to rumination-engine.sh)
# Phase 7A-4 will add: action resolution (ask / learn / draft / notify / remind)
#
# Usage:
#   bash ambient-actions.sh --dry-run-actions
#   bash ambient-actions.sh --execute-actions-only
#   bash ambient-actions.sh --live-actions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init
aie_load_env

# Shared library (created in Phase 7A-1; sourced with guard so script works if not yet present)
[[ -f "$SCRIPT_DIR/aie-tools.sh" ]] && source "$SCRIPT_DIR/aie-tools.sh"

RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$AIE_WORKSPACE/memory/rumination")"
ACTION_LOG="$RUMINATION_DIR/ambient-actions-log.jsonl"
RUMINATION_LOG="$AIE_LOGS_DIR/rumination.log"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MODE="execute_actions_only"
case "${1:-}" in
  ""|--execute-actions-only) MODE="execute_actions_only" ;;
  --dry-run-actions)         MODE="dry_run_actions" ;;
  --live-actions)            MODE="live_actions" ;;
  *)
    echo "Usage: $0 [--dry-run-actions|--execute-actions-only|--live-actions]" >&2
    exit 1
    ;;
esac

mkdir -p "$RUMINATION_DIR" "$(dirname "$RUMINATION_LOG")"
touch "$ACTION_LOG" "$RUMINATION_LOG"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ambient-actions] $*"
  echo "$msg" >> "$RUMINATION_LOG"
}

append_action_log() {
  local json_line="$1"
  printf '%s\n' "$json_line" >> "$ACTION_LOG"
}

emit_stage_log() {
  local stage="$1"
  local payload="$2"
  local row
  row=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$MODE" \
    --arg stage "$stage" \
    --argjson payload "$payload" \
    '{timestamp:$ts, mode:$mode, stage:$stage, payload:$payload}')
  append_action_log "$row"
}

log "=== Ambient actions START (mode=$MODE) ==="

# ─── Gate checks ─────────────────────────────────────────────────────────────

if ! aie_bool "ambient_actions.enabled"; then
  log "Ambient actions disabled in config"
  emit_stage_log "skip" '{"reason":"ambient_actions_disabled"}'
  exit 0
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  log "ERROR: OPENROUTER_API_KEY not found"
  emit_stage_log "fatal" '{"error":"missing_openrouter_api_key"}'
  exit 1
fi

# ─── Read latest enriched rumination record ───────────────────────────────────
# Rumination-engine.sh now writes enriched insights; we consume them here.

TODAY_FILE="$RUMINATION_DIR/${TODAY}.jsonl"
if [[ ! -s "$TODAY_FILE" ]]; then
  log "No rumination file for today at $TODAY_FILE"
  emit_stage_log "skip" '{"reason":"missing_today_rumination_file"}'
  exit 0
fi

LATEST_RECORD=$(tail -n 1 "$TODAY_FILE" 2>/dev/null || echo "")
if [[ -z "$LATEST_RECORD" ]]; then
  log "No latest record in $TODAY_FILE"
  emit_stage_log "skip" '{"reason":"empty_today_rumination_file"}'
  exit 0
fi

INSIGHTS_JSON=$(echo "$LATEST_RECORD" | jq -c '.rumination_notes // []' 2>/dev/null || echo "[]")
INSIGHT_COUNT=$(echo "$INSIGHTS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [[ "$INSIGHT_COUNT" -eq 0 ]]; then
  log "Latest rumination record has no insights"
  emit_stage_log "skip" '{"reason":"no_insights"}'
  exit 0
fi

log "Loaded $INSIGHT_COUNT enriched insights from $TODAY_FILE"

# ─── Action Resolution (Phase 7A-4) ──────────────────────────────────────────
# For each enriched insight, decide if a REAL action is needed:
#   - ask:    Surface a question to the user via preconscious buffer
#   - learn:  Write a confirmed fact to learned-facts.json
#   - draft:  Prepare something for the user to review
#   - notify: Send a notification (with guardrails + quiet hours)
#   - remind: Set a time-based nudge
# Action types will be classified by LLM and executed with appropriate guardrails.
log "Action resolution placeholder — awaiting Phase 7A-4 implementation"
emit_stage_log "actions_placeholder" "$(jq -cn --argjson count "$INSIGHT_COUNT" '{status:"not_implemented",insight_count:$count,phase:"7A-4"}')"

# ─── Summary ─────────────────────────────────────────────────────────────────

FINAL_SUMMARY=$(jq -cn \
  --arg mode "$MODE" \
  --arg today_file "$TODAY_FILE" \
  --argjson insight_count "$INSIGHT_COUNT" \
  '{mode:$mode, rumination_file:$today_file, insight_count:$insight_count, status:"stub_7a4_pending"}')
emit_stage_log "summary" "$FINAL_SUMMARY"

log "=== Ambient actions END (mode=$MODE) ==="
exit 0
