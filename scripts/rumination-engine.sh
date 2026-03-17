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
source "$SCRIPT_DIR/aie-tools.sh"
source "$SCRIPT_DIR/google-api.sh"

# Normalize LLM provider vars (LLM_API_KEY preferred; OPENROUTER_API_KEY backward-compatible)
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"

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
mkdir -p "$RUMINATION_DIR" "$(dirname "$LOG")"

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

# Also try calendar API for fresh data
UPCOMING_CAL=$(timeout 10 gapi_calendar_events "primary" --days 2 --json 2>/dev/null | \
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

Then write a brief inner monologue fragment — ${ASSISTANT_NAME}'s private stream of consciousness, not a report. Sharp, honest, occasionally dry. The kind of thing you'd think but might not say.

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
      "content": "what ${ASSISTANT_NAME} should proactively prepare for or surface",
      "importance": 0.8,
      "expires": "ISO8601",
      "tags": ["family"]
    }
  ],
  "monologue_fragment": "${ASSISTANT_NAME}'s private inner voice — honest, in-character, 1-3 sentences"
}
PROMPT_EOF
)

log "Calling LLM (model: $RUMINATION_MODEL)..."

# ─── LLM call ────────────────────────────────────────────────────────────────
# Determine API auth method
AUTH_HEADER=""
MODEL="$RUMINATION_MODEL"

if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_HEADER="x-api-key: $ANTHROPIC_API_KEY"
  API_URL="https://api.anthropic.com/v1/messages"
  USE_ANTHROPIC=true
elif [[ -n "${CLAUDE_ACCESS_TOKEN:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer $CLAUDE_ACCESS_TOKEN"
  API_URL="https://api.anthropic.com/v1/messages"
  USE_ANTHROPIC=true
elif [[ -n "${LLM_API_KEY:-}" ]]; then
  AUTH_HEADER="Authorization: Bearer $LLM_API_KEY"
  API_URL="${LLM_BASE_URL%/}/chat/completions"
  USE_ANTHROPIC=false
else
  log "ERROR: No API key found. Set LLM_API_KEY (or OPENROUTER_API_KEY) in your .env file."
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
    -H "X-Title: ${ASSISTANT_NAME} Rumination Engine" \
    -d "$PAYLOAD" \
    --max-time 60 2>/dev/null || echo "CURL_ERROR")

  if [[ "$HTTP_RESP" == "CURL_ERROR" ]]; then
    log "ERROR: curl failed on OpenRouter API"
    exit 1
  fi

  HTTP_STATUS=$(echo "$HTTP_RESP" | grep '__STATUS__:' | cut -d: -f2)
  BODY=$(echo "$HTTP_RESP" | sed 's/__STATUS__:.*//')

  if [[ "$HTTP_STATUS" != "200" ]]; then
    case "$HTTP_STATUS" in
      401|403)
        log "ERROR: API returned $HTTP_STATUS — invalid or unauthorized API key. Check LLM_API_KEY / OPENROUTER_API_KEY in your .env." ;;
      402)
        log "ERROR: API returned 402 — payment required. If using OpenRouter, check your credit balance at https://openrouter.ai/settings/credits" ;;
      429)
        log "ERROR: API returned 429 — rate limit exceeded. Consider increasing COOLDOWN_SECONDS or trying later." ;;
      5*)
        log "ERROR: API returned $HTTP_STATUS — provider outage or transient failure. Try again later. Body: $(echo "$BODY" | head -c 200)" ;;
      *)
        log "ERROR: API returned status $HTTP_STATUS: $(echo "$BODY" | head -c 300)" ;;
    esac
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

# ─── Parse JSON from LLM response (uses extract_json from aie-tools.sh) ──────
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

# ─── Extract core fields from validated LLM JSON ─────────────────────────────
RUMINATION_NOTES=$(echo "$LLM_JSON" | jq -c '.rumination_notes // []' 2>/dev/null || echo "[]")
MONOLOGUE=$(echo "$LLM_JSON" | jq -r '.monologue_fragment // ""' 2>/dev/null || echo "")

# ─── Cycle State (Working Memory) ────────────────────────────────────────────
CYCLE_STATE_FILE="$RUMINATION_DIR/cycle-state.json"
CYCLE_STATE_DEFAULT='{"version":1,"last_updated":"","lookups":[],"ttl_hours":4,"max_entries":50}'

if [[ -f "$CYCLE_STATE_FILE" ]]; then
  CYCLE_STATE=$(jq -c '.' "$CYCLE_STATE_FILE" 2>/dev/null || echo "$CYCLE_STATE_DEFAULT")
else
  CYCLE_STATE="$CYCLE_STATE_DEFAULT"
fi

# Prune entries older than ttl_hours
CYCLE_TTL_HOURS=$(echo "$CYCLE_STATE" | jq -r '.ttl_hours // 4' 2>/dev/null || echo 4)
CYCLE_STATE=$(echo "$CYCLE_STATE" | jq -c \
  --arg now "$NOW" \
  --argjson ttl "$CYCLE_TTL_HOURS" '
  .lookups = [
    .lookups[] |
    select(
      (now - (.timestamp | if . == "" then 0 else (try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0) end)) < ($ttl * 3600)
    )
  ]
' 2>/dev/null || echo "$CYCLE_STATE")
log "Cycle state loaded ($(echo "$CYCLE_STATE" | jq '.lookups | length' 2>/dev/null || echo 0) cached entries, ttl=${CYCLE_TTL_HOURS}h)"

# ─── Insight Classification (moved from ambient-actions) ─────────────────────
CANDIDATE_ACTIONS="[]"
ALLOWED_TOOLS="calendar_lookup gmail_search gmail_read ionos_search todoist_query weather fitbit_data github_status openrouter_balance web_search places_lookup"

NOTES_FOR_CLASS=$(echo "$RUMINATION_NOTES" | jq -r '.[] | "[\(.thread | ascii_upcase)] [importance=\(.importance)] \(.content)"' 2>/dev/null | head -30)

CLASS_PROMPT=$(cat << CLASS_EOF
You are the classification layer of an AI assistant. Given a set of rumination insights, decide which (if any) real-time lookups would meaningfully enrich them.

## Available tools
- calendar_lookup: query="search term" — upcoming events, schedule conflicts
- gmail_search: query="search terms" — search primary Gmail inbox (${GMAIL_ACCOUNT:-your-gmail@example.com})
- gmail_read: query="message_id" — read a specific Gmail message body
- ionos_search: query="search terms" — search secondary IONOS email account (work/external)
- todoist_query: query="filter" — check tasks/todos
- weather: query="location or empty" — current weather conditions
- fitbit_data: query="" — health metrics (sleep, steps, heart rate, weight)
- github_status: query="" — GitHub notifications and repo activity
- openrouter_balance: query="" — check AI API credit balance
- web_search: query="search terms" — live web search for breaking news or facts
- places_lookup: query="place type or name" — nearby places of interest

## Rules
1. Only recommend lookups that would DIRECTLY enrich one of the insights listed below.
2. Maximum 5 lookups total. Prefer quality over quantity.
3. EMAIL ACCOUNTS — CRITICAL: There are TWO email accounts:
   - gmail_search/gmail_read = personal Gmail (${GMAIL_ACCOUNT:-your-gmail@example.com}) — personal correspondence, receipts, notifications
   - ionos_search = work/professional IONOS account — client emails, invoices, professional contacts
   Use the correct account. When in doubt about which account an email thread lives in, check BOTH.
4. ATTRIBUTION: All sensor data belongs to the primary user unless there is explicit evidence otherwise.
5. If no lookup would genuinely help, return an empty actions array.
6. Each action must have: tool (string), query (string), reason (string, max 60 chars), importance (float 0-1)

Respond with ONLY valid JSON:
{"actions": [{"tool": "...", "query": "...", "reason": "...", "importance": 0.7}]}
CLASS_EOF
)

# Append the actual insights
CLASS_PROMPT="${CLASS_PROMPT}

## Insights to classify
${NOTES_FOR_CLASS:-No insights available.}
"

log "Running classification (model: $CLASSIFICATION_MODEL)..."
CLASS_RAW=$(call_openrouter "$CLASS_PROMPT" 900 0.2 "Rumination Classification" "$CLASSIFICATION_MODEL" 2>/dev/null || echo "")
CLASS_TOKENS="$TOKENS_USED"

if [[ -n "$CLASS_RAW" ]]; then
  CLASS_JSON=$(extract_json "$CLASS_RAW" 2>/dev/null || echo "")
  if [[ -n "$CLASS_JSON" ]]; then
    # Filter to only ALLOWED_TOOLS
    CANDIDATE_ACTIONS=$(echo "$CLASS_JSON" | jq -c \
      --arg allowed "$ALLOWED_TOOLS" \
      '.actions // [] | map(select(.tool as $t | ($allowed | split(" ")) | any(. == $t)))' \
      2>/dev/null || echo "[]")
    ACTION_COUNT=$(echo "$CANDIDATE_ACTIONS" | jq 'length' 2>/dev/null || echo 0)
    log "Classification complete: $ACTION_COUNT candidate actions (tokens: $CLASS_TOKENS)"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "=== CLASSIFICATION RESULT ===" >&2
      echo "$CANDIDATE_ACTIONS" | jq '.' >&2
    fi
  else
    log "WARN: Classification returned unparseable JSON — continuing with no actions"
  fi
else
  log "WARN: Classification call failed — continuing with no actions"
fi

# Prune to MAX_ACTIONS
CANDIDATE_ACTIONS=$(echo "$CANDIDATE_ACTIONS" | jq -c \
  --argjson max "${MAX_ACTIONS:-5}" \
  'sort_by(-.importance) | .[0:$max]' 2>/dev/null || echo "[]")

# ─── Execute Lookups (with cycle-state dedup) ─────────────────────────────────
ACTION_RESULTS="[]"
LOOKUP_ENTRIES="[]"
BUDGET_START=$(date +%s)
BUDGET_REMAINING="${ACTION_BUDGET_SECONDS:-60}"

CANDIDATE_COUNT=$(echo "$CANDIDATE_ACTIONS" | jq 'length' 2>/dev/null || echo 0)
log "Executing $CANDIDATE_COUNT lookups (budget: ${BUDGET_REMAINING}s)"

for i in $(seq 0 $((CANDIDATE_COUNT - 1))); do
  # Check time budget
  BUDGET_NOW=$(date +%s)
  ELAPSED_BUDGET=$(( BUDGET_NOW - BUDGET_START ))
  BUDGET_REMAINING=$(( ACTION_BUDGET_SECONDS - ELAPSED_BUDGET ))
  if [[ $BUDGET_REMAINING -le 0 ]]; then
    log "Budget exhausted after $ELAPSED_BUDGET s — stopping lookups"
    break
  fi

  ACTION=$(echo "$CANDIDATE_ACTIONS" | jq -c ".[$i]" 2>/dev/null || continue)
  TOOL=$(echo "$ACTION" | jq -r '.tool // ""' 2>/dev/null)
  QUERY=$(echo "$ACTION" | jq -r '.query // ""' 2>/dev/null)
  REASON=$(echo "$ACTION" | jq -r '.reason // ""' 2>/dev/null)
  IMPORTANCE=$(echo "$ACTION" | jq -r '.importance // 0.5' 2>/dev/null)
  LOOKUP_KEY="${TOOL}:${QUERY}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would execute: $TOOL (query='$QUERY', reason='$REASON')" >&2
    continue
  fi

  # Check cycle-state for previous result
  PREV_ENTRY=$(echo "$CYCLE_STATE" | jq -c \
    --arg key "$LOOKUP_KEY" \
    --argjson ttl "$CYCLE_TTL_HOURS" \
    '.lookups[] | select(.tool + ":" + .query == $key) | select(
      (now - (.timestamp | if . == "" then 0 else (try (strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) catch 0) end)) < ($ttl * 3600)
    )' 2>/dev/null | head -1 || echo "")

  log "Lookup $((i+1))/$CANDIDATE_COUNT: $TOOL (query='${QUERY:0:50}')..."

  # Execute the tool (returns JSON: {"status":"ok","output":"..."} or {"status":"error",...})
  RESULT_JSON=$(run_tool "$TOOL" "$QUERY" "$BUDGET_REMAINING" 2>/dev/null || echo '{"status":"error","error":"run_tool_failed"}')
  RESULT_STATUS=$(echo "$RESULT_JSON" | jq -r '.status // "error"' 2>/dev/null || echo "error")
  RESULT_OUTPUT=$(echo "$RESULT_JSON" | jq -r '.output // ""' 2>/dev/null || echo "")
  RESULT_HASH=$(echo "$RESULT_OUTPUT" | head -c 500 | md5sum | cut -d' ' -f1)
  STATUS="new"

  if [[ -n "$PREV_ENTRY" ]]; then
    PREV_HASH=$(echo "$PREV_ENTRY" | jq -r '.result_hash // ""' 2>/dev/null)
    PREV_TS=$(echo "$PREV_ENTRY" | jq -r '.timestamp // ""' 2>/dev/null)
    if [[ "$RESULT_HASH" == "$PREV_HASH" ]]; then
      log "  → unchanged since $PREV_TS (hash match)"
      STATUS="unchanged"
    else
      log "  → CHANGED since $PREV_TS (hash differs)"
      STATUS="changed"
      IMPORTANCE=$(echo "$IMPORTANCE + 0.1" | bc 2>/dev/null || echo "$IMPORTANCE")
      # Cap at 1.0
      IMPORTANCE=$(echo "$IMPORTANCE" | awk '{if ($1 > 1.0) print 1.0; else print $1}')
    fi
  fi

  RESULT_SUMMARY=$(echo "$RESULT_OUTPUT" | head -c 100 | tr '\n' ' ')
  log "  → status=$STATUS tool_status=$RESULT_STATUS result='${RESULT_SUMMARY:0:80}...'"

  # Build action result entry (only if tool returned useful output)
  if [[ "$RESULT_STATUS" == "ok" && -n "$RESULT_OUTPUT" ]]; then
    RESULT_ENTRY=$(jq -cn \
      --arg tool "$TOOL" \
      --arg query "$QUERY" \
      --arg reason "$REASON" \
      --arg result "$RESULT_OUTPUT" \
      --arg status "$STATUS" \
      --argjson importance "$IMPORTANCE" \
      '{tool:$tool, query:$query, reason:$reason, result:$result, status:$status, importance:$importance}')
    ACTION_RESULTS=$(echo "$ACTION_RESULTS" | jq -c \
      --argjson entry "$RESULT_ENTRY" '. + [$entry]' 2>/dev/null || echo "$ACTION_RESULTS")
  fi

  # Build cycle-state lookup entry
  LOOKUP_ENTRY=$(jq -cn \
    --arg tool "$TOOL" \
    --arg query "$QUERY" \
    --arg hash "$RESULT_HASH" \
    --arg summary "$RESULT_SUMMARY" \
    --arg ts "$NOW" \
    --arg status "$STATUS" \
    '{tool:$tool, query:$query, result_hash:$hash, result_summary:$summary, timestamp:$ts, status:$status}')
  LOOKUP_ENTRIES=$(echo "$LOOKUP_ENTRIES" | jq -c \
    --argjson entry "$LOOKUP_ENTRY" '. + [$entry]' 2>/dev/null || echo "$LOOKUP_ENTRIES")
done

EXEC_COUNT=$(echo "$ACTION_RESULTS" | jq 'length' 2>/dev/null || echo 0)
log "Lookup execution complete: $EXEC_COUNT results collected"

# ─── Insight Enrichment ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" && "$EXEC_COUNT" -gt 0 ]]; then
  RESULTS_SUMMARY=$(echo "$ACTION_RESULTS" | jq -r \
    '.[] | "[\(.tool)] query=\(.query)\nResult: \(.result | .[0:400])\nStatus: \(.status)\n"' \
    2>/dev/null | head -60 || echo "")

  ENRICH_PROMPT=$(cat << 'ENRICH_EOF'
You are the enrichment layer of an AI assistant. You have rumination insights from an earlier thinking pass, plus fresh real-time data from lookups. Your task is to ENRICH the insights with the new data — not to rewrite them wholesale.

Rules:
1. Update insights where the lookup data directly confirms, refutes, or adds specificity.
2. Add NEW insights only if the lookup data reveals something genuinely important that wasn't in the original notes.
3. Keep the same JSON structure as the input: array of objects with thread, content, importance, expires, tags fields.
4. Do NOT increase total insight count by more than 3.
5. Importance scores should only increase if the lookup confirmed urgency or revealed a new risk.
6. If lookup results don't improve any insight, return the original notes unchanged.

Respond with ONLY valid JSON:
{"rumination_notes": [...enriched notes array...]}
ENRICH_EOF
)

  ENRICH_PROMPT="${ENRICH_PROMPT}

## Original rumination notes
$(echo "$RUMINATION_NOTES" | jq '.' 2>/dev/null)

## Real-time lookup results
${RESULTS_SUMMARY}
"

  log "Running enrichment (model: $ENRICHMENT_MODEL)..."
  ENRICH_RAW=$(call_openrouter "$ENRICH_PROMPT" 1200 0.2 "Rumination Enrichment" "$ENRICHMENT_MODEL" 2>/dev/null || echo "")
  ENRICH_TOKENS="$TOKENS_USED"

  if [[ -n "$ENRICH_RAW" ]]; then
    ENRICH_JSON=$(extract_json "$ENRICH_RAW" 2>/dev/null || echo "")
    if [[ -n "$ENRICH_JSON" ]]; then
      ENRICHED_NOTES=$(echo "$ENRICH_JSON" | jq -c '.rumination_notes // empty' 2>/dev/null || echo "")
      if [[ -n "$ENRICHED_NOTES" ]]; then
        RUMINATION_NOTES="$ENRICHED_NOTES"
        log "Enrichment applied (tokens: $ENRICH_TOKENS, notes updated)"
      else
        log "WARN: Enrichment JSON missing rumination_notes — keeping originals"
      fi
    else
      log "WARN: Enrichment returned unparseable JSON — keeping originals"
    fi
  else
    log "WARN: Enrichment call failed — keeping originals"
  fi
elif [[ "$DRY_RUN" == "true" && "$CANDIDATE_COUNT" -gt 0 ]]; then
  echo "[DRY RUN] Would run enrichment with $CANDIDATE_COUNT candidate lookups" >&2
else
  log "Enrichment skipped (no executed lookup results)"
fi

# ─── Update Cycle State ───────────────────────────────────────────────────────
if [[ "$DRY_RUN" != "true" ]]; then
  NEW_LOOKUP_COUNT=$(echo "$LOOKUP_ENTRIES" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$NEW_LOOKUP_COUNT" -gt 0 ]]; then
    # Merge: keep existing non-expired entries + new ones, dedup by tool:query (newest wins)
    MERGED_STATE=$(echo "$CYCLE_STATE" | jq -c \
      --argjson new_entries "$LOOKUP_ENTRIES" \
      --arg now "$NOW" \
      --argjson max_entries "$(echo "$CYCLE_STATE" | jq -r '.max_entries // 50')" \
      '
      (.lookups + $new_entries) |
      group_by(.tool + ":" + .query) |
      map(sort_by(.timestamp) | last) |
      sort_by(.timestamp) | reverse |
      .[0:$max_entries]
      ' 2>/dev/null || echo "[]")

    NEW_CYCLE_STATE=$(jq -cn \
      --argjson lookups "$MERGED_STATE" \
      --arg now "$NOW" \
      --argjson version "$(echo "$CYCLE_STATE" | jq '.version // 1')" \
      --argjson ttl "$(echo "$CYCLE_STATE" | jq '.ttl_hours // 4')" \
      --argjson max "$(echo "$CYCLE_STATE" | jq '.max_entries // 50')" \
      '{version:$version, last_updated:$now, lookups:$lookups, ttl_hours:$ttl, max_entries:$max}')

    TMP_CS=$(mktemp "${CYCLE_STATE_FILE}.tmp.XXXXXX")
    echo "$NEW_CYCLE_STATE" > "$TMP_CS"
    mv "$TMP_CS" "$CYCLE_STATE_FILE"
    log "Cycle state written: $(echo "$MERGED_STATE" | jq 'length' 2>/dev/null || echo 0) entries → $CYCLE_STATE_FILE"
  else
    log "Cycle state not updated (no new lookups executed)"
  fi
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

  # Trigger preconscious selection
  PRECONSCIOUS_SCRIPT="$SCRIPT_DIR/preconscious-select.sh"
  if [[ -f "$PRECONSCIOUS_SCRIPT" ]]; then
    timeout 90 bash "$PRECONSCIOUS_SCRIPT" >> "$LOG" 2>&1 || log "WARN: preconscious-select trigger failed"
  fi
fi

log "=== Rumination engine END ==="
exit 0
