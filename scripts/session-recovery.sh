#!/usr/bin/env bash
# Session Recovery — catches missed sessions on /new or /reset
# Part of Total Recall skill

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"
SESSIONS_DIR="${SESSIONS_DIR:-$HOME/.openclaw/agents/main/sessions}"
HASH_FILE="$MEMORY_DIR/.observer-last-hash"
RECOVERY_LOG="$WORKSPACE/logs/session-recovery.log"

mkdir -p "$WORKSPACE/logs"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$RECOVERY_LOG"
}

log "Session recovery check starting"

# Find most recent session file (filter out subagent/cron/topic)
LAST_SESSION=""
for f in $(find "$SESSIONS_DIR" -maxdepth 1 -name "*.jsonl" -type f 2>/dev/null | sort -r); do
  BASENAME=$(basename "$f" .jsonl)
  if echo "$BASENAME" | grep -qE "(topic|subagent|cron)"; then
    continue
  fi
  LAST_SESSION="$f"
  break
done

if [ -z "$LAST_SESSION" ]; then
  log "No main session files found"
  exit 0
fi

CURRENT_HASH=$(tail -50 "$LAST_SESSION" 2>/dev/null | md5_hash || echo "")

if [ -z "$CURRENT_HASH" ]; then
  log "Could not hash session file"
  exit 0
fi

if [ -f "$HASH_FILE" ]; then
  STORED_HASH=$(cat "$HASH_FILE" 2>/dev/null || echo "")
  if [ "$CURRENT_HASH" = "$STORED_HASH" ]; then
    log "Last session already observed (hash match)"
    exit 0
  fi
fi

log "Unobserved session detected: $(basename "$LAST_SESSION") (hash: ${CURRENT_HASH:0:8})"
log "Triggering emergency observer capture..."

bash "$SKILL_DIR/scripts/observer-agent.sh" --recover "$LAST_SESSION" 2>/dev/null || {
  log "Observer recovery failed, attempting direct capture..."
  CUTOFF_ISO=$(date_minutes_ago 240)
  
  OBSERVATIONS_FILE="$MEMORY_DIR/observations.md"
  RECENT_MESSAGES=$(jq -r --arg cutoff "$CUTOFF_ISO" '
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
    select($text != "HEARTBEAT_OK" and $text != "NO_REPLY") |
    "\($who): \($text[0:400])"
  ' "$LAST_SESSION" 2>/dev/null | head -100 || true)
  
  if [ -n "$RECENT_MESSAGES" ]; then
    echo "" >> "$OBSERVATIONS_FILE"
    echo "<!-- Session Recovery Capture: $(date '+%Y-%m-%d %H:%M') -->" >> "$OBSERVATIONS_FILE"
    echo "$RECENT_MESSAGES" >> "$OBSERVATIONS_FILE"
    echo "$CURRENT_HASH" > "$HASH_FILE"
    log "Emergency capture complete ($(echo "$RECENT_MESSAGES" | wc -l) lines)"
  fi
}

log "Session recovery complete"
