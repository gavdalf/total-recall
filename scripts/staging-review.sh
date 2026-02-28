#!/usr/bin/env bash
# staging-review.sh — Pattern Promotion Proposal reviewer (WP4)
#
# Usage:
#   staging-review.sh list              — list pending proposals (file, age, target, confidence)
#   staging-review.sh show <file>       — print proposal content
#   staging-review.sh approve <file>    — mark approved (rename to .approved.md)
#   staging-review.sh reject <file>     — delete proposal
#
# Environment:
#   OPENCLAW_WORKSPACE  — path to the workspace (required; defaults to $HOME/workspace)
#
# Never applies changes — that is always the main agent's job on human instruction.

set -euo pipefail

OPENCLAW_WORKSPACE="${OPENCLAW_WORKSPACE:-$HOME/workspace}"
STAGING_DIR="$OPENCLAW_WORKSPACE/memory/dream-staging"

err()  { echo "ERROR: $*" >&2; }
info() { echo "$*"; }

# ── Helpers ──────────────────────────────────────────────────────────────────

ensure_staging_dir() {
  if [ ! -d "$STAGING_DIR" ]; then
    err "Staging directory does not exist: $STAGING_DIR"
    err "Run dream-cycle.sh preflight to initialise directories."
    exit 1
  fi
}

# Resolve a file argument to an absolute path inside STAGING_DIR.
# Accepts: bare filename, relative path, or absolute path.
# Exits with error if the resolved path is not inside STAGING_DIR.
resolve_staging_file() {
  local arg="$1"
  local resolved

  # If it's already absolute, use as-is; otherwise treat as workspace-relative
  case "$arg" in
    /*)
      resolved="$arg"
      ;;
    *)
      # Could be bare filename or relative path
      if [ -f "$STAGING_DIR/$arg" ]; then
        resolved="$STAGING_DIR/$arg"
      else
        resolved="$(cd "$OPENCLAW_WORKSPACE" && realpath -m "$arg" 2>/dev/null || true)"
      fi
      ;;
  esac

  if [ -z "$resolved" ]; then
    err "Cannot resolve path: $arg"
    exit 1
  fi

  # Safety: must be inside STAGING_DIR
  local real_staging
  real_staging="$(realpath -m "$STAGING_DIR" 2>/dev/null || echo "$STAGING_DIR")"
  case "$resolved" in
    "$real_staging"/*)
      : # ok
      ;;
    *)
      err "File is not inside the staging directory: $resolved"
      exit 1
      ;;
  esac

  printf '%s' "$resolved"
}

# Extract a field value from a proposal file (reads the header section).
extract_field() {
  local file="$1"
  local field="$2"
  grep -m1 "^\*\*${field}\*\*:" "$file" 2>/dev/null | sed "s/^\*\*${field}\*\*:[[:space:]]*//" || echo "N/A"
}

# Human-readable age of a file in minutes/hours/days
file_age() {
  local file="$1"
  local now mod_time elapsed

  now="$(date +%s)"
  # macOS uses -f %m, Linux uses -c %Y
  if stat --version >/dev/null 2>&1; then
    # GNU stat (Linux)
    mod_time="$(stat -c '%Y' "$file" 2>/dev/null || echo "$now")"
  else
    # BSD stat (macOS)
    mod_time="$(stat -f '%m' "$file" 2>/dev/null || echo "$now")"
  fi

  elapsed=$(( now - mod_time ))

  if [ "$elapsed" -lt 3600 ]; then
    printf '%dm ago' $(( elapsed / 60 ))
  elif [ "$elapsed" -lt 86400 ]; then
    printf '%dh ago' $(( elapsed / 3600 ))
  else
    printf '%dd ago' $(( elapsed / 86400 ))
  fi
}

# ── Subcommands ───────────────────────────────────────────────────────────────

cmd_list() {
  ensure_staging_dir

  # Find pending proposals: .md files that do NOT end in .approved.md
  local proposals=()
  while IFS= read -r -d '' f; do
    proposals+=("$f")
  done < <(find "$STAGING_DIR" -maxdepth 1 -name '*.md' ! -name '*.approved.md' ! -name '.gitkeep' -print0 2>/dev/null | sort -z)

  if [ "${#proposals[@]}" -eq 0 ]; then
    info "No pending proposals in $STAGING_DIR"
    return 0
  fi

  printf '%-45s  %-10s  %-15s  %-10s\n' "FILE" "AGE" "TARGET" "CONFIDENCE"
  printf '%-45s  %-10s  %-15s  %-10s\n' "----" "---" "------" "----------"

  local f
  for f in "${proposals[@]}"; do
    local basename age target confidence
    basename="$(basename "$f")"
    age="$(file_age "$f")"
    target="$(extract_field "$f" "Target file")"
    confidence="$(extract_field "$f" "Confidence")"
    printf '%-45s  %-10s  %-15s  %-10s\n' "$basename" "$age" "$target" "$confidence"
  done

  printf '\n%d pending proposal(s). Use: show <file> | approve <file> | reject <file>\n' "${#proposals[@]}"
}

cmd_show() {
  local arg="${1:-}"
  [ -n "$arg" ] || { err "Usage: staging-review.sh show <file>"; exit 1; }

  ensure_staging_dir
  local path
  path="$(resolve_staging_file "$arg")"

  [ -f "$path" ] || { err "File not found: $path"; exit 1; }

  info "=== $path ==="
  cat "$path"
}

cmd_approve() {
  local arg="${1:-}"
  [ -n "$arg" ] || { err "Usage: staging-review.sh approve <file>"; exit 1; }

  ensure_staging_dir
  local path
  path="$(resolve_staging_file "$arg")"

  [ -f "$path" ] || { err "File not found: $path"; exit 1; }

  # Must not already be approved
  case "$path" in
    *.approved.md)
      err "File is already approved: $path"
      exit 1
      ;;
  esac

  # Rename: strip .md suffix and add .approved.md
  local approved_path="${path%.md}.approved.md"

  if [ -e "$approved_path" ]; then
    err "Approved file already exists: $approved_path"
    exit 1
  fi

  mv "$path" "$approved_path"
  info "Approved: $(basename "$approved_path")"
  info "Note: apply the proposed change manually (the main agent reads approved proposals on next session start)."
}

cmd_reject() {
  local arg="${1:-}"
  [ -n "$arg" ] || { err "Usage: staging-review.sh reject <file>"; exit 1; }

  ensure_staging_dir
  local path
  path="$(resolve_staging_file "$arg")"

  [ -f "$path" ] || { err "File not found: $path"; exit 1; }

  local basename
  basename="$(basename "$path")"
  rm -f "$path"
  info "Rejected and deleted: $basename"
}

usage() {
  cat <<'EOF'
Usage:
  staging-review.sh list              — list pending proposals (file, age, target, confidence)
  staging-review.sh show <file>       — print proposal content
  staging-review.sh approve <file>    — mark approved (rename to .approved.md)
  staging-review.sh reject <file>     — delete proposal

Arguments:
  <file>  Basename of the proposal file (e.g. 20260228-023100-rule.md)
          or full path inside memory/dream-staging/.

Environment:
  OPENCLAW_WORKSPACE  Path to the workspace root (default: $HOME/workspace)

Notes:
  - staging-review.sh never applies changes to AGENTS.md, MEMORY.md, etc.
  - Approved proposals are renamed to .approved.md and read by the main agent.
  - Rejected proposals are permanently deleted.
  - Only .md files in memory/dream-staging/ are listed (not .approved.md files).
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)
      shift
      cmd_list "$@"
      ;;
    show)
      shift
      cmd_show "$@"
      ;;
    approve)
      shift
      cmd_approve "$@"
      ;;
    reject)
      shift
      cmd_reject "$@"
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
