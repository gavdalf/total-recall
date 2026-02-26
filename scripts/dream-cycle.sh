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
TOKEN_TARGET="${DREAM_TOKEN_TARGET:-8000}"

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

ensure_dirs() {
  mkdir -p "$ARCHIVE_DIR" "$DREAM_LOG_DIR" "$BACKUP_DIR" "$METRICS_DIR"
  mkdir -p "$MEMORY_DIR/archive/chunks"
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

cmd_validate() {
  require_file "$OBSERVATIONS_FILE"
  ensure_dirs

  local tokens
  tokens="$(token_count "$OBSERVATIONS_FILE")"

  local critical_hits=0
  local today_archive="$ARCHIVE_DIR/$(ISO_DATE_UTC).md"
  if [ -f "$today_archive" ]; then
    critical_hits="$(grep -Eci '^\*\*Impact\*\*: *(critical|Critical)$' "$today_archive" || true)"
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

  info "{\"status\":\"ok\",\"command\":\"validate\",\"validation_passed\":$passed,\"tokens\":$tokens,\"token_target\":$TOKEN_TARGET,\"git_status_lines\":$git_state,\"critical_false_archives\":$critical_hits,\"notes\":\"$notes\"}"

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
  dream-cycle.sh update-observations <new-observations-file>
  dream-cycle.sh write-log <log-file> <json-data?>
  dream-cycle.sh write-metrics <json-file> <json-data?>
  dream-cycle.sh validate
  dream-cycle.sh rollback

Notes:
  - JSON payload can be passed as argument or piped via stdin.
  - Paths are workspace-relative.
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
