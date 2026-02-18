#!/usr/bin/env bash
# Observer Agent — compresses recent session messages into observations
# Part of Total Recall skill
# Uses Gemini Flash via OpenRouter for cheap, fast compression

set -euo pipefail

# --- Configuration (all overridable via env) ---
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.openclaw/agents/main/sessions}"
OBSERVER_MODEL="${OBSERVER_MODEL:-google/gemini-2.5-flash}"
OBSERVER_FALLBACK_MODEL="${OBSERVER_FALLBACK_MODEL:-google/gemini-2.0-flash-001}"
OBSERVER_LOOKBACK_MIN="${OBSERVER_LOOKBACK_MIN:-15}"
OBSERVER_MORNING_LOOKBACK_MIN="${OBSERVER_MORNING_LOOKBACK_MIN:-480}"
REFLECTOR_WORD_THRESHOLD="${REFLECTOR_WORD_THRESHOLD:-8000}"

OBSERVATIONS_FILE="$MEMORY_DIR/observations.md"
OBSERVER_PROMPT="$SKILL_DIR/prompts/observer-system.txt"
OBSERVER_LOG="$WORKSPACE/logs/observer.log"
MARKER_FILE="$MEMORY_DIR/.observer-last-run"
HASH_FILE="$MEMORY_DIR/.observer-last-hash"
LOCK_FILE="/tmp/total-recall-reflector-$(id -u).lock"

# Source env if available (grep-guard: only export KEY=VALUE lines)
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$WORKSPACE/.env" | grep -v '^#' > /tmp/.total-recall-env-$$ 2>/dev/null || true
  source /tmp/.total-recall-env-$$ 2>/dev/null || true
  rm -f /tmp/.total-recall-env-$$
  set +a
fi

mkdir -p "$WORKSPACE/logs" "$MEMORY_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$OBSERVER_LOG"
}

log "Observer agent starting"

# --- Validate prompt file exists ---
if [ ! -f "$OBSERVER_PROMPT" ]; then
  log "ERROR: Observer prompt not found at $OBSERVER_PROMPT"
  echo "ERROR_NO_PROMPT"
  exit 1
fi

# --- Lock check (prevent collision with reflector OR another observer) ---
OBSERVER_LOCK="/tmp/total-recall-observer-$(id -u).lock"
if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(file_mtime "$LOCK_FILE") ))
  if [ "$LOCK_AGE" -lt 300 ]; then
    log "Lock file exists (${LOCK_AGE}s old) — reflector running, skipping"
    echo "SKIPPED_LOCKED"
    exit 0
  else
    log "Stale lock file (${LOCK_AGE}s), removing"
    rm -f "$LOCK_FILE"
  fi
fi
if [ -f "$OBSERVER_LOCK" ]; then
  OBS_LOCK_AGE=$(( $(date +%s) - $(file_mtime "$OBSERVER_LOCK") ))
  if [ "$OBS_LOCK_AGE" -lt 120 ]; then
    log "Another observer is running (${OBS_LOCK_AGE}s old) — skipping"
    echo "SKIPPED_OBSERVER_RUNNING"
    exit 0
  fi
  rm -f "$OBSERVER_LOCK"
fi
echo $$ > "$OBSERVER_LOCK"
TMPMSGS=""
trap 'rm -f "$OBSERVER_LOCK" "$TMPMSGS" 2>/dev/null' EXIT

# --- Determine lookback window ---
FLUSH_MODE=false
RECOVER_MODE=false
RECOVER_FILE=""

if [ "${1:-}" = "--recover" ] && [ -n "${2:-}" ]; then
  RECOVER_MODE=true
  RECOVER_FILE="$2"
  LOOKBACK_MIN=240
  FIND_MIN=250
  log "RECOVERY MODE: capturing missed session $RECOVER_FILE"
elif [ "${1:-}" = "--flush" ]; then
  FLUSH_MODE=true
  LOOKBACK_MIN=120
  FIND_MIN=125
  log "FLUSH MODE: pre-compaction emergency capture (2hr lookback)"
else
  HOUR=$(date +%H)
  if [ "$HOUR" -le 7 ]; then
    LOOKBACK_MIN="$OBSERVER_MORNING_LOOKBACK_MIN"
    FIND_MIN=$(( OBSERVER_MORNING_LOOKBACK_MIN + 10 ))
    log "Morning mode: ${LOOKBACK_MIN}-minute lookback"
  else
    LOOKBACK_MIN="$OBSERVER_LOOKBACK_MIN"
    FIND_MIN=$(( OBSERVER_LOOKBACK_MIN + 5 ))
  fi
fi

# --- Find recently modified transcripts (skip subagent/cron/topic sessions) ---
if [ "$RECOVER_MODE" = true ] && [ -f "$RECOVER_FILE" ]; then
  TRANSCRIPTS="$RECOVER_FILE"
  log "Recovery mode: using $RECOVER_FILE"
else
  TRANSCRIPTS=""
  while IFS= read -r f; do
    BASENAME=$(basename "$f" .jsonl)
    if echo "$BASENAME" | grep -qE "(topic|subagent|cron)"; then
      continue
    fi
    TRANSCRIPTS+="$f"$'\n'
  done < <(find "$SESSIONS_DIR" -name "*.jsonl" -mmin "-${FIND_MIN}" -type f 2>/dev/null | head -10)
  TRANSCRIPTS=$(echo "$TRANSCRIPTS" | grep -v "^$" || true)
fi

if [ -z "${TRANSCRIPTS:-}" ]; then
  log "No recently modified transcripts, exiting"
  echo "NO_OBSERVATIONS"
  exit 0
fi

TRANSCRIPT_COUNT=$(echo "$TRANSCRIPTS" | wc -l)
log "Found $TRANSCRIPT_COUNT active transcripts"

# --- Calculate cutoff (portable) ---
CUTOFF_ISO=$(date_minutes_ago "$LOOKBACK_MIN")

# --- Extract recent meaningful messages ---
TMPMSGS=$(mktemp)

echo "$TRANSCRIPTS" | while IFS= read -r transcript; do
  [ -z "$transcript" ] && continue
  tail -150 "$transcript" 2>/dev/null | jq -r --arg cutoff "$CUTOFF_ISO" '
    select(.timestamp != null and (.timestamp > $cutoff)) |
    select(.message.role == "user" or .message.role == "assistant") |
    .message as $m |
    (if $m.role == "user" then "USER" else "ASSISTANT" end) as $who |
    (
      if ($m.content | type) == "array" then
        [$m.content[] | select(.type == "text") | .text] | join(" ")
      elif ($m.content | type) == "string" then
        $m.content
      else
        ""
      end
    ) as $text |
    select($text != "" and ($text | length) > 5) |
    select($text != "HEARTBEAT_OK" and $text != "NO_REPLY" and $text != "ANNOUNCE_SKIP") |
    select(($text | test("Observer agent|REFLECTION_|NO_OBSERVATIONS|OBSERVATIONS_ADDED|observer-agent|reflector-agent"; "i")) | not) |
    (.timestamp | split("T")[1] | split(".")[0] | split(":")[0:2] | join(":")) as $time |
    "[\($time)] \($who): \($text[0:500])"
  ' 2>/dev/null >> "$TMPMSGS" || true
done

RECENT_MESSAGES=$(cat "$TMPMSGS" | grep -v "^$" | head -150 || true)

LINE_COUNT=$(echo "$RECENT_MESSAGES" | grep -c "." || true)
if [ "$LINE_COUNT" -lt 2 ]; then
  log "Only $LINE_COUNT meaningful lines — skipping"
  date +%s > "$MARKER_FILE"
  echo "NO_OBSERVATIONS"
  exit 0
fi

# --- Dedup check (hash comparison) — skip in flush mode ---
CURRENT_HASH=$(echo "$RECENT_MESSAGES" | md5_hash)
if [ "$FLUSH_MODE" = false ] && [ -f "$HASH_FILE" ]; then
  LAST_HASH=$(cat "$HASH_FILE")
  if [ "$CURRENT_HASH" = "$LAST_HASH" ]; then
    log "Messages unchanged since last run (hash match) — skipping"
    date +%s > "$MARKER_FILE"
    echo "NO_OBSERVATIONS"
    exit 0
  fi
fi

log "Found $LINE_COUNT lines to compress (hash: ${CURRENT_HASH:0:8})"

# --- Validate API key ---
if [ -z "${OPENROUTER_API_KEY:-}" ]; then
  log "ERROR: OPENROUTER_API_KEY not set"
  echo "ERROR_NO_API_KEY"
  exit 1
fi

# --- Call LLM ---
SYSTEM_PROMPT=$(cat "$OBSERVER_PROMPT")
TODAY=$(date '+%Y-%m-%d')

PAYLOAD=$(jq -n \
  --arg system "$SYSTEM_PROMPT" \
  --arg messages "Today is $TODAY. Compress these recent messages into observations:\n\n$RECENT_MESSAGES" \
  '{
    model: "placeholder",
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $messages}
    ],
    max_tokens: 2000,
    temperature: 0.3
  }')

MODELS=("$OBSERVER_MODEL" "$OBSERVER_FALLBACK_MODEL")
OBSERVATION=""
for ATTEMPT in 1 2; do
  MODEL="${MODELS[$((ATTEMPT-1))]}"
  ATTEMPT_PAYLOAD=$(echo "$PAYLOAD" | jq --arg m "$MODEL" '.model = $m')
  
  RESPONSE=$(curl -s --max-time 60 "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$ATTEMPT_PAYLOAD" 2>/dev/null)

  OBSERVATION=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)

  if [ -n "$OBSERVATION" ]; then
    log "Success with model $MODEL on attempt $ATTEMPT"
    break
  fi

  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
  log "API attempt $ATTEMPT ($MODEL) failed: ${ERROR:-unknown error}"

  [ "$ATTEMPT" -lt 2 ] && sleep 3
done

if [ -z "$OBSERVATION" ] || echo "$OBSERVATION" | grep -qi "NO_OBSERVATIONS"; then
  log "No notable observations after LLM call"
  date +%s > "$MARKER_FILE"
  echo "NO_OBSERVATIONS"
  exit 0
fi

# --- Append to observations file ---
if [ ! -f "$OBSERVATIONS_FILE" ]; then
  cat > "$OBSERVATIONS_FILE" << 'EOF'
# Observations Log

Auto-generated by Observer agent. Loaded at session startup for cross-session memory.

---

EOF
fi

if grep -q "^Date: $TODAY" "$OBSERVATIONS_FILE"; then
  echo "" >> "$OBSERVATIONS_FILE"
  echo "$OBSERVATION" | sed "/^Date: $TODAY$/d" >> "$OBSERVATIONS_FILE"
else
  echo "" >> "$OBSERVATIONS_FILE"
  echo "$OBSERVATION" >> "$OBSERVATIONS_FILE"
fi

# Write hash AFTER successful append (blocker #6 fix — prevents data loss)
echo "$CURRENT_HASH" > "$HASH_FILE"
date +%s > "$MARKER_FILE"
touch /tmp/observer-watcher-lastrun 2>/dev/null || true

OBS_WORDS=$(wc -w < "$OBSERVATIONS_FILE")
log "Observations appended. Total: $OBS_WORDS words (~$((OBS_WORDS * 4 / 3)) tokens)"

# --- Trigger reflector if needed ---
if [ "$OBS_WORDS" -gt "$REFLECTOR_WORD_THRESHOLD" ]; then
  log "Reflection recommended ($OBS_WORDS words)"
  echo $$ > "$LOCK_FILE"
  if bash "$SKILL_DIR/scripts/reflector-agent.sh" 2>/dev/null; then
    echo "REFLECTION_COMPLETE"
  else
    log "Reflector failed, observations kept as-is"
    echo "OBSERVATIONS_ADDED"
  fi
  rm -f "$LOCK_FILE"
else
  echo "OBSERVATIONS_ADDED"
fi
