#!/usr/bin/env bash
# Backfill importance tags on existing observations
# One-shot script — run once to tag all untagged observations with dc:type/importance/date
# Uses Opus for maximum accuracy

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${WORKSPACE}/memory"
OBSERVATIONS_FILE="${MEMORY_DIR}/observations.md"
BACKUP_FILE="${OBSERVATIONS_FILE}.pre-backfill.bak"

# Source env
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  eval "$(grep -E '^(ANTHROPIC_API_KEY)=' "$WORKSPACE/.env" 2>/dev/null)" || true
  set +a
fi

MODEL="${BACKFILL_MODEL:-claude-opus-4-20250918}"
API_KEY="${ANTHROPIC_API_KEY:-}"

if [ -z "$API_KEY" ]; then
  echo "ERROR: ANTHROPIC_API_KEY not set"
  exit 1
fi

if [ ! -f "$OBSERVATIONS_FILE" ]; then
  echo "ERROR: Observations file not found at $OBSERVATIONS_FILE"
  exit 1
fi

# Backup first
cp "$OBSERVATIONS_FILE" "$BACKUP_FILE"
echo "Backup saved to $BACKUP_FILE"

CONTENT=$(cat "$OBSERVATIONS_FILE")
WORD_COUNT=$(wc -w <<< "$CONTENT")
echo "Processing $WORD_COUNT words (~$(( WORD_COUNT * 4 / 3 )) tokens)"

SYSTEM_PROMPT='You are a metadata tagger for an AI memory system. Your job is to add importance metadata tags to every observation line in the file.

## Task
Add a `<!-- dc:type=X dc:importance=Y dc:date=Z -->` tag to the END of every line that contains substantive information. This includes:
- Bullet points (lines starting with -)
- Section content lines under headers
- Any line with meaningful information

Do NOT tag:
- Headers (lines starting with # or ##)
- Separator lines (---)
- Empty lines
- Lines that ALREADY have a `<!-- dc:` tag

## Tag Format
`<!-- dc:type=TYPE dc:importance=SCORE dc:date=DATE -->`

### Types (choose the most specific):
- **decision** — A choice was made, direction set, something approved/rejected
- **preference** — User likes/dislikes, style choices, ways of working
- **rule** — Explicit rules, policies, hard constraints (never decays)
- **goal** — Targets, milestones, aspirations, deadlines (never decays)
- **habit** — Recurring patterns, routines (never decays)
- **fact** — Names, numbers, file paths, technical details, URLs
- **event** — Something that happened — completed tasks, meetings, errors
- **context** — Background info, options discussed, non-actionable understanding

### Importance (0.0 to 10.0):
- **9-10:** Life-changing decisions, financial commitments, health emergencies
- **7-8:** Project milestones, deadlines, user preferences, significant bugs, career decisions
- **5-6:** Technical decisions, completed tasks, meaningful context
- **3-4:** Routine completions, minor technical details, general context
- **1-2:** Cron job runs, routine confirmations, noise
- User decisions > assistant actions
- Financial info: 7+
- Family-related: 6+
- Architecture/system design decisions: 7+
- Routine cron completions: 1-2

### Date
- Use the date the observation REFERS TO, not today
- For consolidated sections without explicit dates, use the "Last reflection" date from the file header
- For dated sections (Date: YYYY-MM-DD), use that date

## CRITICAL RULES
- Output the ENTIRE file with tags added — do not remove or change any existing content
- Preserve ALL formatting, indentation, headers, separators exactly as-is
- Only ADD the `<!-- dc:... -->` tags at the end of content lines
- If a line already has a dc: tag, leave it unchanged
- Do not wrap output in markdown code blocks'

PAYLOAD=$(jq -n \
  --arg system "$SYSTEM_PROMPT" \
  --arg content "$CONTENT" \
  '{
    model: "claude-opus-4-20250918",
    max_tokens: 8192,
    messages: [
      {role: "user", content: ("Here is the observations file to tag. Output the complete file with metadata tags added:\n\n" + $content)}
    ],
    system: $system,
    temperature: 0.1
  }')

echo "Calling Opus..."
RESPONSE=$(curl -s --max-time 120 "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

TAGGED=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null)

if [ -z "$TAGGED" ]; then
  ERROR=$(echo "$RESPONSE" | jq -r '.error.message // .error.type // "unknown"' 2>/dev/null)
  echo "ERROR: API call failed: $ERROR"
  echo "Backup preserved at $BACKUP_FILE"
  exit 1
fi

# Validate: tagged output should have dc: tags
TAG_COUNT=$(echo "$TAGGED" | grep -c 'dc:type=' || true)
if [ "$TAG_COUNT" -lt 5 ]; then
  echo "ERROR: Only $TAG_COUNT tags found — expected many more. Output may be malformed."
  echo "Saving raw output to ${OBSERVATIONS_FILE}.backfill-attempt for inspection"
  echo "$TAGGED" > "${OBSERVATIONS_FILE}.backfill-attempt"
  echo "Backup preserved at $BACKUP_FILE"
  exit 1
fi

# Validate: output should be roughly similar length (not truncated)
ORIGINAL_LINES=$(wc -l <<< "$CONTENT")
TAGGED_LINES=$(echo "$TAGGED" | wc -l)
if [ "$TAGGED_LINES" -lt $(( ORIGINAL_LINES / 2 )) ]; then
  echo "ERROR: Tagged output ($TAGGED_LINES lines) is much shorter than original ($ORIGINAL_LINES lines) — possible truncation"
  echo "Saving raw output to ${OBSERVATIONS_FILE}.backfill-attempt for inspection"
  echo "$TAGGED" > "${OBSERVATIONS_FILE}.backfill-attempt"
  echo "Backup preserved at $BACKUP_FILE"
  exit 1
fi

# Write tagged output
echo "$TAGGED" > "$OBSERVATIONS_FILE"

echo "SUCCESS: $TAG_COUNT tags added across $TAGGED_LINES lines"
echo "Backup at: $BACKUP_FILE"
echo "Review with: diff $BACKUP_FILE $OBSERVATIONS_FILE"
