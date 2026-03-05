#!/usr/bin/env bash
# ambient-actions.sh — AIE v2 Phase 5: Tier 1 action resolution after rumination
# Usage:
#   bash ambient-actions.sh --dry-run-actions
#   bash ambient-actions.sh --execute-actions-only
#   bash ambient-actions.sh --live-actions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init
aie_load_env

RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$AIE_WORKSPACE/memory/rumination")"
ACTION_LOG="$RUMINATION_DIR/ambient-actions-log.jsonl"
RUMINATION_LOG="$AIE_LOGS_DIR/rumination.log"
ENV_FILE="$AIE_ENV_FILE"
MODEL="$(aie_get "models.ambient_actions" "google/gemini-2.5-flash")"
CLASSIFICATION_MODEL="$(aie_get "models.classification" "$MODEL")"
ENRICHMENT_MODEL="$(aie_get "models.enrichment" "$MODEL")"
HTTP_REFERER="$(aie_get "api.http_referer" "https://github.com/gavdalf/total-recall")"
MAX_ACTIONS="$(aie_get "ambient_actions.max_actions" "5")"
ACTION_BUDGET_SECONDS="$(aie_get "ambient_actions.action_budget_seconds" "60")"
GMAIL_ACCOUNT="$(aie_get "ambient_actions.tool_settings.gmail_search.gog_account" "$(aie_get "connectors.gmail.account" "")")"
GMAIL_KEYRING_PASSWORD="$(aie_get "ambient_actions.tool_settings.gmail_search.gog_keyring_password" "$(aie_get "connectors.gmail.keyring_password" "")")"
CALENDAR_ACCOUNT="$(aie_get "ambient_actions.tool_settings.calendar_lookup.gog_account" "$(aie_get "connectors.calendar.account" "")")"
CALENDAR_KEYRING_PASSWORD="$(aie_get "ambient_actions.tool_settings.calendar_lookup.gog_keyring_password" "$(aie_get "connectors.calendar.keyring_password" "")")"
IONOS_ACCOUNT="$(aie_get "ambient_actions.tool_settings.ionos_search.account" "$(aie_get "connectors.ionos.account" "ionos")")"
WEATHER_URL="$(aie_get "ambient_actions.weather_url" "https://wttr.in")"
HEALTH_DATA_DIR="$(aie_get "paths.health_data_dir" "$AIE_WORKSPACE/health/data")"
WEB_SEARCH_SCRIPT="$(aie_get "ambient_actions.tool_settings.web_search.script" "$(aie_get "paths.perplexity_search_script" "")")"
PLACES_ENABLED="$(aie_get "ambient_actions.places.enabled" "false")"
PLACES_LAT="$(aie_get "ambient_actions.places.default_lat" "0.0")"
PLACES_LNG="$(aie_get "ambient_actions.places.default_lng" "0.0")"
PLACES_LIMIT="$(aie_get "ambient_actions.places.default_limit" "3")"
TODAY="$(date +%Y-%m-%d)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MODE="execute_actions_only"
case "${1:-}" in
  ""|--execute-actions-only) MODE="execute_actions_only" ;;
  --dry-run-actions) MODE="dry_run_actions" ;;
  --live-actions) MODE="live_actions" ;;
  *)
    echo "Usage: $0 [--dry-run-actions|--execute-actions-only|--live-actions]" >&2
    exit 1
    ;;
esac

mkdir -p "$RUMINATION_DIR" "$(dirname "$RUMINATION_LOG")"
touch "$ACTION_LOG" "$RUMINATION_LOG"

log() {
  local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ambient-actions] $*"
  echo "$msg" >> "$RUMINATION_LOG"
}

append_action_log() {
  local json_line="$1"
  printf '%s\n' "$json_line" >> "$ACTION_LOG"
}

emit_stage_log() {
  local stage="$1"
  local payload="$2"
  local row
  row=$(jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$MODE" \
    --arg stage "$stage" \
    --argjson payload "$payload" \
    '{timestamp:$ts, mode:$mode, stage:$stage, payload:$payload}')
  append_action_log "$row"
}

log "=== Ambient actions START (mode=$MODE) ==="

if ! aie_bool "ambient_actions.enabled"; then
  log "Ambient actions disabled in config"
  emit_stage_log "skip" '{"reason":"ambient_actions_disabled"}'
  exit 0
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  log "ERROR: OPENROUTER_API_KEY not found in $ENV_FILE"
  emit_stage_log "fatal" '{"error":"missing_openrouter_api_key"}'
  exit 1
fi

TODAY_FILE="$RUMINATION_DIR/${TODAY}.jsonl"
if [[ ! -s "$TODAY_FILE" ]]; then
  log "No rumination file for today at $TODAY_FILE"
  emit_stage_log "skip" '{"reason":"missing_today_rumination_file"}'
  exit 0
fi

LATEST_RECORD=$(tail -n 1 "$TODAY_FILE" 2>/dev/null || echo "")
if [[ -z "$LATEST_RECORD" ]]; then
  log "No latest record in $TODAY_FILE"
  emit_stage_log "skip" '{"reason":"empty_today_rumination_file"}'
  exit 0
fi

INSIGHTS_JSON=$(echo "$LATEST_RECORD" | jq -c '.rumination_notes // []' 2>/dev/null || echo "[]")
INSIGHT_COUNT=$(echo "$INSIGHTS_JSON" | jq 'length' 2>/dev/null || echo 0)
if [[ "$INSIGHT_COUNT" -eq 0 ]]; then
  log "Latest rumination record has no insights"
  emit_stage_log "skip" '{"reason":"no_insights"}'
  exit 0
fi

extract_json() {
  local raw="$1"
  local result=""

  result=$(echo "$raw" | jq -c '.' 2>/dev/null)
  if [[ -n "$result" ]]; then echo "$result"; return 0; fi

  local stripped
  stripped=$(echo "$raw" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  stripped=$(echo "$raw" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  stripped=$(echo "$raw" | sed -n '/{/,/^}/p')
  if [[ -n "$stripped" ]]; then
    result=$(echo "$stripped" | jq -c '.' 2>/dev/null)
    if [[ -n "$result" ]]; then echo "$result"; return 0; fi
  fi

  if command -v python3 >/dev/null 2>&1; then
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

call_openrouter() {
  local prompt="$1"
  local max_tokens="$2"
  local temperature="$3"
  local title="$4"
  local model_override="${5:-$MODEL}"

  local payload
  payload=$(jq -cn \
    --arg model "$model_override" \
    --arg content "$prompt" \
    --argjson max_tokens "$max_tokens" \
    --argjson temperature "$temperature" \
    '{
      model: $model,
      max_tokens: $max_tokens,
      temperature: $temperature,
      messages: [{role:"user", content:$content}]
    }')

  local http_resp
  http_resp=$(timeout 65 curl -s -w "\n__STATUS__:%{http_code}" \
    "https://openrouter.ai/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "HTTP-Referer: $HTTP_REFERER" \
    -H "X-Title: $title" \
    -d "$payload" \
    --max-time 60 2>/dev/null || echo "CURL_ERROR")

  if [[ "$http_resp" == "CURL_ERROR" ]]; then
    echo '{"error":"curl_failed"}'
    return 1
  fi

  local status body text
  status=$(echo "$http_resp" | grep '__STATUS__:' | cut -d: -f2)
  body=$(echo "$http_resp" | sed 's/__STATUS__:.*//')

  if [[ "$status" != "200" ]]; then
    echo "$body" | jq -c --arg status "$status" '{error:"http_error", status:$status, body:(.|tostring)}' 2>/dev/null \
      || echo '{"error":"http_error"}'
    return 1
  fi

  text=$(echo "$body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  TOKENS_USED=$(echo "$body" | jq -r '(.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0)' 2>/dev/null || echo 0)

  if [[ -z "$text" ]]; then
    echo '{"error":"empty_response"}'
    return 1
  fi

  echo "$text"
  return 0
}

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
          gog calendar events "$(aie_get "connectors.calendar.calendar_id" "primary")" --from "$from" --to "$to"
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
          gog gmail search "$query" --limit 5
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
          gog gmail get "$query"
      fi
      ;;
    ionos_search)
      effective_timeout=$(cap_timeout 15 "$remaining_budget")
      run_timed_capture "$effective_timeout" 2000 himalaya envelope list --account "$IONOS_ACCOUNT" -q "$query" -s date -p 1 -w 5
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

CLASS_PROMPT=$(cat <<PROMPT_EOF
You are the Action Classifier for the Ambient Intelligence Engine.

You've just received rumination insights. For each insight, decide whether a READ-ONLY lookup could meaningfully enrich it with real data.

## Available tools (Tier 1 — read-only, zero side effects):
- calendar_lookup: Check upcoming calendar events
- gmail_search: Search the configured Gmail account
- gmail_read: Read a specific Gmail email by ID
- ionos_search: Search the configured IONOS email account
- todoist_query: Query Todoist tasks with filters
- weather: Get current weather for a location
- fitbit_data: Read health data for a date (YYYY-MM-DD)
- github_status: Run a gh CLI subcommand
- openrouter_balance: Check OpenRouter credit balance
- web_search: Search the web via Perplexity
- places_lookup: Search Google Places for nearby businesses/venues

## CRITICAL — Two email accounts:
The user may have more than one email account. When unsure, request both Gmail and IONOS searches if both tools are configured.
If you're unsure which account an email is on, request BOTH searches (counts as 2 actions).
Common examples: Stripe = IONOS. Google/YouTube = Gmail. Client emails = could be either.

## CRITICAL — Attribution rule:
All sensor data belongs to the primary user unless there is explicit evidence otherwise. Do NOT infer that other people triggered sensor events based on topic alone.

## Rules:
1. Only suggest an action if the result would MEANINGFULLY change or enrich the insight
2. "The user has a meeting tomorrow" does NOT need a calendar lookup — we already know
3. "Stripe sent urgent emails" DOES benefit from ionos_search (Stripe uses the work email)
4. Max 5 actions per run
5. If an insight is already specific enough, mark it as "no_action"
6. Prefer the most targeted tool — email search over web_search when it's an email topic
7. When unsure which email account, search BOTH (gmail_search + ionos_search)

## Insights to classify:
$INSIGHTS_JSON

Respond with ONLY valid JSON:
{
  "actions": [
    {
      "insight_index": 0,
      "action": "no_action" | "lookup",
      "tool": "tool_id or null",
      "query": "the specific query/command parameter",
      "intent": "what we're trying to learn"
    }
  ]
}
PROMPT_EOF
)

CLASS_RAW=$(call_openrouter "$CLASS_PROMPT" 900 0.2 "Ambient Actions Classification" "$CLASSIFICATION_MODEL")
CLASS_RC=$?
if [[ $CLASS_RC -ne 0 ]]; then
  log "Classification call failed"
  emit_stage_log "classification_error" "$(echo "$CLASS_RAW" | jq -c '.' 2>/dev/null || echo '{"error":"classification_failed"}')"
  exit 1
fi

CLASS_JSON=$(extract_json "$CLASS_RAW")
if [[ -z "$CLASS_JSON" ]]; then
  CLASS_JSON='{"actions":[]}'
  log "Classification JSON parse failed; using empty actions"
fi

if [[ "$(echo "$CLASS_JSON" | jq 'has("actions")' 2>/dev/null || echo "false")" != "true" ]]; then
  CLASS_JSON='{"actions":[]}'
fi

emit_stage_log "classification" "$CLASS_JSON"

ALLOWED_TOOLS='["calendar_lookup","gmail_search","gmail_read","ionos_search","todoist_query","weather","fitbit_data","github_status","openrouter_balance","web_search","places_lookup"]'
CANDIDATE_ACTIONS=$(echo "$CLASS_JSON" | jq -c --argjson allowed "$ALLOWED_TOOLS" --argjson max_actions "$MAX_ACTIONS" '
  [.actions[]? |
    select(.action == "lookup") |
    select((.tool // "") as $t | $allowed | index($t) != null) |
    {insight_index:(.insight_index // -1), tool:(.tool // ""), query:(.query // ""), intent:(.intent // "")}
  ] | .[:$max_actions]
' 2>/dev/null || echo '[]')

ACTIONS_COUNT=$(echo "$CANDIDATE_ACTIONS" | jq 'length' 2>/dev/null || echo 0)

ACTION_RESULTS='[]'
ACTION_PHASE_START=$(date +%s)

if [[ "$MODE" == "dry_run_actions" ]]; then
  log "Dry run actions mode: actions identified but not executed"
  emit_stage_log "actions_skipped_dry_run" "$CANDIDATE_ACTIONS"
else
  i=0
  while [[ $i -lt "$ACTIONS_COUNT" ]]; do
    elapsed=$(( $(date +%s) - ACTION_PHASE_START ))
    remaining_budget=$(( ACTION_BUDGET_SECONDS - elapsed ))
    if [[ $remaining_budget -le 0 ]]; then
      log "Action budget exceeded at ${elapsed}s; stopping further actions"
      emit_stage_log "action_budget_exceeded" "$(jq -cn --argjson elapsed "$elapsed" '{elapsed_seconds:$elapsed}')"
      break
    fi

    action=$(echo "$CANDIDATE_ACTIONS" | jq -c ".[$i]")
    tool=$(echo "$action" | jq -r '.tool')
    query=$(echo "$action" | jq -r '.query')

    result=$(run_tool "$tool" "$query" "$remaining_budget")

    merged=$(jq -cn \
      --argjson action "$action" \
      --argjson result "$result" \
      '{action:$action, result:$result}')

    ACTION_RESULTS=$(echo "$ACTION_RESULTS" | jq -c --argjson item "$merged" '. + [$item]' 2>/dev/null || echo '[]')
    emit_stage_log "action_result" "$merged"
    i=$((i + 1))
  done
fi

ENRICH_INPUT=$(jq -cn \
  --argjson insights "$INSIGHTS_JSON" \
  --argjson actions "$ACTION_RESULTS" \
  '{insights:$insights, action_results:$actions}')

ENRICH_PROMPT=$(cat <<PROMPT_EOF
You are enriching rumination insights with real data from lookups.

For each insight that had a successful lookup, rewrite the insight content to incorporate the real data. Keep the original voice: sharp, specific, actionable. Replace speculation with facts.

## Original insights + lookup results:
$ENRICH_INPUT

## Rules:
1. If the lookup returned useful data, rewrite the insight with specifics
2. If the lookup returned an error or irrelevant data, keep the original insight unchanged
3. Importance scores may increase if the data confirms urgency (e.g., a real deadline found)
4. Keep the same JSON structure — just update content, and optionally importance
5. Add an "enriched": true flag and "action_taken": "tool:query" to enriched insights

Respond with ONLY valid JSON:
{
  "enriched_insights": [
    {
      "thread": "...",
      "content": "enriched or original content",
      "importance": 0.X,
      "expires": "...",
      "tags": [...],
      "enriched": true|false,
      "action_taken": "tool:query" or null
    }
  ]
}
PROMPT_EOF
)

if [[ "$MODE" == "dry_run_actions" ]]; then
  ENRICHED_INSIGHTS="$INSIGHTS_JSON"
  emit_stage_log "enrichment_skipped_dry_run" '{"reason":"dry_run_actions_mode"}'
else
  ENRICH_RAW=$(call_openrouter "$ENRICH_PROMPT" 1200 0.2 "Ambient Actions Enrichment" "$ENRICHMENT_MODEL")
  ENRICH_RC=$?
  if [[ $ENRICH_RC -ne 0 ]]; then
    log "Enrichment call failed; using original insights"
    ENRICHED_INSIGHTS="$INSIGHTS_JSON"
    emit_stage_log "enrichment_error" "$(echo "$ENRICH_RAW" | jq -c '.' 2>/dev/null || echo '{"error":"enrichment_failed"}')"
  else
    ENRICH_JSON=$(extract_json "$ENRICH_RAW")
    if [[ -n "$ENRICH_JSON" && "$(echo "$ENRICH_JSON" | jq 'has("enriched_insights")' 2>/dev/null || echo "false")" == "true" ]]; then
      ENRICHED_INSIGHTS=$(echo "$ENRICH_JSON" | jq -c '.enriched_insights // []' 2>/dev/null || echo "$INSIGHTS_JSON")
    else
      ENRICHED_INSIGHTS="$INSIGHTS_JSON"
    fi
  fi
fi

emit_stage_log "enrichment" "$(jq -cn --argjson enriched "$ENRICHED_INSIGHTS" '{enriched_insights:$enriched}')"

FINAL_SUMMARY=$(jq -cn \
  --arg mode "$MODE" \
  --arg today_file "$TODAY_FILE" \
  --argjson insight_count "$INSIGHT_COUNT" \
  --argjson actions_requested "$ACTIONS_COUNT" \
  --argjson actions_executed "$(echo "$ACTION_RESULTS" | jq 'length' 2>/dev/null || echo 0)" \
  '{mode:$mode, rumination_file:$today_file, insight_count:$insight_count, actions_requested:$actions_requested, actions_executed:$actions_executed}')
emit_stage_log "summary" "$FINAL_SUMMARY"

if [[ "$MODE" == "live_actions" ]]; then
  ENRICHED_RECORD=$(echo "$LATEST_RECORD" | jq -c \
    --arg ts "$NOW" \
    --arg model "$MODEL" \
    --argjson actions "$ACTION_RESULTS" \
    --argjson notes "$ENRICHED_INSIGHTS" \
    '.rumination_notes = $notes
     | .ambient_actions = {
         timestamp: $ts,
         model: $model,
         actions: $actions,
         enriched: true
       }')

  TMP_RECORD=$(mktemp "${TODAY_FILE}.ambient.tmp.XXXXXX")
  echo "$ENRICHED_RECORD" > "$TMP_RECORD"
  TMP_COMBINED=$(mktemp "${TODAY_FILE}.ambient.combined.XXXXXX")
  cat "$TODAY_FILE" "$TMP_RECORD" > "$TMP_COMBINED"
  mv "$TMP_COMBINED" "$TODAY_FILE"
  rm -f "$TMP_RECORD"

  PRECONSCIOUS_SCRIPT="$SCRIPT_DIR/preconscious-select.sh"
  if [[ -f "$PRECONSCIOUS_SCRIPT" ]]; then
    timeout 90 bash "$PRECONSCIOUS_SCRIPT" >> "$RUMINATION_LOG" 2>&1 || log "WARN: preconscious-select trigger failed"
  else
    log "WARN: preconscious-select.sh not found at $PRECONSCIOUS_SCRIPT"
  fi

  log "Live mode write complete; enriched record appended"
fi

log "=== Ambient actions END (mode=$MODE) ==="
exit 0
