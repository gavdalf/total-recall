#!/usr/bin/env bash
# preconscious-select.sh — AIE v2: Score and select top rumination insights for session injection
# Reads last 7 days of rumination JSONL, scores by importance × recency decay, writes buffer
# Usage: bash preconscious-select.sh [--dry-run]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$AIE_WORKSPACE/memory/rumination")"
OUTPUT="$(aie_get "paths.preconscious_buffer" "$AIE_WORKSPACE/memory/preconscious-buffer.md")"
LOG="$AIE_LOGS_DIR/rumination.log"
NOW_EPOCH=$(date -u +%s)
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [preconscious] $*" >> "$LOG"
}

log "=== Preconscious buffer START ==="

# Collect all rumination notes from last 7 days into a temp file
TMP_NOTES=$(mktemp /tmp/aie_notes.XXXXXX)
export TMP_NOTES
trap 'rm -f "$TMP_NOTES"' EXIT

for i in 0 1 2 3 4 5 6; do
  # Portable date: -d for Linux, -v for macOS
  if date -d "-${i} days" +%Y-%m-%d >/dev/null 2>&1; then
    DAY=$(date -d "-${i} days" +%Y-%m-%d)
  else
    DAY=$(date -v"-${i}d" +%Y-%m-%d 2>/dev/null || echo "")
  fi
  [[ -z "$DAY" ]] && continue
  FILE="$RUMINATION_DIR/${DAY}.jsonl"
  [[ -f "$FILE" ]] || continue
  # Extract each run's notes with the run timestamp attached
  jq -c --arg day "$DAY" '
    .timestamp as $ts |
    .rumination_notes[]? |
    . + {run_timestamp: $ts}
  ' "$FILE" >> "$TMP_NOTES" 2>/dev/null || true
done

NOTE_COUNT=$(wc -l < "$TMP_NOTES" 2>/dev/null || echo 0)
log "Collected $NOTE_COUNT notes from last 7 days"

if [[ "$NOTE_COUNT" -eq 0 ]]; then
  log "No rumination notes found. Writing empty buffer."
  echo "# Preconscious Buffer" > "$OUTPUT"
  echo "_No rumination data available yet._" >> "$OUTPUT"
  log "=== Preconscious buffer END ==="
  exit 0
fi

# Score and select using Python
BUFFER_CONTENT=$(TMP_NOTES="$TMP_NOTES" NOW_EPOCH="$NOW_EPOCH" python3 << 'PYEOF'
import json, math, sys, os
from datetime import datetime, timezone

now_epoch = int(os.environ['NOW_EPOCH'])
notes_file = os.environ['TMP_NOTES']

notes = []

with open(notes_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            note = json.loads(line)
        except:
            continue

        # Parse run timestamp for decay
        try:
            ts_str = note.get('run_timestamp', '1970-01-01T00:00:00Z')
            run_ts = datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
            hours_since = (now_epoch - run_ts.timestamp()) / 3600
        except:
            hours_since = 168  # 7 days default

        # Skip expired notes
        expires = note.get('expires')
        if expires and expires != 'null':
            try:
                exp_ts = datetime.fromisoformat(str(expires).replace('Z', '+00:00'))
                if exp_ts.timestamp() < now_epoch:
                    continue  # expired
                hours_until = (exp_ts.timestamp() - now_epoch) / 3600
                time_bonus = 0.2 if hours_until <= 4 else 0.0
            except:
                time_bonus = 0.0
        else:
            time_bonus = 0.0

        importance = float(note.get('importance', 0.5))

        # Skip debug/rescue entries
        tags = note.get('tags', [])
        if 'debug' in tags and importance <= 0.3:
            continue

        # Score: importance * exponential decay + urgency bonus
        decay = math.exp(-hours_since / 24)
        score = importance * decay + time_bonus

        note['_score'] = round(score, 4)
        note['_hours_since'] = round(hours_since, 1)
        notes.append(note)

# Sort by score descending
notes.sort(key=lambda x: x['_score'], reverse=True)

# Select top 5, deduplicate by thread+primary_tag combo
selected = []
seen_keys = set()
for note in notes:
    thread = note.get('thread', 'unknown')
    tags = note.get('tags', ['general'])
    primary_tag = tags[0] if tags else 'general'
    dedup_key = f"{thread}:{primary_tag}"

    # Allow up to 2 per tag but only 1 per exact thread+tag combo
    tag_count = sum(1 for s in selected if s.get('tags', [''])[0] == primary_tag)
    if dedup_key not in seen_keys and tag_count < 2 and len(selected) < 5:
        selected.append(note)
        seen_keys.add(dedup_key)

# Format output
now_str = datetime.fromtimestamp(now_epoch, tz=timezone.utc).strftime('%Y-%m-%d %H:%M UTC')
lines = [
    '# Preconscious Buffer',
    f'_Updated: {now_str}_',
    '',
    'What Max has on his mind right now:',
    ''
]

thread_icons = {
    'observation': '👁️',
    'reasoning': '🧠',
    'memory': '📝',
    'planning': '📋'
}

for note in selected:
    thread = note.get('thread', 'unknown')
    icon = thread_icons.get(thread, '💭')
    content = note.get('content', '')
    score = note['_score']
    tags = note.get('tags', [])
    tag_str = ', '.join(tags)
    hours = note['_hours_since']

    # Truncate very long notes to ~200 chars for the buffer
    if len(content) > 250:
        content = content[:247] + '...'

    lines.append(f'{icon} **[{tag_str}]** {content}')
    lines.append(f'  _score: {score:.2f} | {hours:.0f}h ago_')
    lines.append('')

print('\n'.join(lines))
PYEOF
)

PARSE_EXIT=$?

if [[ $PARSE_EXIT -ne 0 || -z "$BUFFER_CONTENT" ]]; then
  log "ERROR: Python scoring failed (exit $PARSE_EXIT)"
  echo "# Preconscious Buffer" > "$OUTPUT"
  echo "_Scoring error — fallback mode._" >> "$OUTPUT"
  log "=== Preconscious buffer END (error) ==="
  exit 1
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "═══════════════════════════════════════"
  echo "  DRY RUN — Preconscious Buffer"
  echo "═══════════════════════════════════════"
  echo ""
  echo "$BUFFER_CONTENT"
  echo ""
  WORD_COUNT=$(echo "$BUFFER_CONTENT" | wc -w)
  echo "Word count: $WORD_COUNT (target: <500)"
  echo "═══════════════════════════════════════"
else
  echo "$BUFFER_CONTENT" > "$OUTPUT"
  WORD_COUNT=$(echo "$BUFFER_CONTENT" | wc -w)
  log "Buffer written to $OUTPUT ($WORD_COUNT words)"
fi

log "=== Preconscious buffer END ==="
