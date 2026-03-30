#!/usr/bin/env bash
# Memory Integrity Verification — semantic drift detection
# Implements the design approved in issue #18:
# https://github.com/gavdalf/total-recall/issues/18
#
# Usage:
#   integrity-check.sh reflector [--dry-run]
#   integrity-check.sh dream     [--dry-run]
#
# Samples observations before a compression boundary, embeds both pre- and
# post-versions with Gemini Embedding 2, and flags any pair whose cosine
# similarity falls below the configured threshold.
#
# Flags are written to:
#   - memory/integrity-log.md   (machine-parseable + human-readable)
#   - The dream log entry       (inline, visible during normal review)
#
# Exit codes:
#   0  Check passed (or flag-only mode — flags written but no hard fail)
#   1  Fatal error (missing files, API failure with no fallback)
#
# Environment / config keys (all optional — see integrity.yaml):
#   INTEGRITY_ENABLED              true|false (default: true)
#   INTEGRITY_SAMPLE_N             observations to sample (default: 10)
#   INTEGRITY_THRESHOLD            global cosine floor (default: 0.85)
#   INTEGRITY_REFLECTOR_THRESHOLD  per-type override for reflector boundary
#   INTEGRITY_DREAM_THRESHOLD      per-type override for dream boundary
#   INTEGRITY_BLOCK_ON_FLAG        true|false — block pipeline on flag (default: false)
#   GEMINI_API_KEY                 required; also accepts GOOGLE_API_KEY

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SKILL_DIR/scripts/_compat.sh"

WORKSPACE="${OPENCLAW_WORKSPACE:-$(cd "$SKILL_DIR/../.." && pwd)}"
MEMORY_DIR="${MEMORY_DIR:-$WORKSPACE/memory}"
LOGS_DIR="${LOGS_DIR:-$WORKSPACE/logs}"

INTEGRITY_LOG="$MEMORY_DIR/integrity-log.md"
DREAM_LOG_DIR="$MEMORY_DIR/dream-logs"
INTEGRITY_CFG="$SKILL_DIR/config/integrity.yaml"

# Load env
if [ -f "$WORKSPACE/.env" ]; then
  set -a
  eval "$(grep -E '^(INTEGRITY_|GEMINI_API_KEY|GOOGLE_API_KEY|LLM_API_KEY)' "$WORKSPACE/.env" 2>/dev/null)" || true
  set +a
fi

# Config defaults (can be overridden by integrity.yaml or env)
INTEGRITY_ENABLED="${INTEGRITY_ENABLED:-true}"
SAMPLE_N="${INTEGRITY_SAMPLE_N:-10}"
GLOBAL_THRESHOLD="${INTEGRITY_THRESHOLD:-0.85}"
REFLECTOR_THRESHOLD="${INTEGRITY_REFLECTOR_THRESHOLD:-$GLOBAL_THRESHOLD}"
DREAM_THRESHOLD="${INTEGRITY_DREAM_THRESHOLD:-$GLOBAL_THRESHOLD}"
BLOCK_ON_FLAG="${INTEGRITY_BLOCK_ON_FLAG:-false}"

# Gemini Embedding 2 endpoint
GEMINI_EMBED_MODEL="text-embedding-004"
GEMINI_API_KEY="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}"

CHECKPOINT="${1:-}"  # "reflector" or "dream"
DRY_RUN="false"
# Consume optional --dry-run flag (may appear as $2 before or alongside subcommand)
shift || true  # shift past CHECKPOINT

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [integrity] $*" >> "$LOGS_DIR/integrity.log" 2>/dev/null || true; }
info() { echo "$*"; }
err()  { echo "ERROR [integrity]: $*" >&2; }

# Load per-type thresholds from integrity.yaml if present
_load_yaml_threshold() {
  local key="$1"
  local default="$2"
  if [ -f "$INTEGRITY_CFG" ] && command -v python3 &>/dev/null; then
    python3 -c "
import yaml, sys
try:
    with open('$INTEGRITY_CFG') as f:
        d = yaml.safe_load(f)
    # Read from nested integrity.thresholds, not document root
    thresholds = (d or {}).get('integrity', {}).get('thresholds', {})
    val = thresholds.get('$key', $default)
    print(val)
except Exception:
    print($default)
" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

# Embed a text string using Gemini Embedding 2. Returns JSON with .embedding array.
_embed() {
  local text="$1"
  local task_type="${2:-SEMANTIC_SIMILARITY}"

  if [ -z "$GEMINI_API_KEY" ]; then
    err "GEMINI_API_KEY not set — cannot embed"
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg text "$text" \
    --arg task "$task_type" \
    '{"model": "models/text-embedding-004", "content": {"parts": [{"text": $text}]}, "taskType": $task}')

  local response
  response=$(curl -s --max-time 30 \
    "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_EMBED_MODEL}:embedContent?key=${GEMINI_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>/dev/null) || { err "Embedding API call failed"; return 1; }

  # Check for error in response
  local api_err
  api_err=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [ -n "$api_err" ]; then
    err "Embedding API error: $api_err"
    return 1
  fi

  echo "$response" | jq -c '.embedding.values // empty'
}

# Cosine similarity between two JSON float arrays (Python required for float math)
_cosine_sim() {
  local vec_a="$1"
  local vec_b="$2"
  python3 - <<PYEOF
import json, math
a = json.loads("""$vec_a""")
b = json.loads("""$vec_b""")
dot = sum(x*y for x,y in zip(a,b))
mag_a = math.sqrt(sum(x*x for x in a))
mag_b = math.sqrt(sum(y*y for y in b))
denom = mag_a * mag_b
print(round(dot / denom, 4) if denom > 0 else 0.0)
PYEOF
}

# Randomly sample N lines from a file (one observation per line kept as-is)
_sample_observations() {
  local obs_file="$1"
  local n="$2"
  # Treat each non-empty line as one "observation unit"
  grep -v '^[[:space:]]*$' "$obs_file" | shuf -n "$n" 2>/dev/null || grep -v '^[[:space:]]*$' "$obs_file" | head -n "$n"
}

# Append an integrity result entry to integrity-log.md
_write_integrity_log() {
  local ts="$1"
  local checkpoint="$2"
  local samples_checked="$3"
  local flagged="$4"
  local min_sim="$5"
  local flag_table="$6"

  mkdir -p "$MEMORY_DIR"

  # Machine-parseable header line (invisible in rendered markdown)
  local status="PASSED"
  [ "$flagged" -gt 0 ] && status="FLAG"

  {
    echo ""
    echo "<!-- integrity:${checkpoint} ts=${ts} samples=${samples_checked} flagged=${flagged} min_sim=${min_sim} status=${status} -->"
    echo ""
    echo "## ${checkpoint^} Integrity Check — ${ts}"
    echo ""
    if [ "$flagged" -eq 0 ]; then
      echo "**Integrity check:** PASSED (${samples_checked} samples, lowest similarity: ${min_sim})"
    else
      echo "**Integrity check:** FLAG (${flagged}/${samples_checked} samples below threshold)"
      echo ""
      echo "$flag_table"
    fi
    echo ""
    echo "---"
  } >> "$INTEGRITY_LOG"
}

# Append a short summary to today's dream log
_write_dream_log_entry() {
  local ts="$1"
  local checkpoint="$2"
  local samples_checked="$3"
  local flagged="$4"
  local min_sim="$5"

  local today
  today=$(date -u '+%Y-%m-%d')
  local dream_log="$DREAM_LOG_DIR/dream-${today}.md"
  mkdir -p "$DREAM_LOG_DIR"

  if [ "$flagged" -eq 0 ]; then
    echo "<!-- integrity:${checkpoint} ts=${ts} samples=${samples_checked} min_sim=${min_sim} status=PASSED -->" >> "$dream_log"
    echo "_Integrity check (${checkpoint}): PASSED — ${samples_checked} samples, min similarity ${min_sim}_" >> "$dream_log"
  else
    echo "<!-- integrity:${checkpoint} ts=${ts} samples=${samples_checked} flagged=${flagged} min_sim=${min_sim} status=FLAG -->" >> "$dream_log"
    echo "⚠️ _Integrity check (${checkpoint}): FLAG — ${flagged}/${samples_checked} samples below threshold. Review \`memory/integrity-log.md\` for details._" >> "$dream_log"
  fi
  echo "" >> "$dream_log"
}

# ─── Phase: Capture pre-compression sample ───────────────────────────────────

cmd_capture() {
  # Called BEFORE the compression step (reflector or dream-cycle preflight).
  # Writes sampled observations + their embeddings to a temp state file.
  local obs_file="${1:-$MEMORY_DIR/observations.md}"
  local state_out="${2:-$MEMORY_DIR/.integrity-pre-${CHECKPOINT}.json}"

  [ -f "$obs_file" ] || { err "Observations file not found: $obs_file"; exit 1; }

  local threshold
  # Resolve env-var fallback per checkpoint so INTEGRITY_REFLECTOR_THRESHOLD /
  # INTEGRITY_DREAM_THRESHOLD are honoured when no YAML config is present.
  local _env_threshold
  case "$CHECKPOINT" in
    reflector) _env_threshold="$REFLECTOR_THRESHOLD" ;;
    dream)     _env_threshold="$DREAM_THRESHOLD"     ;;
    *)         _env_threshold="$GLOBAL_THRESHOLD"    ;;
  esac
  threshold=$(_load_yaml_threshold "${CHECKPOINT}_threshold" "$_env_threshold")

  log "capture: sampling $SAMPLE_N observations from $obs_file (checkpoint=$CHECKPOINT)"

  local samples=()
  while IFS= read -r line; do
    samples+=("$line")
  done < <(_sample_observations "$obs_file" "$SAMPLE_N")

  if [ "${#samples[@]}" -eq 0 ]; then
    log "capture: no observations to sample, skipping"
    echo '{"status":"skipped","reason":"empty"}' > "$state_out"
    exit 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "capture: dry-run mode — would embed ${#samples[@]} observations"
    echo "{\"status\":\"dry-run\",\"count\":${#samples[@]}}"
    exit 0
  fi

  # Build JSON array of {text, embedding} pairs
  local entries='[]'
  local i=0
  for sample in "${samples[@]}"; do
    local vec
    vec=$(_embed "$sample") || { log "capture: embed failed for sample $i, skipping"; ((i++)); continue; }
    if [ -n "$vec" ]; then
      entries=$(echo "$entries" | jq --argjson v "$vec" --arg t "$sample" '. + [{"text": $t, "embedding": $v}]')
    fi
    ((i++)) || true
  done

  local captured_count
  captured_count=$(echo "$entries" | jq 'length')
  log "capture: $captured_count samples embedded, writing state to $state_out"

  jq -n \
    --argjson entries "$entries" \
    --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg checkpoint "$CHECKPOINT" \
    --argjson threshold "$threshold" \
    '{"captured_at": $ts, "checkpoint": $checkpoint, "threshold": $threshold, "samples": $entries}' \
    > "$state_out"

  echo "{\"status\":\"ok\",\"captured\":$captured_count}"
}

# ─── Phase: Verify post-compression similarity ───────────────────────────────

cmd_verify() {
  # Called AFTER compression. Re-embeds a post-compression snapshot
  # and compares each pre-capture embedding against the nearest match
  # in the current observations file.
  local obs_file="${1:-$MEMORY_DIR/observations.md}"
  local state_in="${2:-$MEMORY_DIR/.integrity-pre-${CHECKPOINT}.json}"

  [ -f "$obs_file" ] || { err "Post-compression observations file not found: $obs_file"; exit 1; }

  if [ ! -f "$state_in" ]; then
    log "verify: no pre-capture state found at $state_in — nothing to verify"
    exit 0
  fi

  local state
  state=$(cat "$state_in")

  local status
  status=$(echo "$state" | jq -r '.status // empty')
  if [ "$status" = "skipped" ] || [ "$status" = "dry-run" ]; then
    log "verify: pre-capture was $status — skipping verify"
    rm -f "$state_in"
    exit 0
  fi

  local threshold
  threshold=$(echo "$state" | jq -r '.threshold')
  local pre_samples
  pre_samples=$(echo "$state" | jq -c '.samples[]')

  if [ -z "$pre_samples" ]; then
    log "verify: no pre-capture samples found, skipping"
    rm -f "$state_in"
    exit 0
  fi

  if [ "$DRY_RUN" = "true" ]; then
    log "verify: dry-run mode — would verify against $obs_file"
    rm -f "$state_in"
    exit 0
  fi

  # Embed a representative sample of post-compression observations
  local post_samples=()
  while IFS= read -r line; do
    post_samples+=("$line")
  done < <(_sample_observations "$obs_file" "$((SAMPLE_N * 2))")

  # Build post-embeddings
  local post_vecs=()
  for ps in "${post_samples[@]}"; do
    local vec
    vec=$(_embed "$ps") || continue
    [ -n "$vec" ] && post_vecs+=("$vec")
  done

  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local samples_checked=0
  local flagged=0
  local min_sim="1.0"
  local flag_rows=""

  # Guard: if no post embeddings were obtained, skip similarity checks
  if [ "${#post_vecs[@]}" -eq 0 ]; then
    log "verify: no post-compression embeddings available (API unavailable or empty file) — skipping similarity checks"
    rm -f "$state_in"
    echo "{\"status\":\"skipped\",\"reason\":\"no_post_embeddings\",\"checkpoint\":\"$CHECKPOINT\"}"
    exit 0
  fi

  # Guard: python3 is required for float arithmetic
  if ! command -v python3 &>/dev/null; then
    log "verify: python3 not available — skipping similarity checks"
    rm -f "$state_in"
    echo "{\"status\":\"skipped\",\"reason\":\"python3_unavailable\",\"checkpoint\":\"$CHECKPOINT\"}"
    exit 0
  fi

  while IFS= read -r pre_entry; do
    local pre_text
    pre_text=$(echo "$pre_entry" | jq -r '.text')
    local pre_vec
    pre_vec=$(echo "$pre_entry" | jq -c '.embedding')

    # Find the best-matching post embedding (maximum cosine similarity)
    local best_sim="0.0"
    for post_vec in "${post_vecs[@]}"; do
      local sim
      sim=$(_cosine_sim "$pre_vec" "$post_vec") || continue
      # Keep max
      best_sim=$(python3 -c "print(max($best_sim, $sim))")
    done

    ((samples_checked++)) || true

    # Update running minimum
    min_sim=$(python3 -c "print(min($min_sim, $best_sim))")

    # Check threshold
    local below
    below=$(python3 -c "print(1 if $best_sim < $threshold else 0)")
    if [ "$below" = "1" ]; then
      ((flagged++)) || true
      local short_text
      short_text=$(echo "$pre_text" | cut -c1-50 | tr '\n' ' ')
      flag_rows="${flag_rows}| \`${short_text}...\` | ${best_sim} | ⚠️ FLAGGED |\n"
      log "flag: '${short_text}' sim=$best_sim < threshold=$threshold"
    fi
  done < <(echo "$state" | jq -c '.samples[]')

  # Build flag table if needed
  local flag_table=""
  if [ "$flagged" -gt 0 ]; then
    flag_table="| Observation (first 50 chars) | Pre-compress sim | Status |\n|------------------------------|-----------------|--------|\n${flag_rows}"
  fi

  # Write outputs
  _write_integrity_log "$ts" "$CHECKPOINT" "$samples_checked" "$flagged" "$min_sim" "$flag_table"
  _write_dream_log_entry "$ts" "$CHECKPOINT" "$samples_checked" "$flagged" "$min_sim"

  log "verify: done — $samples_checked checked, $flagged flagged, min_sim=$min_sim"

  # Clean up state file
  rm -f "$state_in"

  # Emit structured result
  local status_word="PASSED"
  [ "$flagged" -gt 0 ] && status_word="FLAG"

  echo "{\"status\":\"$status_word\",\"checkpoint\":\"$CHECKPOINT\",\"samples_checked\":$samples_checked,\"flagged\":$flagged,\"min_sim\":$min_sim}"

  # Block pipeline only if configured AND flag was raised
  if [ "$flagged" -gt 0 ] && [ "$BLOCK_ON_FLAG" = "true" ]; then
    err "Integrity flag raised and INTEGRITY_BLOCK_ON_FLAG=true — halting pipeline"
    exit 2
  fi

  exit 0
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────

if [ "$INTEGRITY_ENABLED" != "true" ]; then
  log "disabled — skipping"
  echo '{"status":"disabled"}'
  exit 0
fi

[ -n "$CHECKPOINT" ] || { err "Usage: integrity-check.sh <reflector|dream> [--dry-run] <capture|verify> [args...]"; exit 1; }

# Parse remaining args: [--dry-run] <command> [arg1] [arg2]
REMAINING_ARGS=()
for _arg in "$@"; do
  if [ "$_arg" = "--dry-run" ]; then
    DRY_RUN="true"
  else
    REMAINING_ARGS+=("$_arg")
  fi
done

COMMAND="${REMAINING_ARGS[0]:-}"
ARG1="${REMAINING_ARGS[1]:-}"
ARG2="${REMAINING_ARGS[2]:-}"

case "$COMMAND" in
  capture) cmd_capture "$ARG1" "$ARG2" ;;
  verify)  cmd_verify  "$ARG1" "$ARG2" ;;
  *)
    err "Unknown command '$COMMAND'. Use: capture | verify"
    exit 1
    ;;
esac
