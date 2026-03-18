#!/usr/bin/env bash
# google-api.sh — Abstraction layer for Google API CLI tools
# Supports: gog (default), gws, or a custom wrapper script path
# Sourced by other scripts — not run directly.
#
# Config key: google_api.cli (in aie.yaml)
#   "gog"                  — use gog CLI (default)
#   "gws"                  — use gws CLI (different argument syntax)
#   "/path/to/my-wrapper"  — custom wrapper (receives gog-style arguments)

if [[ -n "${GOOGLE_API_SH_LOADED:-}" ]]; then
  return 0
fi
readonly GOOGLE_API_SH_LOADED=1

_GAPI_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bootstrap aie-config if not already loaded
if [[ -z "${AIE_CONFIG_SH_LOADED:-}" ]]; then
  source "$_GAPI_SCRIPT_DIR/aie-config.sh"
  aie_init
fi

source "$_GAPI_SCRIPT_DIR/_compat.sh"

# Lazily resolved CLI name
_GAPI_CLI=""

_gapi_init() {
  [[ -n "$_GAPI_CLI" ]] && return 0
  _GAPI_CLI="$(aie_get "google_api.cli" "gog")"
}

# ─── Calendar events ─────────────────────────────────────────────────────────
# Usage: gapi_calendar_events CALENDAR_ID [--from FROM --to TO | --days DAYS] [--max MAX] [--json]
gapi_calendar_events() {
  _gapi_init
  local calendar_id="$1"; shift
  local from="" to="" days="" max_events="" json_flag=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --to)   to="$2"; shift 2 ;;
      --days) days="$2"; shift 2 ;;
      --max)  max_events="$2"; shift 2 ;;
      --json) json_flag="--json"; shift ;;
      *) shift ;;
    esac
  done

  case "$_GAPI_CLI" in
    gog)
      local -a args=(gog calendar events "$calendar_id")
      [[ -n "$from" ]] && args+=(--from "$from")
      [[ -n "$to" ]] && args+=(--to "$to")
      [[ -n "$days" ]] && args+=(--days "$days")
      [[ -n "$max_events" ]] && args+=(--max "$max_events")
      [[ -n "$json_flag" ]] && args+=(--json)
      "${args[@]}"
      ;;
    gws)
      local time_min_val="" time_max_val=""
      if [[ -n "$from" ]]; then
        time_min_val="$from"
      fi
      if [[ -n "$to" ]]; then
        time_max_val="$to"
      fi
      if [[ -n "$days" ]]; then
        time_min_val=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if $_IS_MACOS; then
          time_max_val=$(date -u -v "+${days}d" +%Y-%m-%dT%H:%M:%SZ)
        else
          time_max_val=$(date -u -d "+${days} days" +%Y-%m-%dT%H:%M:%SZ)
        fi
      fi
      local params
      params=$(jq -cn \
        --arg cal "$calendar_id" \
        --arg tmin "$time_min_val" \
        --arg tmax "$time_max_val" \
        --argjson max "${max_events:-50}" \
        '{calendarId: $cal} + (if $tmin != "" then {timeMin: $tmin} else {} end) + (if $tmax != "" then {timeMax: $tmax} else {} end) + {maxResults: $max}')
      gws calendar events list --params "$params"
      ;;
    *)
      # Custom wrapper — pass gog-style arguments
      local -a args=("$_GAPI_CLI" calendar events "$calendar_id")
      [[ -n "$from" ]] && args+=(--from "$from")
      [[ -n "$to" ]] && args+=(--to "$to")
      [[ -n "$days" ]] && args+=(--days "$days")
      [[ -n "$max_events" ]] && args+=(--max "$max_events")
      [[ -n "$json_flag" ]] && args+=(--json)
      "${args[@]}"
      ;;
  esac
}

# ─── Gmail search ────────────────────────────────────────────────────────────
# Usage: gapi_gmail_search QUERY [--max|--limit MAX]
gapi_gmail_search() {
  _gapi_init
  local query="$1"; shift
  local max_results=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max|--limit) max_results="$2"; shift 2 ;;
      --json) shift ;;
      *) shift ;;
    esac
  done
  : "${max_results:=5}"

  case "$_GAPI_CLI" in
    gog) gog gmail search "$query" --limit "$max_results" ;;
    gws)
      local params
      params=$(jq -cn --arg q "$query" --argjson max "$max_results" \
        '{"userId":"me","q":$q,"maxResults":$max}')
      gws gmail users messages list --params "$params"
      ;;
    *) "$_GAPI_CLI" gmail search "$query" --limit "$max_results" ;;
  esac
}

# ─── Gmail get single message ────────────────────────────────────────────────
# Usage: gapi_gmail_get MSG_ID
gapi_gmail_get() {
  _gapi_init
  local msg_id="$1"

  case "$_GAPI_CLI" in
    gog) gog gmail get "$msg_id" ;;
    gws)
      local params
      params=$(jq -cn --arg id "$msg_id" '{"userId":"me","id":$id,"format":"full"}')
      gws gmail users messages get --params "$params"
      ;;
    *) "$_GAPI_CLI" gmail get "$msg_id" ;;
  esac
}

# ─── Gmail messages search (connector-style) ─────────────────────────────────
# Usage: gapi_gmail_messages_search QUERY [--max MAX] [--json] [--include-body]
gapi_gmail_messages_search() {
  _gapi_init
  local query="$1"; shift
  local max_results="" json_flag="" include_body=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max) max_results="$2"; shift 2 ;;
      --json) json_flag="--json"; shift ;;
      --include-body) include_body="--include-body"; shift ;;
      *) shift ;;
    esac
  done
  : "${max_results:=10}"

  case "$_GAPI_CLI" in
    gog)
      local -a args=(gog gmail messages search "$query" --max "$max_results")
      [[ -n "$json_flag" ]] && args+=(--json)
      [[ -n "$include_body" ]] && args+=(--include-body)
      "${args[@]}"
      ;;
    gws)
      local params
      params=$(jq -cn --arg q "$query" --argjson max "$max_results" \
        '{"userId":"me","q":$q,"maxResults":$max}')
      gws gmail users messages list --params "$params"
      ;;
    *)
      local -a args=("$_GAPI_CLI" gmail messages search "$query" --max "$max_results")
      [[ -n "$json_flag" ]] && args+=(--json)
      "${args[@]}"
      ;;
  esac
}
