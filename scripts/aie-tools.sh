#!/usr/bin/env bash
# aie-tools.sh — AIE v2 Shared Tool Library
# Provides: extract_json, call_openrouter, run_timed_capture, run_tool
# Guard: source-safe, idempotent. Works when sourced from any AIE script.
#
# Usage (source, do not execute directly):
#   source "$SCRIPT_DIR/aie-tools.sh"

if [[ -n "${AIE_TOOLS_SH_LOADED:-}" ]]; then
  return 0
fi
readonly AIE_TOOLS_SH_LOADED=1

# ─── Bootstrap aie-config if not already loaded ──────────────────────────────
_AIE_TOOLS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${AIE_CONFIG_SH_LOADED:-}" ]]; then
  source "$_AIE_TOOLS_SCRIPT_DIR/aie-config.sh"
  aie_init
  aie_load_env
fi

# ─── Load config variables (only if not already set by caller) ───────────────
: "${MODEL:=$(aie_get "models.rumination" "google/gemini-2.5-flash")}"
: "${CLASSIFICATION_MODEL:=$(aie_get "models.classification" "google/gemini-2.5-flash")}"
: "${ENRICHMENT_MODEL:=$(aie_get "models.enrichment" "google/gemini-2.5-flash")}"
: "${HTTP_REFERER:=$(aie_get "api.http_referer" "https://github.com/gavdalf/total-recall")}"
: "${GMAIL_ACCOUNT:=$(aie_get "connectors.gmail.account" "")}"
: "${GMAIL_KEYRING_PASSWORD:=$(aie_get "connectors.gmail.keyring_password" "")}"
: "${CALENDAR_ACCOUNT:=$(aie_get "connectors.calendar.account" "")}"
: "${CALENDAR_KEYRING_PASSWORD:=$(aie_get "connectors.calendar.keyring_password" "")}"
: "${IONOS_ACCOUNT:=$(aie_get "connectors.ionos.account" "ionos")}"
: "${WEATHER_URL:=$(aie_get "ambient_actions.weather_url" "https://wttr.in")}"
: "${HEALTH_DATA_DIR:=$(aie_get "paths.health_data_dir" "${AIE_WORKSPACE}/health/data")}"
: "${WEB_SEARCH_SCRIPT:=$(aie_get "ambient_actions.tool_settings.web_search.script" "")}"
: "${PLACES_ENABLED:=$(aie_get "ambient_actions.places.enabled" "false")}"
: "${PLACES_LAT:=$(aie_get "ambient_actions.places.default_lat" "0.0")}"
: "${PLACES_LNG:=$(aie_get "ambient_actions.places.default_lng" "0.0")}"
: "${PLACES_LIMIT:=$(aie_get "ambient_actions.places.default_limit" "3")}"
: "${MAX_ACTIONS:=$(aie_get "ambient_actions.max_actions" "5")}"
: "${ACTION_BUDGET_SECONDS:=$(aie_get "ambient_actions.action_budget_seconds" "60")}"

export MODEL CLASSIFICATION_MODEL ENRICHMENT_MODEL HTTP_REFERER
export GMAIL_ACCOUNT GMAIL_KEYRING_PASSWORD
export CALENDAR_ACCOUNT CALENDAR_KEYRING_PASSWORD
export IONOS_ACCOUNT WEATHER_URL HEALTH_DATA_DIR WEB_SEARCH_SCRIPT
export PLACES_ENABLED PLACES_LAT PLACES_LNG PLACES_LIMIT
export MAX_ACTIONS ACTION_BUDGET_SECONDS

# ─── Load Google API abstraction ──────────────────────────────────────────────
source "$_AIE_TOOLS_SCRIPT_DIR/google-api.sh"

# ─── Global token counter (set by call_openrouter) ───────────────────────────
TOKENS_USED=0

# ─── extract_json ─────────────────────────────────────────────────────────────
# Robust JSON extraction with 5 fallback methods.
# Usage: result=$(extract_json "$raw_text")
# Returns 0 on success, 1 on failure.
extract_json() {
  local raw="$1"
  local result=""

  # Method 1: Direct parse (cleanest case)
  result=$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)
  if [[ -n "$result" ]]; then echo "$result"; return 0; fi

  # Method 2: Strip markdown code fences (```json ... ```)
  local stripped
  stripped=$(printf '%s' "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(printf '%s' "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 3: Strip any ``` fences (without json tag)
  stripped=$(printf '%s' "$raw" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(printf '%s' "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 4: Find first { to last } (greedy brace extraction)
  stripped=$(printf '%s' "$raw" | sed -n '/{/,/^}/p')
  if [[ -n "$stripped" ]]; then
    result=$(printf '%s' "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  # Method 5: python3 regex extraction as last resort
  if command -v python3 &>/dev/null; then
    result=$(python3 -c "
import re, json, sys
raw = sys.stdin.read()
match = re.search(r'\{.*\}', raw, re.DOTALL)
if match:
    try:
        obj = json.loads(match.group())
        print(json.dumps(obj))
    except json.JSONDecodeError:
        pass
" <<< "$raw" 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  return 1
}

# ─── call_openrouter ──────────────────────────────────────────────────────────
# OpenRouter API call wrapper.
# Usage: call_openrouter "$prompt" "$max_tokens" "$temperature" "$title" ["$model_override"]
# Sets global: TOKENS_USED
# Returns: LLM text on stdout, exit code 0 on success
call_openrouter() {
  local prompt="$1"
  local max_tokens="${2:-1000}"
  local temperature="${3:-0.3}"
  local title="${4:-AIE Call}"
  local model_override="${5:-}"
  local call_model="${model_override:-${MODEL:-google/gemini-2.5-flash}}"

  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[call_openrouter] ERROR: OPENROUTER_API_KEY not set" >&2
    return 1
  fi

  local payload
  payload=$(jq -cn \
    --arg model "$call_model" \
    --arg content "$prompt" \
    --argjson max_tokens "$max_tokens" \
    --argjson temperature "$temperature" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      temperature: $temperature,
      messages: [{role: "user", content: $content}]
    }')

  local http_resp
  http_resp=$(curl -s -w "\n__STATUS__:%{http_code}" \
    "https://openrouter.ai/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "HTTP-Referer: ${HTTP_REFERER:-https://github.com/gavdalf/total-recall}" \
    -H "X-Title: ${title}" \
    -d "$payload" \
    --max-time 60 2>/dev/null || echo "CURL_ERROR")

  if [[ "$http_resp" == "CURL_ERROR" ]]; then
    echo "[call_openrouter] ERROR: curl failed" >&2
    return 1
  fi

  local http_status body
  http_status=$(echo "$http_resp" | grep '__STATUS__:' | cut -d: -f2)
  body=$(echo "$http_resp" | sed 's/__STATUS__:.*//')

  if [[ "$http_status" != "200" ]]; then
    echo "[call_openrouter] ERROR: HTTP $http_status: $(echo "$body" | head -c 300)" >&2
    return 1
  fi

  # Update global token counter
  TOKENS_USED=$(echo "$body" | jq -r '(.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0)' 2>/dev/null || echo 0)

  echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null
}

# ─── run_timed_capture ────────────────────────────────────────────────────────
# Execute a command with a timeout, capturing stdout+stderr, returning JSON.
# Usage: result=$(run_timed_capture TIMEOUT_SECS MAX_CHARS command [args...])
# Returns JSON: {"status":"ok","output":"...","elapsed_seconds":N} or error variant.
# Always exits 0 — errors are encoded in the JSON.
run_timed_capture() {
  local timeout_s="$1"
  local max_chars="$2"
  shift 2

  local start end elapsed status output
  start=$(date +%s)
  output=$(timeout "$timeout_s" "$@" 2>&1)
  status=$?
  end=$(date +%s)
  elapsed=$((end - start))

  output=$(printf '%s' "$output" | head -c "$max_chars")

  if [[ $status -eq 0 ]]; then
    jq -cn \
      --arg status "ok" \
      --arg output "$output" \
      --argjson elapsed_seconds "$elapsed" \
      '{status:$status, output:$output, elapsed_seconds:$elapsed_seconds}'
    return 0
  fi

  local err="command_failed"
  if [[ $status -eq 124 ]]; then
    err="timeout"
  fi

  jq -cn \
    --arg status "error" \
    --arg error "$err" \
    --arg output "$output" \
    --argjson exit_code "$status" \
    --argjson elapsed_seconds "$elapsed" \
    '{status:$status, error:$error, output:$output, exit_code:$exit_code, elapsed_seconds:$elapsed_seconds}'
  return 0
}

# ─── run_tool ─────────────────────────────────────────────────────────────────
# Tool dispatcher for AIE lookups. Returns JSON from run_timed_capture.
# Usage: result=$(run_tool TOOL_NAME QUERY [REMAINING_BUDGET_SECS])
# Returns JSON: {"status":"ok","output":"..."} or {"status":"error","error":"..."}
run_tool() {
  local tool="$1"
  local query="$2"
  local remaining_budget="${3:-$ACTION_BUDGET_SECONDS}"
  local effective_timeout

  cap_timeout() {
    local requested="$1"
    local remaining="$2"
    if [[ "$remaining" -lt "$requested" ]]; then
      echo "$remaining"
    else
      echo "$requested"
    fi
  }

  case "$tool" in
    calendar_lookup)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      local from to
      from=$(echo "$query" | jq -r '.from // empty' 2>/dev/null || true)
      to=$(echo "$query" | jq -r '.to // empty' 2>/dev/null || true)
      if [[ -z "$from" || -z "$to" ]]; then
        from=$(echo "$query" | awk -F'|' '{print $1}')
        to=$(echo "$query" | awk -F'|' '{print $2}')
      fi
      [[ -z "$from" ]] && from="$(date +%Y-%m-%d)"
      [[ -z "$to" ]] && to="$(date -d '+2 days' +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)"
      if [[ -z "$CALENDAR_ACCOUNT" || -z "$CALENDAR_KEYRING_PASSWORD" ]]; then
        echo '{"status":"error","error":"calendar_lookup_not_configured"}'
      else
        run_timed_capture "$effective_timeout" 2000 env \
          GOG_KEYRING_PASSWORD="$CALENDAR_KEYRING_PASSWORD" \
          GOG_ACCOUNT="$CALENDAR_ACCOUNT" \
          gapi_calendar_events "$(aie_get "connectors.calendar.calendar_id" "primary")" --from "$from" --to "$to"
      fi
      ;;
    gmail_search)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      if [[ -z "$GMAIL_ACCOUNT" || -z "$GMAIL_KEYRING_PASSWORD" ]]; then
        echo '{"status":"error","error":"gmail_search_not_configured"}'
      else
        run_timed_capture "$effective_timeout" 2000 env \
          GOG_KEYRING_PASSWORD="$GMAIL_KEYRING_PASSWORD" \
          GOG_ACCOUNT="$GMAIL_ACCOUNT" \
          gapi_gmail_search "$query" --limit 5
      fi
      ;;
    gmail_read)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      if [[ -z "$GMAIL_ACCOUNT" || -z "$GMAIL_KEYRING_PASSWORD" ]]; then
        echo '{"status":"error","error":"gmail_read_not_configured"}'
      else
        run_timed_capture "$effective_timeout" 3000 env \
          GOG_KEYRING_PASSWORD="$GMAIL_KEYRING_PASSWORD" \
          GOG_ACCOUNT="$GMAIL_ACCOUNT" \
          gapi_gmail_get "$query"
      fi
      ;;
    ionos_search)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      # himalaya v1.x uses positional IMAP-style query, not -q flag
      # Convert free-text query into "subject X or body X" format for himalaya
      local _ionos_q
      _ionos_q=$(echo "$query" | sed 's/ OR / or /g; s/ AND / and /g')
      # If query doesn't contain himalaya keywords (subject/body/from/to/date/before/after), wrap it
      if ! echo "$_ionos_q" | grep -qiE '\b(subject|body|from|to|date|before|after|flag)\b'; then
        _ionos_q="subject $_ionos_q or body $_ionos_q"
      fi
      run_timed_capture "$effective_timeout" 2000 bash -c 'himalaya envelope list --account "$1" --page-size 5 -- $2 order by date desc 2>&1 | sed "s/\x1b\[[0-9;]*m//g"' _ "$IONOS_ACCOUNT" "$_ionos_q"
      ;;
    todoist_query)
      effective_timeout=$(cap_timeout 10 "$remaining_budget")
      run_timed_capture "$effective_timeout" 1500 todoist tasks --filter "$query"
      ;;
    weather)
      effective_timeout=$(cap_timeout 10 "$remaining_budget")
      run_timed_capture "$effective_timeout" 1000 bash -lc 'curl -s "$0/$1?format=j1" | jq ".current_condition[0]"' "$WEATHER_URL" "$query"
      ;;
    fitbit_data)
      effective_timeout=$(cap_timeout 5 "$remaining_budget")
      if [[ "$(aie_get "ambient_actions.tool_settings.fitbit_data.enabled" "true")" != "true" ]]; then
        echo '{"status":"error","error":"fitbit_data_disabled"}'
      else
        run_timed_capture "$effective_timeout" 2000 bash -lc 'cat "$0/$1.json"' "$HEALTH_DATA_DIR" "$query"
      fi
      ;;
    github_status)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      local gh_query="$query"
      local -a gh_args
      read -r -a gh_args <<< "$gh_query"
      if [[ ${#gh_args[@]} -eq 0 ]]; then
        echo '{"status":"error","error":"empty_gh_subcommand"}'
        return 0
      fi
      case "${gh_args[0]}" in
        status)
          run_timed_capture "$effective_timeout" 2000 gh status
          ;;
        issue)
          if [[ "${gh_args[1]:-}" =~ ^(list|view|status)$ ]]; then
            run_timed_capture "$effective_timeout" 2000 gh "${gh_args[@]}"
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        pr)
          if [[ "${gh_args[1]:-}" =~ ^(list|view|status|checks|diff)$ ]]; then
            run_timed_capture "$effective_timeout" 2000 gh "${gh_args[@]}"
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        repo)
          if [[ "${gh_args[1]:-}" == "view" ]]; then
            run_timed_capture "$effective_timeout" 2000 gh "${gh_args[@]}"
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        run)
          if [[ "${gh_args[1]:-}" =~ ^(list|view)$ ]]; then
            run_timed_capture "$effective_timeout" 2000 gh "${gh_args[@]}"
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        search)
          if [[ "${gh_args[1]:-}" =~ ^(issues|prs|repos|commits|code)$ ]]; then
            run_timed_capture "$effective_timeout" 2000 gh "${gh_args[@]}"
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        auth)
          if [[ "${gh_args[1]:-}" == "status" ]]; then
            run_timed_capture "$effective_timeout" 2000 gh auth status
          else
            echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          fi
          ;;
        *)
          echo '{"status":"error","error":"gh_subcommand_not_whitelisted"}'
          ;;
      esac
      ;;
    openrouter_balance)
      effective_timeout=$(cap_timeout 10 "$remaining_budget")
      if [[ "$(aie_get "ambient_actions.tool_settings.openrouter_balance.enabled" "true")" != "true" ]]; then
        echo '{"status":"error","error":"openrouter_balance_disabled"}'
      else
        run_timed_capture "$effective_timeout" 200 bash -lc 'curl -s "https://openrouter.ai/api/v1/credits" -H "Authorization: Bearer $OPENROUTER_API_KEY" | jq ".data | .total_credits - .total_usage"'
      fi
      ;;
    web_search)
      effective_timeout=$(cap_timeout 20 "$remaining_budget")
      if [[ "$(aie_get "ambient_actions.tool_settings.web_search.enabled" "false")" != "true" || -z "$WEB_SEARCH_SCRIPT" || ! -f "$WEB_SEARCH_SCRIPT" ]]; then
        echo '{"status":"error","error":"web_search_not_configured"}'
      else
        run_timed_capture "$effective_timeout" 3000 bash -lc 'node "$0" "$1" 2>/dev/null | head -c 3000' "$WEB_SEARCH_SCRIPT" "$query"
      fi
      ;;
    linkedin_messages)
      effective_timeout=$(cap_timeout 10 "$remaining_budget")
      # Read-only: returns cached LinkedIn messages from Mac Studio's last scrape
      local _li_cache="/tmp/linkedin-messages.json"
      # Try to read from Mac Studio via openclaw node invoke
      local _li_result
      _li_result=$(timeout "$effective_timeout" openclaw nodes invoke \
        --node "Mac Studio" \
        --command system.run \
        --params "{\"command\": [\"cat\", \"$_li_cache\"]}" \
        --invoke-timeout 10000 \
        --timeout 12000 \
        --json 2>/dev/null || echo '{"error":"node_unreachable"}')
      local _li_stdout
      _li_stdout=$(echo "$_li_result" | jq -r '.payload.stdout // .stdout // empty' 2>/dev/null || true)
      if [[ -n "$_li_stdout" ]] && echo "$_li_stdout" | jq -e 'type == "array"' >/dev/null 2>&1; then
        echo "{\"status\":\"ok\",\"output\":$(echo "$_li_stdout" | jq -c '.' 2>/dev/null)}"
      else
        echo '{"status":"error","error":"linkedin_messages_unavailable"}'
      fi
      ;;
    places_lookup)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      if [[ "$PLACES_ENABLED" != "true" || "$(aie_get "ambient_actions.tool_settings.places_lookup.enabled" "false")" != "true" ]]; then
        echo '{"status":"error","error":"places_lookup_disabled"}'
      else
        run_timed_capture "$effective_timeout" 2000 goplaces search "$query" --lat="$PLACES_LAT" --lng="$PLACES_LNG" --limit "$PLACES_LIMIT"
      fi
      ;;
    *)
      echo '{"status":"error","error":"tool_not_whitelisted"}'
      ;;
  esac
}
