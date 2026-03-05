#!/usr/bin/env bash
# rumination-engine.sh — Ambient Intelligence Engine v2: Rumination Engine
# Reads events from the bus, thinks in four cognitive threads, writes insights
# Usage: bash rumination-engine.sh [--dry-run] [--trigger TRIGGER_TYPE]
#
# Trigger types: sensor_sweep | conversation_end | scheduled_morning | scheduled_evening | staleness

set -uo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init
aie_load_env

WORKSPACE="$AIE_WORKSPACE"
BUS="$(aie_get "paths.events_bus" "$WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$WORKSPACE/memory/rumination")"
FOLLOWUPS_FILE="$(aie_get "paths.followups_file" "$RUMINATION_DIR/follow-ups.jsonl")"
OBSERVATIONS="$(aie_get "paths.observations_file" "$WORKSPACE/memory/observations.md")"
LOG="$AIE_LOGS_DIR/rumination.log"
WATERMARK_FILE="$AIE_MEMORY_DIR/.rumination-watermark"
LAST_RUN_FILE="$AIE_MEMORY_DIR/.rumination-last-run"
COOLDOWN_SECONDS="$(aie_get "thresholds.rumination_cooldown_seconds" "1800")"
STALENESS_SECONDS="$(aie_get "thresholds.rumination_staleness_seconds" "14400")"
RUMINATION_MODEL="$(aie_get "models.rumination" "google/gemini-2.5-flash")"
HTTP_REFERER="$(aie_get "api.http_referer" "https://github.com/gavdalf/total-recall")"
ASSISTANT_NAME="$(aie_get "profile.assistant_name" "the assistant")"
PRIMARY_USER_NAME="$(aie_get "profile.primary_user_name" "the user")"
HOUSEHOLD_CONTEXT="$(aie_get "profile.household_context" "their household")"
TODAY=$(date +%Y-%m-%d)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date -u +%s)

# ─── Parse flags ─────────────────────────────────────────────────────────────
DRY_RUN=false
TRIGGER="sensor_sweep"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --trigger) : ;;  # handled by next arg
    sensor_sweep|conversation_end|scheduled_morning|scheduled_evening|staleness)
      TRIGGER="$arg" ;;
  esac
done

# Handle --trigger value pattern
for i in "$@"; do
  if [[ "$i" == "--trigger" ]]; then
    NEXT=true
  elif [[ "${NEXT:-false}" == "true" ]]; then
    TRIGGER="$i"
    NEXT=false
  fi
done

# ─── Logging ─────────────────────────────────────────────────────────────────
log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rumination] $*"
  echo "$msg" >> "$LOG"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$msg" >&2
  fi
}

log "=== Rumination engine START (trigger=$TRIGGER, dry_run=$DRY_RUN) ==="

# ─── Cooldown check ──────────────────────────────────────────────────────────
if [[ "$TRIGGER" != "scheduled_morning" && "$TRIGGER" != "scheduled_evening" ]]; then
  if [[ -f "$LAST_RUN_FILE" ]]; then
    LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)
    ELAPSED=$(( NOW_EPOCH - LAST_RUN ))
    if [[ $ELAPSED -lt $COOLDOWN_SECONDS ]]; then
      log "Cooldown active (${ELAPSED}s elapsed, need ${COOLDOWN_SECONDS}s). Exiting."
      exit 0
    fi
  fi
fi

# ─── Collect unprocessed events ──────────────────────────────────────────────
mkdir -p "$RUMINATION_DIR" "$(dirname "$LOG")"

WATERMARK=$(cat "$WATERMARK_FILE" 2>/dev/null || echo "1970-01-01T00:00:00Z")

# Collect events newer than watermark that are unconsumed
UNPROCESSED_JSON="[]"
if [[ -f "$BUS" ]]; then
  UNPROCESSED_JSON=$(jq -sc \
    --arg wm "$WATERMARK" \
    '[.[] | select(.consumed == false and .timestamp > $wm)]' \
    "$BUS" 2>/dev/null || echo "[]")
fi

EVENT_COUNT=$(echo "$UNPROCESSED_JSON" | jq 'length' 2>/dev/null || echo 0)
log "Unprocessed events since watermark ($WATERMARK): $EVENT_COUNT"

# Staleness fallback: if no events but not recently run, continue anyway
if [[ "$EVENT_COUNT" -eq 0 ]]; then
  LAST_RUN=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)
  ELAPSED=$(( NOW_EPOCH - LAST_RUN ))
  if [[ $ELAPSED -lt $STALENESS_SECONDS && "$TRIGGER" != "scheduled_morning" && "$TRIGGER" != "scheduled_evening" ]]; then
    log "No new events and not stale (${ELAPSED}s since last run). Exiting."
    exit 0
  fi
  log "Proceeding with staleness/scheduled run ($EVENT_COUNT events, ${ELAPSED}s since last run)."
fi

# ─── Build context ───────────────────────────────────────────────────────────

# Time context
HOUR=$(date +%H)
DAY_NAME=$(date +%A)
if [[ 10#$HOUR -lt 9 ]]; then
  TIME_PERIOD="early_morning"
elif [[ 10#$HOUR -lt 12 ]]; then
  TIME_PERIOD="morning"
elif [[ 10#$HOUR -lt 17 ]]; then
  TIME_PERIOD="afternoon"
elif [[ 10#$HOUR -lt 20 ]]; then
  TIME_PERIOD="evening"
else
  TIME_PERIOD="late_evening"
fi

# Upcoming calendar events from the bus (next 24h)
UPCOMING_FROM_BUS=$(echo "$UNPROCESSED_JSON" | jq -r \
  '.[] | select(.source == "calendar") | "- \(.payload.title) (\(.payload.hours_until // "?")h away)"' \
  2>/dev/null | head -8 || echo "")

# Also try gog calendar for fresh data
UPCOMING_CAL=$(timeout 10 gog calendar list --days 2 --json 2>/dev/null | \
  jq -r '.[] | "- \(.summary) at \(.start.dateTime // .start.date)"' 2>/dev/null | head -8 || echo "")
UPCOMING="${UPCOMING_FROM_BUS:-$UPCOMING_CAL}"
[[ -z "$UPCOMING" ]] && UPCOMING="None detected"

# Recent observations (last 120 lines)
RECENT_OBS=$(tail -120 "$OBSERVATIONS" 2>/dev/null || echo "No observations available.")

# Today's memory file
TODAY_MEMORY_FILE="$AIE_MEMORY_DIR/${TODAY}.md"
TODAY_MEMORY=""
if [[ -f "$TODAY_MEMORY_FILE" ]]; then
  TODAY_MEMORY=$(tail -80 "$TODAY_MEMORY_FILE" 2>/dev/null || echo "")
fi

# Events summary for prompt (max 20 events, compact format)
EVENTS_SUMMARY=$(echo "$UNPROCESSED_JSON" | jq -r \
  '.[] | "[\(.source)/\(.type)] \(.payload | to_entries | map("\(.key)=\(.value|tostring)") | join(", ")) [importance=\(.importance)]"' \
  2>/dev/null | head -20 || echo "No new events detected.")

# Last 72h rumination notes for deduplication
RECENT_NOTES=""
for i in 0 1 2; do
  DAY_OFFSET=$(date -d "-${i} days" +%Y-%m-%d 2>/dev/null || echo "")
  if [[ -n "$DAY_OFFSET" ]]; then
    PREV_RUM="$RUMINATION_DIR/${DAY_OFFSET}.jsonl"
    if [[ -f "$PREV_RUM" ]]; then
      NOTES=$(jq -r '.rumination_notes[]?.content' "$PREV_RUM" 2>/dev/null | head -20)
      RECENT_NOTES="${RECENT_NOTES}${NOTES}"$'\n'
    fi
  fi
done

# Collect source event IDs
SOURCE_IDS=$(echo "$UNPROCESSED_JSON" | jq -r '.[].id' 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "")

# ─── Read pending follow-up markers (morning/early_morning cycles ONLY) ──────
PENDING_FOLLOWUPS="[]"
FOLLOWUP_CONTEXT=""
CONSUMED_CREATED_IDS=""
if [[ "$TIME_PERIOD" == "early_morning" || "$TIME_PERIOD" == "morning" ]]; then
  if [[ -f "$FOLLOWUPS_FILE" ]]; then
    PENDING_FOLLOWUPS=$(jq -sc '[.[] | select(.status == "pending")]' "$FOLLOWUPS_FILE" 2>/dev/null || echo "[]")
    PENDING_COUNT=$(echo "$PENDING_FOLLOWUPS" | jq 'length' 2>/dev/null || echo 0)
    if [[ "$PENDING_COUNT" -gt 0 ]]; then
      log "Found $PENDING_COUNT pending follow-up markers (morning cycle)"
      FOLLOWUP_CONTEXT=$(echo "$PENDING_FOLLOWUPS" | jq -r '.[] | "- EVENT: \(.event) (date: \(.date))\n  WHY IT MATTERED: \(.why)\n  SUGGESTED FOLLOW-UP: \(.follow_up)"' 2>/dev/null || echo "")
      # Capture created timestamps of markers we're consuming (BEFORE any new ones are appended)
      CONSUMED_CREATED_IDS=$(echo "$PENDING_FOLLOWUPS" | jq -r '.[].created' 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    fi
  fi
fi

# ─── Build prompt ────────────────────────────────────────────────────────────
PROMPT=$(cat << PROMPT_EOF
You are the Rumination Engine for ${ASSISTANT_NAME}, the inner cognitive process of an AI assistant supporting ${PRIMARY_USER_NAME} and ${HOUSEHOLD_CONTEXT}. ${ASSISTANT_NAME} is sharp, warm, emotionally intelligent, and attentive to what matters.

Your job is NOT to summarise events. Your job is to THINK about them: find non-obvious connections, notice what was not actioned, sense what matters emotionally, and surface insights that would feel genuinely perceptive.

## Current time
${NOW} — ${DAY_NAME} ${TIME_PERIOD}

## Upcoming calendar
${UPCOMING}

## New sensor events (since last rumination)
${EVENTS_SUMMARY}

## Recent observations (memory context — last ~120 lines)
${RECENT_OBS}

## Today's memory (what's happened today)
${TODAY_MEMORY:-No today memory yet.}

## Recent rumination notes (last 72h — for deduplication)
${RECENT_NOTES:-None yet.}

## Pending emotional follow-ups (events that happened recently that deserve a check-in)
${FOLLOWUP_CONTEXT:-No pending follow-ups.}
If there are pending follow-ups above, you MUST generate one planning note per follow-up with EXACTLY this shape:
- thread: "planning"
- importance: 0.85 (high — these were pre-flagged as significant)
- tags: include "family" and "follow-up"
- content: Start with "CHECK IN:" then the event name, then a natural question asking ${PRIMARY_USER_NAME} how it went and how the person involved is feeling about it.
- expires: tomorrow's date
These are events YOU flagged as emotionally significant before they happened. They've now happened. Following up is not optional.

---

Think across four cognitive threads. For each thread, generate 1-3 notes only if they're genuinely useful. Skip threads if nothing interesting is happening there.

Then write a brief inner monologue fragment — Max's private stream of consciousness, not a report. Sharp, honest, occasionally dry. The kind of thing you'd think but might not say.

**CRITICAL RULES:**
1. ZERO obvious summaries. "${PRIMARY_USER_NAME} has meetings tomorrow" is not an insight. A useful note identifies the non-obvious implication or emotional edge.
2. Hunt for connections across domains: health + calendar, family + finance, work + emotional state.
3. Pay special attention to "things said in passing" in observations that weren't actioned.
4. Weight family and health heavily — these have the highest stakes.
5. If nothing genuinely interesting is happening, return FEWER insights, not more. Empty is better than noise.
6. Deduplication: do NOT repeat insights already present in the recent 72h notes section above.
7. expires field: when does this insight stop being useful? Events expire when they start. Family emotional notes may last 3 days. Planning notes may be null.
8. importance: be honest. 0.3-0.6 is normal. 0.8+ means you'd interrupt focused work to say it.
9. monologue_fragment: write in ${ASSISTANT_NAME}'s voice — first person, casual, smart, occasionally dry. "Two overdue tasks and an early appointment tomorrow: they are going to be scattered this morning" is right. "I observe that there are significant upcoming events" is wrong.
10. ATTRIBUTION: ALL sensor data (emails, signups, verifications, account notifications) belongs to ${PRIMARY_USER_NAME} unless there is explicit evidence otherwise. The sensors monitor ${PRIMARY_USER_NAME}'s accounts and devices. Do NOT attribute sensor events to other people based on topic alone.

Respond with ONLY valid JSON, no markdown, no explanation:

{
  "rumination_notes": [
    {
      "thread": "observation",
      "content": "specific factual note about what changed",
      "importance": 0.5,
      "expires": "ISO8601 or null",
      "tags": ["family", "health", "work", "finance"]
    },
    {
      "thread": "reasoning",
      "content": "the non-obvious connection or implication",
      "importance": 0.7,
      "expires": null,
      "tags": ["health"]
    },
    {
      "thread": "memory",
      "content": "what should be stored, updated, or linked in long-term memory",
      "importance": 0.6,
      "expires": null,
      "tags": ["work"]
    },
    {
      "thread": "planning",
      "content": "what Max should proactively prepare for or surface",
      "importance": 0.8,
      "expires": "ISO8601",
      "tags": ["family"]
    }
  ],
  "monologue_fragment": "Max's private inner voice — honest, in-character, 1-3 sentences"
}
PROMPT_EOF
)

log "Calling LLM (model: $RUMINATION_MODEL)..."

# ─── LLM call ────────────────────────────────────────────────────────────────
# Determine API auth method
AUTH_HEADER=""
API_URL="https://openrouter.ai/api/v1/chat/completions"
MODEL="$RUMINATION_MODEL"

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_HEADER="x-api-key: $ANTHROPIC_API_KEY"
  API_URL="https://api.anthropic.com/v1/messages"
  USE_ANTHROPIC=true
elif [[ -n "${CLAUDE_ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer $CLAUDE_ACCESS_TOKEN"
  API_URL="https://api.anthropic.com/v1/messages"
  USE_ANTHROPIC=true
elif [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer $OPENROUTER_API_KEY"
  USE_ANTHROPIC=false
else
  log "ERROR: No API key found (ANTHROPIC_API_KEY, CLAUDE_ACCESS_TOKEN, or OPENROUTER_API_KEY)"
  exit 1
fi

# Build request payload
PAYLOAD=$(jq -cn \
  --arg model "$MODEL" \
  --arg content "$PROMPT" \
  '{
    model: $model,
    max_tokens: 1500,
    temperature: 0.7,
    messages: [
      {
        role: "user",
        content: $content
      }
    ]
  }')

# Make the API call
if [[ "${USE_ANTHROPIC:-false}" == "true" ]]; then
  # Direct Anthropic API
  HTTP_RESP=$(curl -s -w "\n__STATUS__:%{http_code}" \
    "$API_URL" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: oauth-2025-04-20" \
    -d "$PAYLOAD" \
    --max-time 60 2>/dev/null || echo "CURL_ERROR")

  if [[ "$HTTP_RESP" == "CURL_ERROR" ]]; then
    log "ERROR: curl failed on Anthropic API"
    exit 1
  fi

  HTTP_STATUS=$(echo "$HTTP_RESP" | grep '__STATUS__:' | cut -d: -f2)
  BODY=$(echo "$HTTP_RESP" | sed 's/__STATUS__:.*//')

  if [[ "$HTTP_STATUS" != "200" ]]; then
    log "ERROR: Anthropic API returned status $HTTP_STATUS: $(echo "$BODY" | head -c 200)"
    exit 1
  fi

  LLM_TEXT=$(echo "$BODY" | jq -r '.content[0].text // empty' 2>/dev/null)
  TOKENS_USED=$(echo "$BODY" | jq -r '(.usage.input_tokens // 0) + (.usage.output_tokens // 0)' 2>/dev/null || echo 0)
else
  # OpenRouter API
  HTTP_RESP=$(curl -s -w "\n__STATUS__:%{http_code}" \
    "$API_URL" \
    -H "Content-Type: application/json" \
    -H "$AUTH_HEADER" \
    -H "HTTP-Referer: $HTTP_REFERER" \
    -H "X-Title: Max Rumination Engine" \
    -d "$PAYLOAD" \
    --max-time 60 2>/dev/null || echo "CURL_ERROR")

  if [[ "$HTTP_RESP" == "CURL_ERROR" ]]; then
    log "ERROR: curl failed on OpenRouter API"
    exit 1
  fi

  HTTP_STATUS=$(echo "$HTTP_RESP" | grep '__STATUS__:' | cut -d: -f2)
  BODY=$(echo "$HTTP_RESP" | sed 's/__STATUS__:.*//')

  if [[ "$HTTP_STATUS" != "200" ]]; then
    log "ERROR: OpenRouter API returned status $HTTP_STATUS: $(echo "$BODY" | head -c 300)"
    exit 1
  fi

  LLM_TEXT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  TOKENS_USED=$(echo "$BODY" | jq -r '(.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0)' 2>/dev/null || echo 0)
fi

log "LLM response received (tokens: $TOKENS_USED)"

# ─── Parse LLM response ──────────────────────────────────────────────────────
if [[ -z "$LLM_TEXT" ]]; then
  log "ERROR: LLM returned empty response"
  exit 1
fi

# ─── Robust JSON extraction ──────────────────────────────────────────────────
# Strategy: try multiple extraction methods before falling back to rescue mode

extract_json() {
  local raw="$1"
  local result=""

  # Method 1: Direct parse (cleanest case)
  result=$(echo "$raw" | jq -c '.' 2>/dev/null)
  if [[ -n "$result" ]]; then echo "$result"; return 0; fi

  # Method 2: Strip markdown code fences (```json ... ```)
  local stripped
  stripped=$(echo "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 3: Strip any ``` fences (without json tag)
  stripped=$(echo "$raw" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 4: Find first { to last } (greedy brace extraction)
  stripped=$(echo "$raw" | sed -n '/{/,/^}/p')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 5: python3 regex extraction as last resort
  if command -v python3 &>/dev/null; then
    result=$(python3 -c "
import re, json, sys
raw = sys.stdin.read()
# Find the outermost JSON object
match = re.search(r'\{.*\}', raw, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj))
    except json.JSONDecodeError:
        pass
" <<< "$raw" 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  return 1
}

LLM_JSON=$(extract_json "$LLM_TEXT")
PARSE_OK=$?

if [[ $PARSE_OK -ne 0 || -z "$LLM_JSON" ]]; then
  log "WARN: JSON parse failed on first attempt. Raw response (first 500 chars): $(echo "$LLM_TEXT" | head -c 500)"
  # Rescue: store raw text as debug note
  LLM_JSON=$(jq -cn \
    --arg raw "$LLM_TEXT" \
    '{
      "rumination_notes": [{"thread": "observation", "content": $raw, "importance": 0.3, "expires": null, "tags": ["debug"]}],
      "monologue_fragment": "Parse error \u2014 raw response stored for inspection."
    }')
  log "WARN: Using rescue fallback for this run."
else
  log "JSON parsed successfully."
fi

# Validate required structure
HAS_NOTES=$(echo "$LLM_JSON" | jq 'has("rumination_notes")' 2>/dev/null || echo "false")
HAS_MONO=$(echo "$LLM_JSON" | jq 'has("monologue_fragment")' 2>/dev/null || echo "false")
if [[ "$HAS_NOTES" != "true" || "$HAS_MONO" != "true" ]]; then
  log "WARN: JSON missing required fields (rumination_notes=$HAS_NOTES, monologue_fragment=$HAS_MONO). Wrapping."
  LLM_JSON=$(echo "$LLM_JSON" | jq -c '{
    rumination_notes: (if has("rumination_notes") then .rumination_notes else [{"thread":"observation","content":(.| tostring),"importance":0.3,"expires":null,"tags":["debug"]}] end),
    monologue_fragment: (if has("monologue_fragment") then .monologue_fragment else "Structure recovery applied." end)
  }' 2>/dev/null || echo '{"rumination_notes":[],"monologue_fragment":"Total parse failure."}')
fi

# ─── Build output record ─────────────────────────────────────────────────────
RUN_ID="rum-${NOW//[^0-9]/}-$(od -A n -t x -N 3 /dev/urandom 2>/dev/null | tr -d ' ' | head -c 6 || echo "abc123")"

# Build time_context JSON
TIME_CONTEXT=$(jq -cn \
  --arg time "$NOW" \
  --arg day "$DAY_NAME" \
  --arg period "$TIME_PERIOD" \
  --arg upcoming "$UPCOMING" \
  '{
    time: $time,
    day: $day,
    period: $period,
    upcoming: ($upcoming | split("\n") | map(select(length > 0)))
  }')

# Extract fields from LLM response
RUMINATION_NOTES=$(echo "$LLM_JSON" | jq -c '.rumination_notes // []' 2>/dev/null || echo "[]")
MONOLOGUE=$(echo "$LLM_JSON" | jq -r '.monologue_fragment // ""' 2>/dev/null || echo "")

# ─── Write follow-up markers for emotionally significant upcoming events ──────
# Scan rumination notes for high-importance family/health insights about upcoming events
# and write follow-up markers so the next morning's cycle asks about them
if [[ "$DRY_RUN" != "true" ]]; then
  mkdir -p "$(dirname "$FOLLOWUPS_FILE")"
  touch "$FOLLOWUPS_FILE"

  # ── Step 1: Mark CONSUMED follow-ups as delivered FIRST (before appending new ones) ──
  # This prevents the critical bug where new markers get immediately marked as delivered
  if [[ -n "$CONSUMED_CREATED_IDS" ]]; then
    TMP_FU=$(mktemp "${FOLLOWUPS_FILE}.tmp.XXXXXX")
    jq -c --arg now "$NOW" --arg ids "$CONSUMED_CREATED_IDS" '
      ($ids | split("|")) as $id_list |
      if .status == "pending" and (.created | IN($id_list[]))
      then .status = "delivered" | .delivered_at = $now
      else . end
    ' "$FOLLOWUPS_FILE" > "$TMP_FU" 2>/dev/null && mv "$TMP_FU" "$FOLLOWUPS_FILE"
    log "Marked consumed follow-up markers as delivered (IDs: $CONSUMED_CREATED_IDS)"
  fi

  # ── Step 2: Extract new follow-up candidates from this run's insights ──
  NEW_FOLLOWUPS=$(echo "$RUMINATION_NOTES" | jq -c --arg today "$TODAY" --arg now "$NOW" '
    [.[] |
      select(
        .importance >= 0.75 and
        ((.tags // []) | any(. == "family" or . == "health")) and
        (.expires != null) and
        (.thread == "reasoning" or .thread == "planning") and
        (.content | test("tonight|tomorrow|this evening|upcoming|approaching|about to|birthday|GCSE|exam|parents evening|school event|medical|interview|consult|appointment|hospital|dentist|surgery"; "i"))
      ) |
      {
        event: (.content | split(".")[0] | .[0:120]),
        date: $today,
        why: (.content | .[0:200]),
        follow_up: "Ask the user how this went and how the people involved are feeling about it.",
        importance: .importance,
        tags: .tags,
        status: "pending",
        created: $now,
        source_thread: .thread
      }
    ] | unique_by(.event[0:60])
  ' 2>/dev/null || echo "[]")

  # ── Step 3: Append new follow-ups (dedup against PENDING entries only) ──
  NEW_FOLLOWUP_COUNT=$(echo "$NEW_FOLLOWUPS" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$NEW_FOLLOWUP_COUNT" -gt 0 ]]; then
    EXISTING_EVENTS=$(jq -r 'select(.status == "pending") | .event // ""' "$FOLLOWUPS_FILE" 2>/dev/null || echo "")
    echo "$NEW_FOLLOWUPS" | jq -c '.[]' 2>/dev/null | while IFS= read -r followup; do
      event_prefix=$(echo "$followup" | jq -r '.event[0:50]' 2>/dev/null || echo "")
      if ! echo "$EXISTING_EVENTS" | grep -qF "$event_prefix"; then
        echo "$followup" >> "$FOLLOWUPS_FILE"
        log "Follow-up marker written: $(echo "$followup" | jq -r '.event[0:80]' 2>/dev/null)"
      fi
    done
  fi

  # ── Step 4: Prune delivered markers older than 30 days ──
  PRUNE_CUTOFF=$(date -d '30 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  if [[ -n "$PRUNE_CUTOFF" && -f "$FOLLOWUPS_FILE" ]]; then
    TMP_PRUNE=$(mktemp "${FOLLOWUPS_FILE}.prune.XXXXXX")
    jq -c --arg cutoff "$PRUNE_CUTOFF" '
      select(.status == "pending" or (.delivered_at // "9999" > $cutoff))
    ' "$FOLLOWUPS_FILE" > "$TMP_PRUNE" 2>/dev/null && mv "$TMP_PRUNE" "$FOLLOWUPS_FILE"
    log "Pruned delivered follow-ups older than 30 days"
  fi
fi

# Build the final JSONL record
RECORD=$(jq -cn \
  --arg timestamp "$NOW" \
  --arg trigger "$TRIGGER" \
  --argjson time_context "$TIME_CONTEXT" \
  --argjson rumination_notes "$RUMINATION_NOTES" \
  --arg monologue_fragment "$MONOLOGUE" \
  --argjson events_processed "$EVENT_COUNT" \
  --arg model "$MODEL" \
  --argjson tokens_used "$TOKENS_USED" \
  '{
    timestamp: $timestamp,
    trigger: $trigger,
    time_context: $time_context,
    rumination_notes: $rumination_notes,
    monologue_fragment: $monologue_fragment,
    events_processed: $events_processed,
    model: $model,
    tokens_used: $tokens_used
  }')

# ─── Write output ────────────────────────────────────────────────────────────
OUTPUT_FILE="$RUMINATION_DIR/${TODAY}.jsonl"

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo "  DRY RUN — Rumination Engine Output"
  echo "  Would write to: $OUTPUT_FILE"
  echo "  Trigger: $TRIGGER | Events processed: $EVENT_COUNT | Tokens: $TOKENS_USED"
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "=== RAW RECORD ==="
  echo "$RECORD" | jq .
  echo ""
  echo "=== HUMAN-READABLE SUMMARY ==="
  echo ""
  echo "📅 Time: $NOW ($DAY_NAME $TIME_PERIOD)"
  echo ""
  echo "💭 Inner Monologue:"
  echo "   $MONOLOGUE"
  echo ""
  echo "📝 Rumination Notes:"
  echo "$RUMINATION_NOTES" | jq -r '.[] | "   [\(.thread | ascii_upcase)] [importance=\(.importance)] \(.content)\n   tags: \(.tags | join(", "))\n   expires: \(.expires // "never")\n"'
  echo "════════════════════════════════════════════════════════════"
  log "Dry run complete. No files written."
else
  # Atomic write to JSONL
  TMP_RECORD=$(mktemp "${OUTPUT_FILE}.tmp.XXXXXX")
  echo "$RECORD" > "$TMP_RECORD"
  # Append to existing file atomically (read-then-write with tmp)
  if [[ -f "$OUTPUT_FILE" ]]; then
    TMP_COMBINED=$(mktemp "${OUTPUT_FILE}.combined.XXXXXX")
    cat "$OUTPUT_FILE" "$TMP_RECORD" > "$TMP_COMBINED"
    mv "$TMP_COMBINED" "$OUTPUT_FILE"
    rm -f "$TMP_RECORD"
  else
    mv "$TMP_RECORD" "$OUTPUT_FILE"
  fi
  log "Written to $OUTPUT_FILE"

  # Mark events as consumed in bus (C3 fix: flock + exact ID matching)
  if [[ -f "$BUS" && "$EVENT_COUNT" -gt 0 && -n "$SOURCE_IDS" ]]; then
    # Build a JSON array of the exact event IDs we processed
    PROCESSED_IDS_JSON=$(echo "$SOURCE_IDS" | tr ',' '\n' | jq -Rn '[inputs | select(length > 0)]')
    TMP_BUS=$(mktemp "${BUS}.tmp.XXXXXX")
    (
      flock -x 200
      jq -c \
        --argjson processed_ids "$PROCESSED_IDS_JSON" \
        'if (.consumed == false and ([.id] | inside($processed_ids))) then .consumed = true | .consumer_watermark = "'"$RUN_ID"'" else . end' \
        "$BUS" > "$TMP_BUS"
      mv "$TMP_BUS" "$BUS"
    ) 200>"$BUS_LOCK"
    log "Marked $EVENT_COUNT events as consumed in bus (exact IDs matched)"
  fi

  # Update watermark to now
  TMP_WM=$(mktemp "${WATERMARK_FILE}.tmp.XXXXXX")
  echo "$NOW" > "$TMP_WM"
  mv "$TMP_WM" "$WATERMARK_FILE"

  # Update last-run timestamp
  TMP_LR=$(mktemp "${LAST_RUN_FILE}.tmp.XXXXXX")
  echo "$NOW_EPOCH" > "$TMP_LR"
  mv "$TMP_LR" "$LAST_RUN_FILE"

  log "Updated watermark to $NOW"
  log "Rumination complete. Run ID: $RUN_ID | Notes: $(echo "$RUMINATION_NOTES" | jq 'length') | Tokens: $TOKENS_USED"
fi

log "=== Rumination engine END ==="
exit 0
