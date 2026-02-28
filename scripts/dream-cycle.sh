#!/usr/bin/env bash
# Dream Cycle helper script (Phase 1 MVP)
# Called by the nightly Dream Cycle agent for safe file operations.

set -euo pipefail

OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/workspace}"
SKILL_DIR="$OPENCLAW_WORKSPACE/skills/total-recall"

# Load environment if present
if [ -f "$OPENCLAW_WORKSPACE/.env" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$OPENCLAW_WORKSPACE/.env"
  set +a
fi

# Load portability helpers if present
if [ -f "$SKILL_DIR/scripts/_compat.sh" ]; then
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/_compat.sh"
fi

MEMORY_DIR="$OPENCLAW_WORKSPACE/memory"
OBSERVATIONS_FILE="$MEMORY_DIR/observations.md"
FAVORITES_FILE="$MEMORY_DIR/favorites.md"
ARCHIVE_DIR="$MEMORY_DIR/archive/observations"
DREAM_LOG_DIR="$MEMORY_DIR/dream-logs"
BACKUP_DIR="$MEMORY_DIR/.dream-backups"
METRICS_DIR="$OPENCLAW_WORKSPACE/research/dream-cycle-metrics/daily"
TOKEN_TARGET="${DREAM_TOKEN_TARGET:-5000}"

ISO_DATE_UTC() { date -u '+%Y-%m-%d'; }
ISO_STAMP_UTC() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

err() { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

token_count() {
  local file="$1"
  wc -c < "$file" | awk '{print int($1/4)}'
}

require_file() {
  local path="$1"
  [ -f "$path" ] || { err "Required file missing: $path"; exit 1; }
}

STAGING_DIR="$MEMORY_DIR/dream-staging"

ensure_dirs() {
  mkdir -p "$ARCHIVE_DIR" "$DREAM_LOG_DIR" "$BACKUP_DIR" "$METRICS_DIR"
  mkdir -p "$MEMORY_DIR/archive/chunks"
  mkdir -p "$STAGING_DIR"
}

atomic_write() {
  local destination="$1"
  local tmp="${destination}.tmp"

  cat > "$tmp"

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    err "Refusing empty write to $destination"
    exit 1
  fi

  mv "$tmp" "$destination"
}

json_input_or_arg() {
  local arg="${1:-}"
  if [ -n "$arg" ]; then
    printf '%s' "$arg"
    return 0
  fi

  if [ ! -t 0 ]; then
    cat
    return 0
  fi

  err "No JSON payload provided (pass argument or pipe via stdin)"
  exit 1
}

git_snapshot() {
  local msg="$1"
  git -C "$OPENCLAW_WORKSPACE" add -A
  git -C "$OPENCLAW_WORKSPACE" commit -m "$msg" || true
}

cmd_preflight() {
  local dry_run="false"
  if [ "${1:-}" = "--dry-run" ]; then
    dry_run="true"
  fi

  require_file "$OBSERVATIONS_FILE"
  require_file "$FAVORITES_FILE"
  ensure_dirs

  local backup_file="$BACKUP_DIR/observations.pre-dream.md"
  cp "$OBSERVATIONS_FILE" "$backup_file"

  if [ "$dry_run" = "false" ]; then
    git_snapshot "Pre-dream snapshot: $(ISO_STAMP_UTC)"
  fi

  info "{\"status\":\"ok\",\"command\":\"preflight\",\"dry_run\":$dry_run,\"backup\":\"$backup_file\"}"
}

cmd_archive() {
  local archive_file="${1:-}"
  local json_arg="${2:-}"

  [ -n "$archive_file" ] || { err "Usage: dream-cycle.sh archive <archive-file> <json-data?>"; exit 1; }
  ensure_dirs

  local archive_path="$OPENCLAW_WORKSPACE/$archive_file"
  mkdir -p "$(dirname "$archive_path")"

  local payload
  payload="$(json_input_or_arg "$json_arg")"

  printf '%s\n' "$payload" | jq -e . >/dev/null 2>&1 || {
    err "Archive payload is not valid JSON"
    exit 1
  }

  local tmp="${archive_path}.tmp"

  {
    local today
    today="$(ISO_DATE_UTC)"
    echo "# Archived Observations — $today"
    echo
    echo "Archived by Dream Cycle nightly run."
    echo
    echo "---"
    echo

    printf '%s\n' "$payload" | jq -r '
      if type == "array" then . else .items // [] end
      | to_entries[]
      | .value as $o
      | "## \($o.id)",
        "**Original date**: \($o.original_date)",
        "**Impact**: \($o.impact)",
        "**Archived reason**: \($o.archived_reason)",
        "\($o.full_text)",
        "",
        "---",
        ""
    '
  } > "$tmp"

  [ -s "$tmp" ] || { rm -f "$tmp"; err "Generated archive file is empty"; exit 1; }
  mv "$tmp" "$archive_path"

  info "{\"status\":\"ok\",\"command\":\"archive\",\"file\":\"$archive_file\"}"
}

cmd_chunk() {
  local chunk_file="${1:-}"
  local json_arg="${2:-}"

  [ -n "$chunk_file" ] || { err "Usage: dream-cycle.sh chunk <chunk-file> <json-data?>"; exit 1; }
  ensure_dirs

  local chunk_path="$OPENCLAW_WORKSPACE/$chunk_file"
  mkdir -p "$(dirname "$chunk_path")"

  local payload
  payload="$(json_input_or_arg "$json_arg")"

  if [ -z "$(printf '%s' "$payload" | tr -d '[:space:]')" ]; then
    err "Chunk payload is empty"
    exit 1
  fi

  printf '%s\n' "$payload" | jq -e . >/dev/null 2>&1 || {
    err "Chunk payload is not valid JSON"
    exit 1
  }

  local missing_fields=""
  local field
  for field in id topic date_range_start date_range_end confidence source_ids finding; do
    if ! printf '%s\n' "$payload" | jq -e --arg f "$field" 'has($f) and .[$f] != null' >/dev/null 2>&1; then
      missing_fields+=" $field"
    fi
  done

  if [ -n "$missing_fields" ]; then
    err "Chunk payload missing required fields:${missing_fields}"
    exit 1
  fi

  printf '%s\n' "$payload" | jq -e '
    (.id | type == "string" and length > 0) and
    (.topic | type == "string" and length > 0) and
    (.date_range_start | type == "string" and length > 0) and
    (.date_range_end | type == "string" and length > 0) and
    (.finding | type == "string" and length > 0)
  ' >/dev/null 2>&1 || {
    err "Chunk payload has invalid string fields (id/topic/date_range_start/date_range_end/finding must be non-empty strings)"
    exit 1
  }

  printf '%s\n' "$payload" | jq -e '.source_ids | type == "array"' >/dev/null 2>&1 || {
    err "Chunk payload field source_ids must be an array"
    exit 1
  }

  printf '%s\n' "$payload" | jq -e '.source_ids | length > 0' >/dev/null 2>&1 || {
    err "Chunk payload field source_ids must contain at least one source id"
    exit 1
  }

  printf '%s\n' "$payload" | jq -e '.source_ids | all(.[]; (type == "string" and length > 0))' >/dev/null 2>&1 || {
    err "Chunk payload field source_ids must contain only non-empty string ids"
    exit 1
  }

  printf '%s\n' "$payload" | jq -e '.confidence | IN("tentative", "established", "single-source")' >/dev/null 2>&1 || {
    err "Chunk payload field confidence must be one of: tentative, established, single-source"
    exit 1
  }

  local chunk_entry
  chunk_entry="$(printf '%s\n' "$payload" | jq -r '
    "## \(.id)",
    "**Topic**: \(.topic)",
    "**Date range**: \(.date_range_start) → \(.date_range_end)",
    "**Confidence**: \(.confidence)",
    "**Source IDs**: \(.source_ids | join(", "))",
    "**Source archive**: archive/observations/" + (.date_range_end | tostring) + ".md",
    "",
    "### Consolidated Finding",
    .finding,
    "",
    "---",
    ""
  ')"

  {
    if [ -f "$chunk_path" ]; then
      cat "$chunk_path"
      [ -s "$chunk_path" ] && printf '\n'
      printf '%s' "$chunk_entry"
    else
      local today
      today="$(ISO_DATE_UTC)"
      echo "# Chunked Observations — $today"
      echo "Chunked by Dream Cycle Phase 2 (Wisdom Builder)."
      echo
      echo "---"
      echo
      printf '%s' "$chunk_entry"
    fi
  } | atomic_write "$chunk_path"

  info "{\"status\":\"ok\",\"command\":\"chunk\",\"file\":\"$chunk_file\"}"
}

cmd_update_observations() {
  local new_file="${1:-}"
  [ -n "$new_file" ] || { err "Usage: dream-cycle.sh update-observations <new-observations-file>"; exit 1; }

  local source_path="$OPENCLAW_WORKSPACE/$new_file"
  [ -f "$source_path" ] || { err "New observations file not found: $source_path"; exit 1; }

  require_file "$OBSERVATIONS_FILE"
  ensure_dirs

  local tmp="$OBSERVATIONS_FILE.tmp"
  cp "$source_path" "$tmp"

  [ -s "$tmp" ] || { rm -f "$tmp"; err "New observations content is empty"; exit 1; }

  local before_tokens after_tokens
  before_tokens="$(token_count "$OBSERVATIONS_FILE")"
  after_tokens="$(token_count "$tmp")"

  mv "$tmp" "$OBSERVATIONS_FILE"

  git -C "$OPENCLAW_WORKSPACE" add "$OBSERVATIONS_FILE"
  git -C "$OPENCLAW_WORKSPACE" commit -m "Dream cycle: update observations $(ISO_STAMP_UTC)" || true

  info "{\"status\":\"ok\",\"command\":\"update-observations\",\"tokens_before\":$before_tokens,\"tokens_after\":$after_tokens}"
}

cmd_write_log() {
  local log_file="${1:-}"
  local json_arg="${2:-}"
  [ -n "$log_file" ] || { err "Usage: dream-cycle.sh write-log <log-file> <json-data?>"; exit 1; }

  local path="$OPENCLAW_WORKSPACE/$log_file"
  mkdir -p "$(dirname "$path")"

  local payload
  payload="$(json_input_or_arg "$json_arg")"
  printf '%s\n' "$payload" | jq -e . >/dev/null 2>&1 || { err "Log payload is not valid JSON"; exit 1; }

  local tmp="${path}.tmp"
  printf '%s\n' "$payload" | jq -r '
    "# Dream Cycle Log — " + (.date // ""),
    "",
    "**Run time**: " + (.run_time // ""),
    "**Model**: " + (.model // ""),
    "**Duration**: " + ((.runtime_seconds // 0) | tostring) + " seconds",
    "**Status**: " + (.status // "⚠️ Partial"),
    "",
    "---",
    "",
    "## Summary",
    "",
    "- **Observations analyzed**: " + ((.observations_total // 0) | tostring),
    "- **Observations archived**: " + ((.observations_archived // 0) | tostring),
    "- **Semantic hooks created**: " + ((.hooks_created // 0) | tostring),
    "- **Token reduction**: " + ((.tokens_before // 0) | tostring) + " → " + ((.tokens_after // 0) | tostring) + " (saved " + ((.tokens_saved // 0) | tostring) + " tokens)",
    "- **Dry run**: " + ((.dry_run // false) | tostring),
    "",
    "## Archived Items",
    "",
    ((.archived_items // []) | if length == 0 then ["- None"] else map("- " + .) end | .[]),
    "",
    "## Hooks Created",
    "",
    ((.hooks // []) | if length == 0 then ["- None"] else . end | .[]),
    "",
    "## Validation Results",
    "",
    ((.validation_results // []) | if length == 0 then ["- None"] else map("- " + .) end | .[]),
    "",
    "## Flagged for Review",
    "",
    (.flagged_for_review // "None"),
    "",
    "## Next Steps",
    "",
    (.next_steps // "None")
  ' > "$tmp"

  [ -s "$tmp" ] || { rm -f "$tmp"; err "Generated dream log is empty"; exit 1; }
  mv "$tmp" "$path"

  info "{\"status\":\"ok\",\"command\":\"write-log\",\"file\":\"$log_file\"}"
}

cmd_write_metrics() {
  local json_file="${1:-}"
  local json_arg="${2:-}"
  [ -n "$json_file" ] || { err "Usage: dream-cycle.sh write-metrics <json-file> <json-data?>"; exit 1; }

  local path="$OPENCLAW_WORKSPACE/$json_file"
  mkdir -p "$(dirname "$path")"

  local payload
  payload="$(json_input_or_arg "$json_arg")"

  printf '%s\n' "$payload" | jq -e . >/dev/null 2>&1 || { err "Metrics payload is not valid JSON"; exit 1; }

  printf '%s\n' "$payload" | jq -e '
    .date and .model and (.runtime_seconds != null) and
    (.observations_total != null) and (.observations_archived != null) and
    (.hooks_created != null) and (.tokens_before != null) and
    (.tokens_after != null) and (.tokens_saved != null) and
    (.reduction_pct != null) and (.critical_false_archives != null) and
    (.validation_passed != null) and (.dry_run != null)
  ' >/dev/null || {
    err "Metrics payload missing required fields"
    exit 1
  }

  local tmp="${path}.tmp"
  printf '%s\n' "$payload" | jq '.' > "$tmp"
  mv "$tmp" "$path"

  info "{\"status\":\"ok\",\"command\":\"write-metrics\",\"file\":\"$json_file\"}"
}

cmd_decay() {
  require_file "$OBSERVATIONS_FILE"
  ensure_dirs

  local today
  today="$(ISO_DATE_UTC)"

  local decay_tmp="${OBSERVATIONS_FILE}.decay.tmp"
  rm -f "$decay_tmp"

  # Use python3 for reliable float arithmetic and date handling.
  # On ANY parse error, python3 exits non-zero; original file is left untouched.
  set +e
  python3 - "$OBSERVATIONS_FILE" "$today" > "$decay_tmp" <<'PYEOF'
import sys
import os
import re
from datetime import date

obs_file = sys.argv[1]
today_str = sys.argv[2]

# Decay rates per type (per day). Types not listed default to fact rate.
DECAY_RATES = {
    "event":      0.5,
    "fact":       0.1,
    "preference": 0.02,
    "rule":       0.0,
    "habit":      0.0,
    "goal":       0.0,
    "context":    0.1,
}

try:
    today = date.fromisoformat(today_str)
except ValueError as e:
    print("ERROR: Cannot parse today's date '{}': {}".format(today_str, e), file=sys.stderr)
    sys.exit(1)

try:
    with open(obs_file, 'r', encoding='utf-8') as f:
        lines = f.readlines()
except IOError as e:
    print("ERROR: Cannot read observations file: {}".format(e), file=sys.stderr)
    sys.exit(1)

output = []
changed = 0

for lineno, line in enumerate(lines, 1):
    stripped = line.rstrip('\n')

    # Only process HTML comment metadata lines that contain dc: fields
    if '<!--' in stripped and '-->' in stripped and 'dc:' in stripped:
        type_m = re.search(r'\bdc:type=(\w+)\b', stripped)
        imp_m  = re.search(r'\bdc:importance=([\d.]+)\b', stripped)
        date_m = re.search(r'\bdc:date=(\d{4}-\d{2}-\d{2})\b', stripped)

        # Only process lines that have all three decay-relevant fields
        if type_m and imp_m and date_m:
            obs_type = type_m.group(1)

            try:
                importance = float(imp_m.group(1))
            except ValueError:
                print("ERROR: Invalid importance value '{}' on line {}".format(imp_m.group(1), lineno), file=sys.stderr)
                sys.exit(1)

            try:
                obs_date = date.fromisoformat(date_m.group(1))
            except ValueError:
                print("ERROR: Invalid date '{}' on line {}".format(date_m.group(1), lineno), file=sys.stderr)
                sys.exit(1)

            if obs_date > today:
                # Future-dated observation: no decay yet
                output.append(line)
                continue

            days_elapsed = (today - obs_date).days
            # Unknown types fall back to fact decay rate
            decay_rate = DECAY_RATES.get(obs_type, 0.1)
            new_importance = importance - decay_rate * days_elapsed
            # Clamp to [0.0, 10.0]
            new_importance = max(0.0, min(10.0, new_importance))
            new_importance = round(new_importance, 2)

            if new_importance != importance:
                new_line = re.sub(
                    r'\bdc:importance=[\d.]+\b',
                    'dc:importance={}'.format(new_importance),
                    stripped
                )
                output.append(new_line + '\n')
                changed += 1
                continue

    output.append(line)

# Archive observations that have decayed below threshold
ARCHIVE_THRESHOLD = 3.0
archived = []
final_output = []

for line in output:
    stripped = line.rstrip('\n')
    if '<!--' in stripped and '-->' in stripped and 'dc:' in stripped:
        imp_m = re.search(r'\bdc:importance=([\d.]+)\b', stripped)
        if imp_m:
            imp_val = float(imp_m.group(1))
            if imp_val < ARCHIVE_THRESHOLD and imp_val >= 0.0:
                archived.append(line)
                continue
    final_output.append(line)

if archived:
    # Append archived observations to the archive file
    archive_dir = os.path.dirname(obs_file)
    archive_file = os.path.join(archive_dir, "archived-observations.md")
    try:
        with open(archive_file, 'a', encoding='utf-8') as af:
            af.write("\n## Auto-archived by decay ({})\n".format(today_str))
            for a in archived:
                af.write(a)
    except IOError as e:
        print("WARNING: Could not write to archive file: {}".format(e), file=sys.stderr)
        # Don't lose the data — keep it in output instead
        final_output.extend(archived)
        archived = []

print("INFO: Decay complete — {} observations updated, {} archived (below {})".format(changed, len(archived), ARCHIVE_THRESHOLD), file=sys.stderr)
sys.stdout.write(''.join(final_output))
PYEOF
  local py_exit=$?
  set -e

  if [ $py_exit -ne 0 ]; then
    rm -f "$decay_tmp"
    err "Decay calculation failed — observations.md unchanged"
    exit 1
  fi

  if [ ! -s "$decay_tmp" ]; then
    rm -f "$decay_tmp"
    err "Decay produced empty output — observations.md unchanged"
    exit 1
  fi

  # Atomic replace: use mv (temp file already written and validated)
  mv "$decay_tmp" "$OBSERVATIONS_FILE"

  info "{\"status\":\"ok\",\"command\":\"decay\",\"date\":\"$today\"}"
}

cmd_write_staging() {
  local staging_file="${1:-}"
  local json_arg="${2:-}"

  [ -n "$staging_file" ] || { err "Usage: dream-cycle.sh write-staging <staging-file> <json-data?>"; exit 1; }
  ensure_dirs

  # ── Safety check: path must be workspace-relative and inside memory/dream-staging/ ──
  # Strip any leading "./" normalisation, then check prefix
  local normalised_path
  normalised_path="$(printf '%s' "$staging_file" | sed 's|^\./||')"

  # Resolve to absolute and verify it stays within STAGING_DIR (prevents path traversal)
  local abs_staging_file
  abs_staging_file="$(cd "$OPENCLAW_WORKSPACE" && realpath -m "$normalised_path" 2>/dev/null || true)"

  if [ -z "$abs_staging_file" ]; then
    err "Cannot resolve staging file path: $staging_file"
    exit 1
  fi

  # Ensure the resolved path is under STAGING_DIR (no path traversal)
  local real_staging_dir
  real_staging_dir="$(realpath -m "$STAGING_DIR" 2>/dev/null || echo "$STAGING_DIR")"

  case "$abs_staging_file" in
    "$real_staging_dir"/*)
      : # ok — inside staging dir
      ;;
    *)
      err "Staging file path must be inside memory/dream-staging/ — got: $staging_file (resolved: $abs_staging_file)"
      exit 1
      ;;
  esac

  local payload
  payload="$(json_input_or_arg "$json_arg")"

  # Reject empty payload
  if [ -z "$(printf '%s' "$payload" | tr -d '[:space:]')" ]; then
    err "Staging payload is empty"
    exit 1
  fi

  # Validate JSON
  printf '%s\n' "$payload" | jq -e . >/dev/null 2>&1 || {
    err "Staging payload is not valid JSON"
    exit 1
  }

  # Validate required fields
  local required_fields="type target_file confidence pattern_summary proposed_text evidence"
  local missing_fields=""
  local field
  for field in $required_fields; do
    # Field must exist, be non-null, and be a non-empty string
    if ! printf '%s\n' "$payload" | jq -e --arg f "$field" \
        'has($f) and .[$f] != null and (.[$f] | type == "string") and (.[$f] | length > 0)' \
        >/dev/null 2>&1; then
      missing_fields="${missing_fields} ${field}"
    fi
  done

  if [ -n "$missing_fields" ]; then
    err "Staging payload missing or empty required string fields:${missing_fields}"
    exit 1
  fi

  # Validate type is one of the allowed WP1 types (not 'context' — context type is never promoted)
  printf '%s\n' "$payload" | jq -e '.type | IN("fact", "preference", "goal", "habit", "rule")' \
    >/dev/null 2>&1 || {
    err "Staging payload field 'type' must be one of: fact, preference, goal, habit, rule (context is never promoted)"
    exit 1
  }

  # Validate target_file is one of the allowed files
  printf '%s\n' "$payload" | jq -e '.target_file | IN("AGENTS.md", "MEMORY.md", "TOOLS.md", "favorites.md")' \
    >/dev/null 2>&1 || {
    err "Staging payload field 'target_file' must be one of: AGENTS.md, MEMORY.md, TOOLS.md, favorites.md"
    exit 1
  }

  # Validate confidence level
  printf '%s\n' "$payload" | jq -e '.confidence | IN("high", "medium", "low")' \
    >/dev/null 2>&1 || {
    err "Staging payload field 'confidence' must be one of: high, medium, low"
    exit 1
  }

  # supporting_observations is optional but if present must be an array of strings
  if printf '%s\n' "$payload" | jq -e 'has("supporting_observations") and (.supporting_observations != null)' \
      >/dev/null 2>&1; then
    printf '%s\n' "$payload" | jq -e '.supporting_observations | type == "array"' >/dev/null 2>&1 || {
      err "Staging payload field 'supporting_observations' must be an array when present"
      exit 1
    }
  fi

  # Generate staging file path (workspace-absolute)
  local staging_path="$abs_staging_file"
  mkdir -p "$(dirname "$staging_path")"

  # Build the proposal markdown and write atomically
  # Staging files are NOT git-committed (ephemeral, pending human review)
  local generated_at
  generated_at="$(ISO_STAMP_UTC)"

  {
    printf '%s\n' "$payload" | jq -r --arg ts "$generated_at" '
      "# Pattern Promotion Proposal",
      "**Generated**: " + $ts,
      "**Type**: " + .type,
      "**Target file**: " + .target_file,
      "**Confidence**: " + .confidence,
      "**Supporting observations**: " + (
        if has("supporting_observations") and (.supporting_observations | type == "array") and (.supporting_observations | length > 0)
        then (.supporting_observations | join(", "))
        else "N/A"
        end
      ),
      "**Pattern summary**: " + .pattern_summary,
      "",
      "## Proposed addition to " + .target_file,
      "```",
      .proposed_text,
      "```",
      "",
      "## Evidence",
      .evidence,
      "",
      "## Human review required — respond: APPROVE / REJECT / MODIFY"
    '
  } | atomic_write "$staging_path"

  info "{\"status\":\"ok\",\"command\":\"write-staging\",\"file\":\"$staging_file\",\"confidence\":$(printf '%s\n' "$payload" | jq '.confidence')}"
}

cmd_validate() {
  require_file "$OBSERVATIONS_FILE"
  ensure_dirs

  local tokens
  tokens="$(token_count "$OBSERVATIONS_FILE")"

  local critical_hits=0
  local high_importance_hits=0
  local today_archive="$ARCHIVE_DIR/$(ISO_DATE_UTC).md"
  if [ -f "$today_archive" ]; then
    # Legacy backward-compat check: string label "critical" (Phase 1 archives)
    critical_hits="$(grep -Eci '^\*\*Impact\*\*: *(critical|Critical)$' "$today_archive" || true)"

    # WP2 check: numeric importance >= 9.0 in archive **Impact** lines
    high_importance_hits="$(awk '
      /^\*\*Impact\*\*:/ {
        val = $0
        sub(/^\*\*Impact\*\*:[[:space:]]*/, "", val)
        num = val + 0
        if (val ~ /^[0-9]/ && num >= 9.0) count++
      }
      END { print count+0 }
    ' "$today_archive" || echo "0")"
  fi

  local git_state
  git_state="$(git -C "$OPENCLAW_WORKSPACE" status --short | wc -l | awk '{print $1}')"

  local passed=true
  local notes="ok"

  if [ "$tokens" -gt "$TOKEN_TARGET" ]; then
    passed=false
    notes="token count above target (${tokens} > ${TOKEN_TARGET})"
  fi

  if [ "$critical_hits" -gt 0 ]; then
    passed=false
    notes="critical archived items detected: $critical_hits"
  fi

  if [ "$high_importance_hits" -gt 0 ]; then
    passed=false
    notes="${notes}; high-importance items (>=9.0) archived: $high_importance_hits"
  fi

  local total_false_archives=$(( critical_hits + high_importance_hits ))

  info "{\"status\":\"ok\",\"command\":\"validate\",\"validation_passed\":$passed,\"tokens\":$tokens,\"token_target\":$TOKEN_TARGET,\"git_status_lines\":$git_state,\"critical_false_archives\":$total_false_archives,\"notes\":\"$notes\"}"

  if [ "$passed" != true ]; then
    exit 1
  fi
}

cmd_rollback() {
  set +e
  git -C "$OPENCLAW_WORKSPACE" reset --hard HEAD~1
  local rc=$?
  set -e

  if [ $rc -ne 0 ]; then
    err "git rollback failed"
    exit 1
  fi

  local backup_file="$BACKUP_DIR/observations.pre-dream.md"
  if [ -f "$backup_file" ]; then
    cp "$backup_file" "$OBSERVATIONS_FILE"
  fi

  info "{\"status\":\"ok\",\"command\":\"rollback\"}"
}

usage() {
  cat <<'EOF'
Usage:
  dream-cycle.sh preflight [--dry-run]
  dream-cycle.sh archive <archive-file> <json-data?>
  dream-cycle.sh chunk <chunk-file> <json-data?>
  dream-cycle.sh decay
  dream-cycle.sh update-observations <new-observations-file>
  dream-cycle.sh write-log <log-file> <json-data?>
  dream-cycle.sh write-metrics <json-file> <json-data?>
  dream-cycle.sh write-staging <staging-file> <json-data?>
  dream-cycle.sh validate
  dream-cycle.sh rollback

Notes:
  - JSON payload can be passed as argument or piped via stdin.
  - Paths are workspace-relative.
  - decay: applies per-type daily importance decay to observations.md.
    Run before classification. Reads dc:type, dc:importance, dc:date metadata.
    Types without metadata are left unchanged. Decay rates:
      event -0.5/day | fact -0.1/day | preference -0.02/day
      rule, habit, goal: 0 (no decay) | unknown types: -0.1/day (fact rate)
  - write-staging: writes a Pattern Promotion Proposal to memory/dream-staging/ only.
    Required JSON fields: type, target_file, confidence, pattern_summary, proposed_text, evidence.
    Optional: supporting_observations (array of OBS IDs).
    Path traversal is blocked — file must resolve inside memory/dream-staging/.
    Staging files are NOT git-committed (ephemeral, pending human review via staging-review.sh).
  - DREAM_TOKEN_TARGET env var overrides the default token target (default: 5000).
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    preflight)
      shift
      cmd_preflight "$@"
      ;;
    archive)
      shift
      cmd_archive "$@"
      ;;
    chunk)
      shift
      cmd_chunk "$@"
      ;;
    decay)
      shift
      cmd_decay "$@"
      ;;
    update-observations)
      shift
      cmd_update_observations "$@"
      ;;
    write-log)
      shift
      cmd_write_log "$@"
      ;;
    write-metrics)
      shift
      cmd_write_metrics "$@"
      ;;
    write-staging)
      shift
      cmd_write_staging "$@"
      ;;
    validate)
      shift
      cmd_validate "$@"
      ;;
    rollback)
      shift
      cmd_rollback "$@"
      ;;
    ""|-h|--help|help)
      usage
      ;;
    *)
      err "Unknown command: $cmd"
      usage
      exit 1
      ;;
  esac
}

main "$@"
