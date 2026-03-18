#!/usr/bin/env bash
# Reflector Agent — consolidates observations.md when it gets too large
# Part of Total Recall skill

set -euo pipefail

# --- Configuration ---
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"

# LLM provider configuration (OpenAI-compatible APIs)
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"
LLM_MODEL="${LLM_MODEL:-google/gemini-2.5-flash}"

REFLECTOR_MODEL="${REFLECTOR_MODEL:-${OBSERVER_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}}"
REFLECTOR_FALLBACK_MODEL="${REFLECTOR_FALLBACK_MODEL:-openrouter/hunter-alpha}"
REFLECTOR_WORD_THRESHOLD="${REFLECTOR_WORD_THRESHOLD:-8000}"

OBSERVATIONS_FILE="$MEMORY_DIR/observations.md"
REFLECTOR_PROMPT="$SKILL_DIR/prompts/reflector-system.txt"
REFLECTOR_LOG="$WORKSPACE/logs/reflector.log"
BACKUP_DIR="$MEMORY_DIR/observation-backups"
LOCK_FILE="$WORKSPACE/logs/reflector.lock"

# Safe env loading
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  # Load provider config + backward compatible OPENROUTER key
  eval "$(grep -E '^(LLM_BASE_URL|LLM_API_KEY|LLM_MODEL|OPENROUTER_API_KEY|OBSERVER_MODEL|REFLECTOR_MODEL|REFLECTOR_FALLBACK_MODEL)=' "$WORKSPACE/.env" 2>/dev/null)" || true
  set +a
fi

# Re-apply defaults after env load
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_API_KEY="${LLM_API_KEY:-${OPENROUTER_API_KEY:-}}"
LLM_MODEL="${LLM_MODEL:-google/gemini-2.5-flash}"
REFLECTOR_MODEL="${REFLECTOR_MODEL:-${OBSERVER_MODEL:-nvidia/nemotron-3-super-120b-a12b:free}}"
REFLECTOR_FALLBACK_MODEL="${REFLECTOR_FALLBACK_MODEL:-openrouter/hunter-alpha}"

mkdir -p "$WORKSPACE/logs" "$BACKUP_DIR"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$REFLECTOR_LOG"
}

log "Reflector agent starting"

# --- Lock check (prevent concurrent reflector runs) ---
if [ -f "$LOCK_FILE" ]; then
  LOCK_AGE=$(( $(date +%s) - $(file_mtime "$LOCK_FILE") ))
  if [ "$LOCK_AGE" -lt 300 ]; then
    log "Lock file exists (${LOCK_AGE}s old) — another reflector/observer running, skipping"
    exit 0
  else
    log "Stale lock file (${LOCK_AGE}s), removing"
    rm -f "$LOCK_FILE"
  fi
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT

if [ ! -f "$OBSERVATIONS_FILE" ]; then
  log "No observations file found, exiting"
  exit 0
fi

if [ ! -f "$REFLECTOR_PROMPT" ]; then
  log "ERROR: Reflector prompt not found at $REFLECTOR_PROMPT"
  exit 1
fi

OBS_WORDS=$(wc -w < "$OBSERVATIONS_FILE")
log "Current observations: $OBS_WORDS words"

if [ "$OBS_WORDS" -lt "$REFLECTOR_WORD_THRESHOLD" ]; then
  log "Under threshold ($OBS_WORDS < $REFLECTOR_WORD_THRESHOLD words), skipping"
  exit 0
fi

if [ -z "${LLM_API_KEY:-}" ]; then
  log "ERROR: LLM_API_KEY not set (or OPENROUTER_API_KEY for backward compatibility)"
  exit 1
fi

# Backup current observations
BACKUP_FILE="$BACKUP_DIR/observations-$(date '+%Y%m%d-%H%M%S').md"
cp "$OBSERVATIONS_FILE" "$BACKUP_FILE"
log "Backed up to $BACKUP_FILE"

CURRENT_OBS=$(cat "$OBSERVATIONS_FILE")
SYSTEM_PROMPT=$(cat "$REFLECTOR_PROMPT")
TODAY=$(date '+%Y-%m-%d')

PAYLOAD=$(jq -n \
  --arg system "$SYSTEM_PROMPT" \
  --arg obs "Today is $TODAY. Here is the current observation log to consolidate:\n\n$CURRENT_OBS" \
  --arg model "$REFLECTOR_MODEL" \
  '{
    model: $model,
    messages: [
      {role: "system", content: $system},
      {role: "user", content: $obs}
    ],
    max_tokens: 4000,
    temperature: 0.2
  }')

REFLECTED=""
MODELS=("$REFLECTOR_MODEL" "$REFLECTOR_FALLBACK_MODEL")
for ATTEMPT in 1 2; do
  MODEL="${MODELS[$((ATTEMPT-1))]}"
  
  # Update payload with current model
  PAYLOAD=$(jq -n --arg model "$MODEL" --arg prompt "$PROMPT" '{
    model: $model,
    messages: [
      {
        role: "system",
        content: $prompt
      }
    ],
    temperature: 0.2
  }')

  RESPONSE=$(curl -s --max-time 120 "$LLM_BASE_URL/chat/completions" \
    -H "Authorization: Bearer $LLM_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)

  CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  REASONING=$(echo "$RESPONSE" | jq -r '.choices[0].message.reasoning // empty' 2>/dev/null)
  
  # Use content if not empty, otherwise fall back to reasoning
  if [ -n "$CONTENT" ] && [ "$CONTENT" != "null" ] && [ "$CONTENT" != "" ]; then
    REFLECTED="$CONTENT"
  elif [ -n "$REASONING" ] && [ "$REASONING" != "null" ] && [ "$REASONING" != "" ]; then
    REFLECTED="$REASONING"
  else
    REFLECTED=""
  fi
  
  [ -n "$REFLECTED" ] && break

  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // empty' 2>/dev/null)
  log "API attempt $ATTEMPT failed with model $MODEL: ${ERROR:-unknown error}"
  [ "$ATTEMPT" -lt 2 ] && sleep 5
done

if [ -z "$REFLECTED" ]; then
  log "ERROR: Reflector returned empty response after retries"
  exit 1
fi

REFLECTED_WORDS=$(echo "$REFLECTED" | wc -w)
if [ "$REFLECTED_WORDS" -gt "$OBS_WORDS" ]; then
  log "WARNING: Reflection ($REFLECTED_WORDS words) is LARGER than input ($OBS_WORDS words) — keeping original"
  exit 1
fi

# Atomic write: write to temp then move
TMPOUT=$(mktemp "$MEMORY_DIR/.reflector-out-XXXXXX")
cat > "$TMPOUT" << EOF
# Observations Log

Auto-generated by Observer agent. Consolidated by Reflector.
Last reflection: $TODAY

---

$REFLECTED
EOF

mv "$TMPOUT" "$OBSERVATIONS_FILE"

NEW_WORDS=$(wc -w < "$OBSERVATIONS_FILE")
REDUCTION=$(( (OBS_WORDS - NEW_WORDS) * 100 / OBS_WORDS ))
log "Reflection complete. $OBS_WORDS → $NEW_WORDS words ($REDUCTION% reduction)"

# Clean old backups (keep last 10) — null-safe
find "$BACKUP_DIR" -name "observations-*.md" -type f | sort -r | tail -n +11 | while IFS= read -r old; do
  rm -f "$old"
done

echo "REFLECTION_COMPLETE"
