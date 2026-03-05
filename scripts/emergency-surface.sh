#!/usr/bin/env bash
# emergency-surface.sh — AIE v2 emergency alert surfacing
# Runs after preconscious-select and sends urgent alerts through configured channels.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aie-config.sh"
aie_init
aie_load_env

BUFFER_FILE="$(aie_get "paths.preconscious_buffer" "$AIE_WORKSPACE/memory/preconscious-buffer.md")"
RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$AIE_WORKSPACE/memory/rumination")"
STATE_FILE="$AIE_MEMORY_DIR/.emergency-surface-sent.json"
LOG_FILE="$AIE_LOGS_DIR/emergency-surface.log"
MAX_ALERTS_PER_DAY="$(aie_get "thresholds.emergency.max_alerts_per_day" "2")"
EMERGENCY_IMPORTANCE="$(aie_get "thresholds.emergency.importance" "0.85")"
EXPIRES_WITHIN_SECONDS="$(aie_get "thresholds.emergency.expires_within_seconds" "14400")"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [emergency-surface] $*" | tee -a "$LOG_FILE"
}

iso_to_epoch() {
  local iso="$1"
  date -u -d "$iso" +%s 2>/dev/null || echo ""
}

hash_text() {
  local text="$1"
  printf '%s' "$text" | sha256sum | awk '{print $1}'
}

load_env() {
  aie_load_env
}

get_telegram_token() {
  local token
  token="$(aie_get "notifications.telegram.bot_token" "")"
  printf '%s' "$token"
}

is_quiet_hours() { aie_is_quiet_hours; }

init_state_if_missing() {
  mkdir -p "$(dirname "$STATE_FILE")"
  if [[ ! -f "$STATE_FILE" ]]; then
    jq -n --arg day "$(date +%Y-%m-%d)" \
      '{day:$day,sent_today:0,sent_hashes:[]}' > "$STATE_FILE"
  fi
}

roll_state_if_new_day() {
  local today state_day
  today="$(date +%Y-%m-%d)"
  state_day="$(jq -r '.day // ""' "$STATE_FILE" 2>/dev/null || echo "")"
  if [[ "$state_day" != "$today" ]]; then
    local tmp
    tmp="$(mktemp)"
    jq --arg day "$today" '.day=$day | .sent_today=0' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

alerts_sent_today() {
  jq -r '.sent_today // 0' "$STATE_FILE" 2>/dev/null || echo 0
}

already_sent_hash() {
  local h="$1"
  jq -e --arg h "$h" '.sent_hashes // [] | index($h) != null' "$STATE_FILE" >/dev/null 2>&1
}

record_sent_hash() {
  local h="$1"
  local tmp
  tmp="$(mktemp)"
  jq --arg h "$h" '
    .sent_today = ((.sent_today // 0) + 1)
    | .sent_hashes = (((.sent_hashes // []) + [$h]) | unique | .[-500:])
  ' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
}

extract_buffer_summaries() {
  sed -n 's/^[^*]*\*\*\[[^]]*\]\*\* //p' "$BUFFER_FILE" 2>/dev/null
}

find_latest_rumination_file() {
  ls -t "$RUMINATION_DIR"/*.jsonl 2>/dev/null | head -1
}

find_matching_note_json() {
  local summary="$1"
  local rum_file="$2"
  # Take first 80 chars of summary for matching (buffer truncates with ...)
  local prefix
  prefix="$(printf '%s' "$summary" | python3 -c 'import sys; print(sys.stdin.read()[:80], end="")' 2>/dev/null)"

  # Search all rumination entries (newest first) for a note whose content starts with the prefix
  local result=""
  while IFS= read -r line; do
    result="$(printf '%s' "$line" | jq -c --arg p "$prefix" '
      .rumination_notes[]?
      | select(.content | type == "string")
      | select((.content | startswith($p)) or ($p | startswith(.content)))
    ' 2>/dev/null | head -1)"
    if [[ -n "$result" ]]; then
      break
    fi
  done < <(tac "$rum_file" 2>/dev/null)
  printf '%s' "$result"
}

note_is_urgent_or_expiring() {
  local note_json="$1"
  local now_epoch expires importance urgent_flag expiring=false exp_epoch

  now_epoch="$(date -u +%s)"
  importance="$(printf '%s' "$note_json" | jq -r '.importance // 0')"
  urgent_flag="$(printf '%s' "$note_json" | jq -r '
    (
      (.urgency // false) == true
      or (.urgent // false) == true
      or (((.flags // []) | index("urgency")) != null)
      or (((.flags // []) | index("urgent")) != null)
      or (((.tags // []) | index("urgency")) != null)
      or (((.tags // []) | index("urgent")) != null)
    )')"
  expires="$(printf '%s' "$note_json" | jq -r '.expires // empty')"

  if [[ -n "$expires" && "$expires" != "null" ]]; then
    exp_epoch="$(iso_to_epoch "$expires")"
    if [[ -n "$exp_epoch" ]]; then
      if ((exp_epoch >= now_epoch && exp_epoch <= now_epoch + EXPIRES_WITHIN_SECONDS)); then
        expiring=true
      fi
    fi
  fi

  awk -v imp="$importance" -v threshold="$EMERGENCY_IMPORTANCE" 'BEGIN { exit (imp >= threshold ? 0 : 1) }' || return 1
  [[ "$urgent_flag" == "true" || "$expiring" == "true" ]]
}

send_telegram_alert() {
  local bot_token="$1"
  local summary="$2"
  local chat_id
  chat_id="$(aie_get "notifications.telegram.chat_id" "")"
  [[ -n "$chat_id" ]] || return 1
  local msg="AIE Alert: $summary"
  curl -sS --max-time 20 \
    -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${msg}" >/dev/null
}

send_discord_alert() {
  local webhook_url
  webhook_url="$(aie_get "notifications.discord.webhook_url" "")"
  [[ -n "$webhook_url" ]] || return 1
  jq -cn --arg content "AIE Alert: $1" '{content:$content}' | \
    curl -sS --max-time 20 -X POST "$webhook_url" \
      -H "Content-Type: application/json" \
      -d @- >/dev/null
}

send_webhook_alert() {
  local url headers_json
  url="$(aie_get "notifications.webhook.url" "")"
  [[ -n "$url" ]] || return 1
  headers_json="$(aie_get "notifications.webhook.headers" "{}")"
  WEBHOOK_URL="$url" WEBHOOK_HEADERS="$headers_json" WEBHOOK_SUMMARY="$1" python3 <<'PY'
import json
import os
import urllib.request

url = os.environ["WEBHOOK_URL"]
headers = json.loads(os.environ["WEBHOOK_HEADERS"])
summary = os.environ["WEBHOOK_SUMMARY"]
data = json.dumps({"text": f"AIE Alert: {summary}", "summary": summary}).encode()
request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **headers}, method="POST")
with urllib.request.urlopen(request, timeout=20) as response:
    response.read()
PY
}

dispatch_alert() {
  local summary="$1"
  local delivered=1
  if aie_notification_channel_enabled "telegram"; then
    local bot_token
    bot_token="$(get_telegram_token)"
    if [[ -n "$bot_token" ]] && send_telegram_alert "$bot_token" "$summary"; then
      log "Alert delivered via Telegram."
      delivered=0
    fi
  fi
  if aie_notification_channel_enabled "discord" && send_discord_alert "$summary"; then
    log "Alert delivered via Discord."
    delivered=0
  fi
  if aie_notification_channel_enabled "webhook" && send_webhook_alert "$summary"; then
    log "Alert delivered via webhook."
    delivered=0
  fi
  return "$delivered"
}

main() {
  log "=== Emergency surfacing START ==="
  load_env

  if is_quiet_hours; then
    log "Quiet hours active (22:00-07:00). Skipping."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  if [[ ! -f "$BUFFER_FILE" ]]; then
    log "No preconscious buffer found at $BUFFER_FILE. Skipping."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  local rum_file
  rum_file="$(find_latest_rumination_file)"
  if [[ -z "$rum_file" || ! -f "$rum_file" ]]; then
    log "No rumination file available. Skipping."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  init_state_if_missing
  roll_state_if_new_day

  local sent_today
  sent_today="$(alerts_sent_today)"
  if ((sent_today >= MAX_ALERTS_PER_DAY)); then
    log "Daily cap reached ($sent_today/$MAX_ALERTS_PER_DAY). Skipping."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  if ! aie_notification_channel_enabled "telegram" \
    && ! aie_notification_channel_enabled "discord" \
    && ! aie_notification_channel_enabled "webhook"; then
    log "No emergency notification channel enabled. Skipping."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  local candidate_summary=""
  local candidate_hash=""
  local note_json=""

  # Extract summaries to temp file to avoid nested process substitution issues
  local tmp_summaries
  tmp_summaries="$(mktemp)"
  extract_buffer_summaries > "$tmp_summaries"

  # Pre-reverse rumination file to avoid nested process substitution
  local tmp_rum_rev
  tmp_rum_rev="$(mktemp)"
  tac "$rum_file" > "$tmp_rum_rev" 2>/dev/null

  while IFS= read -r summary; do
    [[ -z "$summary" ]] && continue

    # Inline matching using pre-reversed rumination file
    local prefix
    prefix="${summary:0:60}"
    note_json="$(jq -c --arg p "$prefix" '
      .rumination_notes[]?
      | select(.content | type == "string")
      | select((.content | startswith($p)) or ($p | startswith(.content)))
    ' "$tmp_rum_rev" 2>/dev/null | head -1)"

    [[ -z "$note_json" ]] && continue

    if ! note_is_urgent_or_expiring "$note_json"; then
      continue
    fi

    candidate_hash="$(hash_text "$(printf '%s' "$note_json" | jq -c '{content,importance,expires,tags,urgent,urgency,flags}')")"
    if already_sent_hash "$candidate_hash"; then
      log "Duplicate alert candidate ignored."
      continue
    fi

    candidate_summary="$summary"
    break
  done < "$tmp_summaries"

  rm -f "$tmp_summaries" "$tmp_rum_rev"

  if [[ -z "$candidate_summary" ]]; then
    log "No emergency insight met threshold."
    log "=== Emergency surfacing END ==="
    exit 0
  fi

  if ! dispatch_alert "$candidate_summary"; then
    log "No notification channel succeeded."
    log "=== Emergency surfacing END ==="
    exit 1
  fi
  record_sent_hash "$candidate_hash"
  log "=== Emergency surfacing END ==="
}

main "$@"
