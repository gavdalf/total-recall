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

# --- File paths for action outputs ---
PRECONSCIOUS_BUFFER="$(aie_get "paths.preconscious_buffer" "$AIE_WORKSPACE/memory/preconscious-buffer.md")"
LEARNED_FACTS_FILE="$RUMINATION_DIR/learned-facts.json"
REMINDERS_FILE="$RUMINATION_DIR/reminders.jsonl"
DRAFTS_DIR="$RUMINATION_DIR/drafts"

# --- Guardrail counters ---
ASK_COUNT=0
LEARN_COUNT=0
DRAFT_COUNT=0
NOTIFY_COUNT=0
REMIND_COUNT=0
MAX_ASK=3
MAX_LEARN=5
MAX_DRAFT=2
MAX_NOTIFY=2
MAX_REMIND=3

# --- Check daily notify count from action log ---
get_daily_notify_count() {
  local today_date="$TODAY"
  grep -c "\"action_type\":\"notify\"" "$ACTION_LOG" 2>/dev/null | grep -o '[0-9]*' || echo "0"
}

DAILY_NOTIFY_COUNT=$(get_daily_notify_count)

# ─── Step 0: Process Due Reminders ───────────────────────────────────────────
process_due_reminders() {
  log "Checking for due reminders..."
  
  if [[ ! -f "$REMINDERS_FILE" ]]; then
    log "No reminders file exists yet"
    return
  fi
  
  local now_epoch due_reminders_count=0
  now_epoch=$(date -u +%s)
  local tmp_reminders
  tmp_reminders=$(mktemp)
  
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    local status trigger_at trigger_epoch reminder_text
    status=$(echo "$line" | jq -r '.status // "pending"')
    
    if [[ "$status" != "pending" ]]; then
      echo "$line" >> "$tmp_reminders"
      continue
    fi
    
    trigger_at=$(echo "$line" | jq -r '.trigger_at // ""')
    if [[ -z "$trigger_at" || "$trigger_at" == "null" ]]; then
      echo "$line" >> "$tmp_reminders"
      continue
    fi
    
    trigger_epoch=$(date -u -d "$trigger_at" +%s 2>/dev/null || echo "")
    if [[ -z "$trigger_epoch" ]]; then
      echo "$line" >> "$tmp_reminders"
      continue
    fi
    
    if ((trigger_epoch <= now_epoch)); then
      # Due! Surface as ask action
      reminder_text=$(echo "$line" | jq -r '.reminder // "Reminder"')
      local importance
      importance=$(echo "$line" | jq -r '.importance // 0.5')
      local tags
      tags=$(echo "$line" | jq -c '.tags // []')
      
      if [[ "$MODE" != "dry_run_actions" ]]; then
        # Write to preconscious buffer
        local tag_str
        tag_str=$(echo "$tags" | jq -r 'join(", ")' | head -c 30)
        [[ -z "$tag_str" ]] && tag_str="reminder"
        
        {
          echo ""
          echo "🧠 **[$tag_str]** $reminder_text"
          echo "  _score: $importance | reminder due_"
        } >> "$PRECONSCIOUS_BUFFER"
        
        # Mark as delivered
        local updated_line
        updated_line=$(echo "$line" | jq -c '.status = "delivered" | .delivered_at = "'"$NOW"'"')
        echo "$updated_line" >> "$tmp_reminders"
        
        log "Surfaced due reminder: ${reminder_text:0:50}..."
        emit_stage_log "reminder_surfaced" "$(jq -cn --arg text "$reminder_text" '{reminder:$text}')"
      else
        echo "$line" >> "$tmp_reminders"
        log "[DRY RUN] Would surface due reminder: ${reminder_text:0:50}..."
      fi
      
      ((due_reminders_count++))
      ((ASK_COUNT++))
    else
      echo "$line" >> "$tmp_reminders"
    fi
  done < "$REMINDERS_FILE"
  
  # Atomic write back
  if [[ "$MODE" != "dry_run_actions" ]]; then
    mv "$tmp_reminders" "$REMINDERS_FILE"
  else
    rm -f "$tmp_reminders"
  fi
  
  log "Processed $due_reminders_count due reminders"
}

process_due_reminders

# ─── Step 1: Build Classification Prompt ─────────────────────────────────────
build_classification_prompt() {
  local insights_json="$1"
  local current_time current_hour time_period
  current_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  current_hour=$(date +%H)
  
  if ((10#$current_hour >= 6 && 10#$current_hour < 12)); then
    time_period="morning"
  elif ((10#$current_hour >= 12 && 10#$current_hour < 17)); then
    time_period="afternoon"
  elif ((10#$current_hour >= 17 && 10#$current_hour < 22)); then
    time_period="evening"
  else
    time_period="night"
  fi
  
  cat <<PROMPT
You are an action classifier for an AI assistant's rumination system. You receive enriched insights and must classify each one into an action type.

## Current Context
- Current time: $current_time
- Time period: $time_period
- Remaining budget: ask=$((MAX_ASK - ASK_COUNT)), learn=$((MAX_LEARN - LEARN_COUNT)), draft=$((MAX_DRAFT - DRAFT_COUNT)), notify=$((MAX_NOTIFY - NOTIFY_COUNT)), remind=$((MAX_REMIND - REMIND_COUNT))

## Action Types

1. **no_action** (DEFAULT) — Most insights need no action. Use this for:
   - General observations without actionable content
   - Already-handled items
   - Low importance items (< 0.5)
   - Routine status updates

2. **ask** — Surface a question to the user
   - For insights that need user input or decision
   - Format as a clear, specific question
   - Max 3 per run

3. **learn** — Store a confirmed fact
   - ONLY for importance >= 0.7 AND factual/confirmed information
   - Not opinions, not guesses, not questions
   - Max 5 per run

4. **draft** — Prepare something for user review
   - ONLY for importance >= 0.75
   - For things that need drafting: emails, messages, plans, summaries
   - Max 2 per run

5. **notify** — Send urgent notification
   - ONLY for importance >= 0.85 AND time-sensitive (expires within 4 hours)
   - Reserved for genuine emergencies
   - Max 2 per day (daily count: $DAILY_NOTIFY_COUNT)

6. **remind** — Set a future reminder
   - For items that need follow-up at a specific time
   - Must include a trigger_at time (ISO8601 format)
   - Max 3 per run

## Rules
- BE CONSERVATIVE. Most insights should be no_action.
- Only classify as ask/learn/draft/notify/remind if it genuinely needs that action.
- For notify: only truly urgent, time-sensitive items with high importance.
- For remind: the insight must have a clear future time component.
- For learn: must be a confirmed fact, not speculation.

## Insights to Classify
$insights_json

## Required Output Format (JSON only, no markdown)
{"actions": [{"insight_index": 0, "action": "no_action|ask|learn|draft|notify|remind", "content": "the specific text for the action", "trigger_at": "ISO8601 datetime or null (for remind only)"}]}

Return ONLY the JSON, no explanation.
PROMPT
}

CLASSIFICATION_MODEL="${CLASSIFICATION_MODEL:-$(aie_get "models.classification" "google/gemini-2.5-flash")}"
log "Building classification prompt for $INSIGHT_COUNT insights..."

CLASSIFICATION_PROMPT=$(build_classification_prompt "$INSIGHTS_JSON")

# ─── Step 2: Call LLM for Classification ─────────────────────────────────────
log "Calling LLM for action classification (model: $CLASSIFICATION_MODEL)..."

CLASSIFICATION_RESPONSE=$(call_openrouter "$CLASSIFICATION_PROMPT" 2000 0.2 "AIE Action Classification" "$CLASSIFICATION_MODEL")
CLASSIFICATION_EXIT=$?

if [[ $CLASSIFICATION_EXIT -ne 0 || -z "$CLASSIFICATION_RESPONSE" ]]; then
  log "ERROR: Classification LLM call failed"
  emit_stage_log "classification_failed" '{"error":"llm_call_failed"}'
  exit 1
fi

ACTIONS_JSON=$(extract_json "$CLASSIFICATION_RESPONSE")
if [[ $? -ne 0 || -z "$ACTIONS_JSON" ]]; then
  log "ERROR: Failed to extract JSON from classification response"
  emit_stage_log "classification_failed" '{"error":"json_extraction_failed"}'
  exit 1
fi

ACTIONS_ARRAY=$(echo "$ACTIONS_JSON" | jq -c '.actions // []')
ACTIONS_COUNT=$(echo "$ACTIONS_ARRAY" | jq 'length')
log "Classified $ACTIONS_COUNT actions"
emit_stage_log "classification_complete" "$(jq -cn --argjson count "$ACTIONS_COUNT" --argjson tokens "$TOKENS_USED" '{actions_count:$count, tokens_used:$tokens}')"

# ─── Step 3: Execute Actions ─────────────────────────────────────────────────

# Helper: Atomic file write
atomic_write() {
  local file="$1"
  local content="$2"
  local tmp
  tmp=$(mktemp)
  printf '%s' "$content" > "$tmp"
  mv "$tmp" "$file"
}

# Helper: Append to JSONL atomically
atomic_append_jsonl() {
  local file="$1"
  local line="$2"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$file" ]]; then
    cat "$file" > "$tmp"
  fi
  printf '%s\n' "$line" >> "$tmp"
  mv "$tmp" "$file"
}

# Action: ask
execute_ask() {
  local content="$1"
  local importance="${2:-0.6}"
  local tags="${3:-[]}"
  
  if ((ASK_COUNT >= MAX_ASK)); then
    log "Ask limit reached ($MAX_ASK), skipping: ${content:0:50}..."
    return 1
  fi
  
  if [[ "$MODE" == "dry_run_actions" ]]; then
    log "[DRY RUN] Would ask: ${content:0:80}..."
    ((ASK_COUNT++))
    return 0
  fi
  
  local tag_str
  tag_str=$(echo "$tags" | jq -r 'if type == "array" then join(", ") else . end' 2>/dev/null | head -c 30)
  [[ -z "$tag_str" || "$tag_str" == "null" ]] && tag_str="question"
  
  mkdir -p "$(dirname "$PRECONSCIOUS_BUFFER")"
  {
    echo ""
    echo "🧠 **[$tag_str]** $content"
    echo "  _score: $importance | 0h ago_"
  } >> "$PRECONSCIOUS_BUFFER"
  
  ((ASK_COUNT++))
  log "Asked: ${content:0:50}..."
  emit_stage_log "action_executed" "$(jq -cn --arg type "ask" --arg content "$content" '{action_type:$type, content:$content}')"
}

# Action: learn
execute_learn() {
  local fact="$1"
  local confidence="${2:-0.8}"
  local tags="${3:-[]}"
  
  if ((LEARN_COUNT >= MAX_LEARN)); then
    log "Learn limit reached ($MAX_LEARN), skipping: ${fact:0:50}..."
    return 1
  fi
  
  # Dedup check: compare first 50 chars
  if [[ -f "$LEARNED_FACTS_FILE" ]]; then
    local fact_prefix="${fact:0:50}"
    local existing
    existing=$(jq -r --arg prefix "$fact_prefix" '.facts[]? | select(.fact | startswith($prefix)) | .fact' "$LEARNED_FACTS_FILE" 2>/dev/null | head -1)
    if [[ -n "$existing" ]]; then
      log "Fact already learned (dedup): ${fact:0:50}..."
      return 1
    fi
  fi
  
  if [[ "$MODE" == "dry_run_actions" ]]; then
    log "[DRY RUN] Would learn: ${fact:0:80}..."
    ((LEARN_COUNT++))
    return 0
  fi
  
  mkdir -p "$(dirname "$LEARNED_FACTS_FILE")"
  
  local new_fact
  new_fact=$(jq -cn \
    --arg fact "$fact" \
    --arg source "rumination" \
    --argjson confidence "$confidence" \
    --arg learned_at "$NOW" \
    --argjson tags "$tags" \
    '{fact:$fact, source:$source, confidence:$confidence, learned_at:$learned_at, tags:$tags}')
  
  local current_facts new_content
  if [[ -f "$LEARNED_FACTS_FILE" ]]; then
    current_facts=$(jq -c '.facts // []' "$LEARNED_FACTS_FILE" 2>/dev/null || echo "[]")
  else
    current_facts="[]"
  fi
  
  new_content=$(jq -cn --argjson facts "$current_facts" --argjson new "$new_fact" '{facts: ($facts + [$new])}')
  atomic_write "$LEARNED_FACTS_FILE" "$new_content"
  
  ((LEARN_COUNT++))
  log "Learned: ${fact:0:50}..."
  emit_stage_log "action_executed" "$(jq -cn --arg type "learn" --arg content "$fact" '{action_type:$type, content:$content}')"
}

# Action: draft
execute_draft() {
  local content="$1"
  local description="${2:-draft}"
  local importance="${3:-0.75}"
  
  if ((DRAFT_COUNT >= MAX_DRAFT)); then
    log "Draft limit reached ($MAX_DRAFT), skipping: ${description:0:50}..."
    return 1
  fi
  
  # Clean description for filename
  local clean_desc
  clean_desc=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | head -c 30)
  [[ -z "$clean_desc" ]] && clean_desc="draft"
  
  local draft_file="$DRAFTS_DIR/$(date +%Y-%m-%d-%H)-${clean_desc}.md"
  
  if [[ "$MODE" == "dry_run_actions" ]]; then
    log "[DRY RUN] Would draft to $draft_file: ${content:0:80}..."
    ((DRAFT_COUNT++))
    return 0
  fi
  
  mkdir -p "$DRAFTS_DIR"
  
  local draft_content
  draft_content=$(cat <<EOF
# Draft: $description

_Created: ${NOW}_
_Importance: ${importance}_

---

$content
EOF
)
  
  atomic_write "$draft_file" "$draft_content"
  
  ((DRAFT_COUNT++))
  log "Drafted: $draft_file"
  emit_stage_log "action_executed" "$(jq -cn --arg type "draft" --arg file "$draft_file" '{action_type:$type, file:$file}')"
}

# Action: notify
execute_notify() {
  local message="$1"
  local importance="${2:-0.85}"
  
  if ((NOTIFY_COUNT >= MAX_NOTIFY)); then
    log "Notify limit reached ($MAX_NOTIFY), skipping: ${message:0:50}..."
    return 1
  fi
  
  if ((DAILY_NOTIFY_COUNT >= MAX_NOTIFY)); then
    log "Daily notify limit reached ($MAX_NOTIFY/day), demoting to ask: ${message:0:50}..."
    execute_ask "⚠️ [demoted notification] $message" "$importance" '["urgent"]'
    return $?
  fi
  
  # Check quiet hours
  if aie_is_quiet_hours; then
    log "Quiet hours active, demoting notify to ask: ${message:0:50}..."
    execute_ask "⚠️ [quiet hours - notification] $message" "$importance" '["urgent"]'
    return $?
  fi
  
  if [[ "$MODE" == "dry_run_actions" ]]; then
    log "[DRY RUN] Would notify: ${message:0:80}..."
    ((NOTIFY_COUNT++))
    ((DAILY_NOTIFY_COUNT++))
    return 0
  fi
  
  # Call emergency-surface.sh if it exists
  if [[ -x "$SCRIPT_DIR/emergency-surface.sh" ]]; then
    log "Calling emergency-surface.sh..."
    bash "$SCRIPT_DIR/emergency-surface.sh" "$message" 2>&1 | while read -r line; do log "  $line"; done
  else
    log "WARNING: emergency-surface.sh not found, logging only"
  fi
  
  ((NOTIFY_COUNT++))
  ((DAILY_NOTIFY_COUNT++))
  log "Notified: ${message:0:50}..."
  emit_stage_log "action_executed" "$(jq -cn --arg type "notify" --arg content "$message" '{action_type:$type, content:$content}')"
}

# Action: remind
execute_remind() {
  local reminder="$1"
  local trigger_at="$2"
  local importance="${3:-0.6}"
  local tags="${4:-[]}"
  
  if ((REMIND_COUNT >= MAX_REMIND)); then
    log "Remind limit reached ($MAX_REMIND), skipping: ${reminder:0:50}..."
    return 1
  fi
  
  # Validate trigger_at
  if [[ -z "$trigger_at" || "$trigger_at" == "null" ]]; then
    log "Reminder missing trigger_at, skipping: ${reminder:0:50}..."
    return 1
  fi
  
  # Validate it's a valid datetime
  if ! date -u -d "$trigger_at" +%s &>/dev/null; then
    log "Invalid trigger_at datetime '$trigger_at', skipping: ${reminder:0:50}..."
    return 1
  fi
  
  # Dedup: skip if a pending reminder with similar topic already exists
  # Uses first 30 chars to catch LLM rewording the same reminder differently
  if [[ -f "$REMINDERS_FILE" ]]; then
    local reminder_prefix="${reminder:0:30}"
    local existing_match
    existing_match=$(jq -r --arg prefix "$reminder_prefix" \
      'select(.status == "pending") | select(.reminder[0:30] | startswith($prefix[0:20])) | .reminder' \
      "$REMINDERS_FILE" 2>/dev/null | head -1)
    if [[ -n "$existing_match" ]]; then
      log "Reminder dedup: similar pending reminder already exists, skipping: ${reminder:0:50}..."
      return 0
    fi
  fi
  
  if [[ "$MODE" == "dry_run_actions" ]]; then
    log "[DRY RUN] Would remind at $trigger_at: ${reminder:0:80}..."
    ((REMIND_COUNT++))
    return 0
  fi
  
  mkdir -p "$(dirname "$REMINDERS_FILE")"
  
  local reminder_line
  reminder_line=$(jq -cn \
    --arg reminder "$reminder" \
    --arg trigger_at "$trigger_at" \
    --arg created_at "$NOW" \
    --argjson importance "$importance" \
    --arg status "pending" \
    --argjson tags "$tags" \
    '{reminder:$reminder, trigger_at:$trigger_at, created_at:$created_at, importance:$importance, status:$status, tags:$tags}')
  
  atomic_append_jsonl "$REMINDERS_FILE" "$reminder_line"
  
  ((REMIND_COUNT++))
  log "Reminder set for $trigger_at: ${reminder:0:50}..."
  emit_stage_log "action_executed" "$(jq -cn --arg type "remind" --arg content "$reminder" --arg trigger "$trigger_at" '{action_type:$type, content:$content, trigger_at:$trigger}')"
}

# Process each action
log "Executing classified actions..."

for i in $(seq 0 $((ACTIONS_COUNT - 1))); do
  ACTION_OBJ=$(echo "$ACTIONS_ARRAY" | jq -c ".[$i]")
  ACTION_TYPE=$(echo "$ACTION_OBJ" | jq -r '.action // "no_action"')
  ACTION_CONTENT=$(echo "$ACTION_OBJ" | jq -r '.content // ""')
  ACTION_TRIGGER=$(echo "$ACTION_OBJ" | jq -r '.trigger_at // null')
  INSIGHT_INDEX=$(echo "$ACTION_OBJ" | jq -r '.insight_index // 0')
  
  # Get insight details for importance/tags
  INSIGHT_OBJ=$(echo "$INSIGHTS_JSON" | jq -c ".[$INSIGHT_INDEX] // {}")
  INSIGHT_IMPORTANCE=$(echo "$INSIGHT_OBJ" | jq -r '.importance // 0.5')
  INSIGHT_TAGS=$(echo "$INSIGHT_OBJ" | jq -c '.tags // []')
  
  case "$ACTION_TYPE" in
    no_action)
      # Skip silently
      ;;
    ask)
      execute_ask "$ACTION_CONTENT" "$INSIGHT_IMPORTANCE" "$INSIGHT_TAGS"
      ;;
    learn)
      # Extra check: importance >= 0.7
      if awk -v imp="$INSIGHT_IMPORTANCE" 'BEGIN { exit (imp >= 0.7 ? 0 : 1) }'; then
        execute_learn "$ACTION_CONTENT" 0.8 "$INSIGHT_TAGS"
      else
        log "Learn action rejected: importance $INSIGHT_IMPORTANCE < 0.7"
      fi
      ;;
    draft)
      # Extra check: importance >= 0.75
      if awk -v imp="$INSIGHT_IMPORTANCE" 'BEGIN { exit (imp >= 0.75 ? 0 : 1) }'; then
        execute_draft "$ACTION_CONTENT" "rumination-draft" "$INSIGHT_IMPORTANCE"
      else
        log "Draft action rejected: importance $INSIGHT_IMPORTANCE < 0.75"
      fi
      ;;
    notify)
      # Extra check: importance >= 0.85
      if awk -v imp="$INSIGHT_IMPORTANCE" 'BEGIN { exit (imp >= 0.85 ? 0 : 1) }'; then
        execute_notify "$ACTION_CONTENT" "$INSIGHT_IMPORTANCE"
      else
        log "Notify action rejected: importance $INSIGHT_IMPORTANCE < 0.85, demoting to ask"
        execute_ask "⚠️ $ACTION_CONTENT" "$INSIGHT_IMPORTANCE" '["urgent"]'
      fi
      ;;
    remind)
      execute_remind "$ACTION_CONTENT" "$ACTION_TRIGGER" "$INSIGHT_IMPORTANCE" "$INSIGHT_TAGS"
      ;;
    *)
      log "Unknown action type: $ACTION_TYPE"
      ;;
  esac
done

log "Action execution complete: ask=$ASK_COUNT, learn=$LEARN_COUNT, draft=$DRAFT_COUNT, notify=$NOTIFY_COUNT, remind=$REMIND_COUNT"

# ─── Learned facts pruning: TTL + hard cap ────────────────────────────────────
# Prevents unbounded growth of learned-facts.json over long-running deployments.
# - Auto-learned facts (source=ambient_actions or source=rumination with auto tag) expire after TTL
# - Hard cap ensures file never exceeds MAX_TOTAL_FACTS entries
# - Facts from explicit user input (source=gavin_explicit or similar) are protected from TTL

MAX_TOTAL_FACTS="${AIE_LEARNED_FACTS_MAX:-100}"
FACT_TTL_DAYS="${AIE_LEARNED_FACTS_TTL_DAYS:-30}"

if [[ -f "$LEARNED_FACTS_FILE" ]] && [[ "$MODE" != "dry_run_actions" ]]; then
  TOTAL_FACTS=$(jq '.facts | length' "$LEARNED_FACTS_FILE" 2>/dev/null || echo 0)

  if [[ "$TOTAL_FACTS" -gt 0 ]]; then
    # TTL pruning: remove auto-sourced facts older than FACT_TTL_DAYS
    # Protected sources (not auto-pruned): any source NOT matching "ambient_actions"
    CUTOFF_DATE=$(date -u -d "-${FACT_TTL_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                  date -u -v-${FACT_TTL_DAYS}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                  echo "")

    if [[ -n "$CUTOFF_DATE" ]]; then
      TMP_PRUNE=$(mktemp)
      jq --arg cutoff "$CUTOFF_DATE" '
        .facts |= [.[] | select(
          .source != "ambient_actions" or
          (.learned_at // "9999") > $cutoff
        )]
      ' "$LEARNED_FACTS_FILE" > "$TMP_PRUNE" 2>/dev/null

      if jq empty "$TMP_PRUNE" 2>/dev/null; then
        PRUNED_COUNT=$(( TOTAL_FACTS - $(jq '.facts | length' "$TMP_PRUNE" 2>/dev/null || echo "$TOTAL_FACTS") ))
        if [[ $PRUNED_COUNT -gt 0 ]]; then
          mv "$TMP_PRUNE" "$LEARNED_FACTS_FILE"
          log "Pruned $PRUNED_COUNT expired auto-learned facts (older than ${FACT_TTL_DAYS}d)"
          emit_stage_log "prune_ttl" "$(jq -cn --argjson count "$PRUNED_COUNT" --argjson ttl "$FACT_TTL_DAYS" '{pruned:$count, ttl_days:$ttl}')"
        else
          rm -f "$TMP_PRUNE"
        fi
      else
        rm -f "$TMP_PRUNE"
        log "WARN: TTL prune jq failed, skipping"
      fi
    fi

    # Hard cap: if still over MAX_TOTAL_FACTS, drop oldest auto-learned facts
    TOTAL_FACTS=$(jq '.facts | length' "$LEARNED_FACTS_FILE" 2>/dev/null || echo 0)
    if [[ "$TOTAL_FACTS" -gt "$MAX_TOTAL_FACTS" ]]; then
      OVER_BY=$((TOTAL_FACTS - MAX_TOTAL_FACTS))
      TMP_CAP=$(mktemp)
      jq --argjson drop "$OVER_BY" '
        (.facts | map(select(.source == "ambient_actions")) | sort_by(.learned_at) | .[:$drop] | map(.fact)) as $to_remove |
        .facts |= [.[] | select((.fact as $f | $to_remove | index($f)) == null)]
      ' "$LEARNED_FACTS_FILE" > "$TMP_CAP" 2>/dev/null

      if jq empty "$TMP_CAP" 2>/dev/null; then
        mv "$TMP_CAP" "$LEARNED_FACTS_FILE"
        log "Hard cap: removed $OVER_BY oldest auto-learned facts (max $MAX_TOTAL_FACTS)"
        emit_stage_log "prune_cap" "$(jq -cn --argjson removed "$OVER_BY" --argjson max "$MAX_TOTAL_FACTS" '{removed:$removed, max_total:$max}')"
      else
        rm -f "$TMP_CAP"
        log "WARN: Hard cap jq failed, skipping"
      fi
    fi
  fi
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

FINAL_SUMMARY=$(jq -cn \
  --arg mode "$MODE" \
  --arg today_file "$TODAY_FILE" \
  --argjson insight_count "$INSIGHT_COUNT" \
  --argjson actions_classified "$ACTIONS_COUNT" \
  --argjson ask_count "$ASK_COUNT" \
  --argjson learn_count "$LEARN_COUNT" \
  --argjson draft_count "$DRAFT_COUNT" \
  --argjson notify_count "$NOTIFY_COUNT" \
  --argjson remind_count "$REMIND_COUNT" \
  --argjson tokens_used "$TOKENS_USED" \
  '{mode:$mode, rumination_file:$today_file, insight_count:$insight_count, actions_classified:$actions_classified, actions_executed:{ask:$ask_count,learn:$learn_count,draft:$draft_count,notify:$notify_count,remind:$remind_count}, tokens_used:$tokens_used, status:"complete"}')
emit_stage_log "summary" "$FINAL_SUMMARY"

log "=== Ambient actions END (mode=$MODE) ==="
exit 0
