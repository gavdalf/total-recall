#!/usr/bin/env bash
# ionos-connector.sh — IONOS email sensor for AIE v2
# Two-gate scoring: sender cache + LLM content triage
# Usage: bash ionos-connector.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/_compat.sh"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUS="$(aie_get "paths.events_bus" "$AIE_WORKSPACE/memory/events/bus.jsonl")"
BUS_LOCK="${BUS}.lock"
STATE_FILE="$AIE_SENSOR_STATE_DIR/ionos.json"
SENDER_CACHE_FILE="$(aie_get "connectors.scoring.sender_cache_file" "$AIE_SENSOR_STATE_DIR/sender-cache.json")"
SENDER_CACHE_LOCK="${SENDER_CACHE_FILE}.lock"
DRY_RUN=""
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

IONOS_ACCOUNT="$(aie_get "connectors.ionos.account" "ionos")"
IONOS_QUERY_MODE="$(aie_get "connectors.ionos.query" "recent")"
IONOS_MAX_MESSAGES="$(aie_get "connectors.ionos.max_messages" "$(aie_get "connectors.ionos.unread_limit" "20")")"

SCORING_MODEL="$(aie_get "connectors.scoring.model" "google/gemini-3.1-flash-lite-preview")"
SCORING_BATCH_SIZE="$(aie_get "connectors.scoring.batch_size" "12")"
SCORING_CACHE_THRESHOLD="$(aie_get "connectors.scoring.cache_threshold" "3")"

HTTP_REFERER="$(aie_get "api.http_referer" "")"

HIMALAYA_TIMEOUT_SEC=40
CURL_TIMEOUT_SEC=45
LOCK_WAIT_SEC=10

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$SENDER_CACHE_FILE")" "$(dirname "$BUS")"

for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && DRY_RUN="true"; done

log() { echo "[ionos] $*"; }

run_timeout() {
  local seconds="$1"
  shift
  portable_timeout --kill-after=5 "$seconds" "$@"
}

TMP_FILES=()
make_tmp() {
  local f
  f=$(mktemp)
  TMP_FILES+=("$f")
  printf '%s\n' "$f"
}
cleanup() {
  if ((${#TMP_FILES[@]} > 0)); then
    rm -f "${TMP_FILES[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

json_object_or_empty() {
  local input="$1"
  if printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '%s\n' "$input"
  else
    printf '{}\n'
  fi
}

load_json_object_file() {
  local file="$1"
  local raw='{}'
  if [[ -s "$file" ]]; then
    raw=$(cat "$file" 2>/dev/null || true)
  fi
  json_object_or_empty "$raw"
}

sanitize_sender_cache() {
  local cache_json="$1"
  local threshold="$2"
  printf '%s' "$cache_json" | jq -c --argjson threshold "$threshold" '
    if type != "object" then
      {}
    else
      with_entries(
        .key |= (tostring | ascii_downcase)
        | .value |= (
            if type != "object" then
              empty
            else
              (try (.count | tonumber) catch -1) as $count
              | (try (.avg_score | tonumber) catch null) as $avg
              | if ($count | isfinite | not) or ($avg == null) or ($avg | isfinite | not) then
                  empty
                elif $count < $threshold then
                  empty
                else
                  {
                    count: ($count | floor),
                    avg_score: (if $avg < 0 then 0 elif $avg > 1 then 1 else $avg end),
                    last_updated: (.last_updated // "")
                  }
                end
            end
          )
      )
    end
  ' 2>/dev/null || printf '{}\n'
}

safe_write_json_atomic() {
  local target="$1"
  local data="$2"
  local tmp
  tmp="${target}.tmp.$$"
  if ! printf '%s\n' "$data" > "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  mv "$tmp" "$target"
}

aie_load_env

if ! aie_bool "connectors.ionos.enabled"; then
  log "SKIP disabled in config"
  exit 0
fi

if ! [[ "$SCORING_BATCH_SIZE" =~ ^[0-9]+$ ]] || ((SCORING_BATCH_SIZE < 1)); then
  SCORING_BATCH_SIZE=12
fi
if ! [[ "$SCORING_CACHE_THRESHOLD" =~ ^[0-9]+$ ]] || ((SCORING_CACHE_THRESHOLD < 1)); then
  SCORING_CACHE_THRESHOLD=3
fi
if ! [[ "$IONOS_MAX_MESSAGES" =~ ^[0-9]+$ ]] || ((IONOS_MAX_MESSAGES < 1)); then
  IONOS_MAX_MESSAGES=20
fi

health_check() {
  if ! run_timeout "$HIMALAYA_TIMEOUT_SEC" himalaya envelope list --account "$IONOS_ACCOUNT" --max-width 200 -s 1 >/dev/null 2>&1; then
    log "ERROR: health_check failed — himalaya ionos unreachable"
    return 1
  fi
  log "health_check OK"
}

emit_event() {
  local id="$1" type="$2" importance="$3" payload="$4"
  local event
  event=$(jq -cn \
    --arg id "$id" --arg type "$type" --arg timestamp "$NOW" \
    --argjson importance "$importance" --argjson payload "$payload" \
    '{id: $id, source: "ionos", type: $type, timestamp: $timestamp,
      expires_at: null, importance: $importance, actionable: true,
      payload: $payload, consumed: false, consumer_watermark: null}') || return 0

  if [[ -z "$DRY_RUN" ]]; then
    if ! PORTABLE_FLOCK_WAIT="$LOCK_WAIT_SEC" portable_flock_exec "$BUS_LOCK" "echo '$event' >> '$BUS'"; then
      log "WARN: Failed to write event to bus (lock or IO error)"
      return 0
    fi
    log "Emitted: $type -> $id"
  else
    log "[DRY-RUN] Would emit: $type | $(printf '%s' "$payload" | jq -r '.subject // "?"' 2>/dev/null || echo '?')"
  fi
}

extract_sender_domain() {
  local from="$1"
  local email
  local domain
  email=$(printf '%s' "$from" | grep -Eoi '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' | head -n1 || true)
  [[ -z "$email" ]] && { echo ""; return; }
  domain="${email#*@}"
  printf '%s\n' "$domain" | tr '[:upper:]' '[:lower:]'
}

strip_html_to_text() {
  local input="$1"
  printf '%s' "$input" \
    | tr '\r' '\n' \
    | tr -d '\000' \
    | sed -E 's/<(script|style)[^>]*>.*<\/\1>//gI' \
    | sed -E 's/<br[[:space:]]*\/?[[:space:]]*>/\n/gI' \
    | sed -E 's/<\/p>/\n/gI' \
    | sed -E 's/<[^>]+>/ /g' \
    | sed -E "s/&nbsp;/ /g; s/&amp;/\\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/\"/g; s/&#39;/'/g" \
    | awk 'NF{print}'
}

trim_ws() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

parse_ionos_header_field() {
  local field="$1"
  local headers="$2"
  printf '%s\n' "$headers" | awk -v key="$field" '
    BEGIN { IGNORECASE=1 }
    $0 ~ "^" key ":[[:space:]]*" {
      sub("^" key ":[[:space:]]*", "")
      print
      exit
    }
  '
}

ionos_fetch_message_raw() {
  local msg_id="$1"
  run_timeout "$HIMALAYA_TIMEOUT_SEC" himalaya message read "$msg_id" --account "$IONOS_ACCOUNT" 2>/dev/null || true
}

ionos_fetch_message_headers() {
  local msg_id="$1"
  local raw headers unfolded subject from date_field
  raw=$(ionos_fetch_message_raw "$msg_id")
  raw=$(printf '%s' "$raw" | head -c 250000)
  [[ -z "$raw" ]] && { printf '{}\n'; return; }

  headers=$(printf '%s\n' "$raw" | awk 'BEGIN{done=0} {if(done==0){print}} /^$/{done=1; exit}')
  unfolded=$(printf '%s\n' "$headers" | sed ':a;N;$!ba;s/\n[ \t]+/ /g')

  subject=$(parse_ionos_header_field "Subject" "$unfolded" | tr -d '\000' | cut -c1-200)
  from=$(parse_ionos_header_field "From" "$unfolded" | tr -d '\000' | cut -c1-180)
  date_field=$(parse_ionos_header_field "Date" "$unfolded" | tr -d '\000' | cut -c1-100)

  jq -cn --arg subject "${subject:-No subject}" --arg from "$from" --arg date "$date_field" \
    '{subject:$subject,from:$from,date:$date}'
}

ionos_fetch_body_excerpt() {
  local msg_id="$1"
  local raw body

  raw=$(ionos_fetch_message_raw "$msg_id")
  raw=$(printf '%s' "$raw" | head -c 300000)
  body=$(printf '%s' "$raw" | sed '1,/^$/d')
  [[ -z "$body" ]] && body="$raw"

  strip_html_to_text "$body" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | cut -c1-500
}

regex_fallback_score() {
  local from="$1"
  local importance="0.5"
  if aie_sender_matches_importance "$from"; then
    importance="0.8"
  fi
  printf '%s' "$from" | grep -qiE "(noreply|newsletter|marketing|notification|promo)" && importance="0.45"
  printf '%s\n' "$importance"
}

sender_gate_score() {
  local domain="$1"
  local cache_json="$2"
  local threshold="$3"
  local count="0"
  local avg=""

  [[ -z "$domain" ]] && { echo "|"; return; }

  count=$(printf '%s' "$cache_json" | jq -r --arg d "$domain" 'try (.[$d].count // 0 | tonumber | floor) catch 0' 2>/dev/null || echo 0)
  avg=$(printf '%s' "$cache_json" | jq -r --arg d "$domain" 'try (.[$d].avg_score // empty | tonumber) catch empty' 2>/dev/null || echo "")

  if [[ "$count" =~ ^[0-9]+$ ]] && (( count >= threshold )) && [[ "$avg" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    if awk -v a="$avg" 'BEGIN{exit !(a >= 0.7)}'; then
      echo "gate1_high|$avg"
      return
    fi
    if awk -v a="$avg" 'BEGIN{exit !(a <= 0.3)}'; then
      echo "gate1_low|$avg"
      return
    fi
  fi

  echo "|"
}

cache_updates_add() {
  local updates_json="$1"
  local domain="$2"
  local score="$3"
  [[ -z "$domain" ]] && { printf '%s\n' "$updates_json"; return; }

  printf '%s' "$updates_json" | jq -c --arg d "$domain" --argjson s "$score" '
    . as $root
    | ($root[$d] // {sum:0, count:0}) as $entry
    | $root + {
        ($d): {
          sum: ($entry.sum + $s),
          count: ($entry.count + 1)
        }
      }
  ' 2>/dev/null || printf '%s\n' "$updates_json"
}

apply_cache_updates() {
  local cache_json="$1"
  local updates_json="$2"

  printf '%s' "$cache_json" | jq -c --argjson updates "$updates_json" --arg ts "$NOW" '
    if ($updates | type) != "object" then
      .
    else
      reduce ($updates | to_entries[]) as $u (.;
        ($u.key) as $d
        | ($u.value.count // 0) as $inc_count
        | ($u.value.sum // 0) as $inc_sum
        | if ($inc_count <= 0) then
            .
          else
            (.[$d] // {avg_score:0, count:0, last_updated:$ts}) as $entry
            | ($entry.count + $inc_count) as $new_count
            | ((($entry.avg_score * $entry.count) + $inc_sum) / $new_count) as $new_avg
            | . + {
                ($d): {
                  avg_score: (if $new_avg < 0 then 0 elif $new_avg > 1 then 1 else $new_avg end),
                  count: $new_count,
                  last_updated: $ts
                }
              }
          end
      )
    end
  ' 2>/dev/null || printf '%s\n' "$cache_json"
}

persist_sender_cache_updates() {
  local updates_json="$1"
  [[ "$updates_json" == "{}" ]] && return 0

  if [[ -n "$DRY_RUN" ]]; then
    return 0
  fi

  PORTABLE_FLOCK_WAIT="$LOCK_WAIT_SEC" portable_flock_exec "$SENDER_CACHE_LOCK" '
    current=$(load_json_object_file "'"$SENDER_CACHE_FILE"'")
    sanitized=$(sanitize_sender_cache "$current" "'"$SCORING_CACHE_THRESHOLD"'")
    merged=$(apply_cache_updates "$sanitized" "'"$updates_json"'")
    safe_write_json_atomic "'"$SENDER_CACHE_FILE"'" "$merged"
  '
}

extract_llm_content_array() {
  local content="$1"
  local extracted=""

  if printf '%s' "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$content"
    return 0
  fi

  extracted=$(printf '%s' "$content" | tr '\n' ' ' | sed -E 's/^[^[]*//; s/[^]]*$//' || true)
  [[ -z "$extracted" ]] && return 1

  if printf '%s' "$extracted" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$extracted"
    return 0
  fi

  return 1
}

call_openrouter_batch() {
  local batch_json="$1"
  local prompt
  local request
  local response
  local content
  local arr
  local curl_headers

  [[ -z "${OPENROUTER_API_KEY:-}" ]] && return 1

  prompt='Score each email 0.0-1.0 for importance to the user. Consider: finances, health, deliveries, legal/government, family, school, career, deadlines, security notices, account access, and urgent service interruptions. Return ONLY a JSON array of objects with msg_id and score fields.'

  request=$(jq -cn \
    --arg model "$SCORING_MODEL" \
    --arg prompt "$prompt" \
    --argjson emails "$batch_json" \
    '{
      model: $model,
      temperature: 0,
      messages: [
        {role: "system", content: "You are an email triage scorer."},
        {role: "user", content: ($prompt + "\\n\\nEmails JSON:\\n" + ($emails | tojson))}
      ]
    }') || return 1

  curl_headers=(-H "Authorization: Bearer ${OPENROUTER_API_KEY}" -H "Content-Type: application/json")
  if [[ -n "$HTTP_REFERER" ]]; then
    curl_headers+=(-H "HTTP-Referer: ${HTTP_REFERER}" -H "X-Title: Total Recall")
  fi

  response=$(run_timeout "$CURL_TIMEOUT_SEC" curl -sS --max-time "$CURL_TIMEOUT_SEC" https://openrouter.ai/api/v1/chat/completions \
    "${curl_headers[@]}" \
    -d "$request" 2>/dev/null || true)

  [[ -z "$response" ]] && return 1

  content=$(printf '%s' "$response" | jq -r 'try .choices[0].message.content // empty catch empty' 2>/dev/null || true)
  [[ -z "$content" ]] && return 1

  arr=$(extract_llm_content_array "$content") || return 1

  printf '%s' "$arr" | jq -c '
    if type != "array" then
      []
    else
      [ .[]
        | {
            msg_id: (try (.msg_id | tostring) catch ""),
            score: (try (.score | tonumber) catch null)
          }
        | select(.msg_id != "" and .score != null and (.score | isfinite))
        | .score = (if .score < 0 then 0 elif .score > 1 then 1 else .score end)
      ]
    end
  ' 2>/dev/null
}

fetch_envelopes_json() {
  local raw

  raw=$(run_timeout "$HIMALAYA_TIMEOUT_SEC" himalaya envelope list --account "$IONOS_ACCOUNT" --max-width 500 -s "$IONOS_MAX_MESSAGES" --output json 2>/dev/null || true)
  if [[ -n "$raw" ]] && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$raw" | jq -c '
      [ .[]
        | {
            id: (try (.id // .ID // "" | tostring) catch ""),
            flags: (try (.flags // .Flags // "" | tostring) catch ""),
            subject: (try (.subject // .Subject // "No subject" | tostring) catch "No subject"),
            from: (
              try (
                if (.from | type) == "array" then (.from | join(", "))
                elif (.from | type) == "object" then (.from | tostring)
                else (.from // .sender // .From // "" | tostring)
                end
              ) catch ""
            ),
            date: (try (.date // .Date // "" | tostring) catch "")
          }
      ]
    ' 2>/dev/null || echo '[]'
    return 0
  fi

  local table
  table=$(run_timeout "$HIMALAYA_TIMEOUT_SEC" himalaya envelope list --account "$IONOS_ACCOUNT" --max-width 500 -s "$IONOS_MAX_MESSAGES" 2>/dev/null || true)
  [[ -z "$table" ]] && { echo '[]'; return 1; }

  local tmp_lines line n i
  local id flags date_field from subject part_trimmed
  tmp_lines=$(make_tmp)
  : > "$tmp_lines"

  while IFS= read -r line; do
    [[ "$line" != *"|"* ]] && continue
    [[ "$line" =~ ^[[:space:]]*[-+┌┬┐├┼┤└┴┘─]+[[:space:]]*$ ]] && continue

    IFS='|' read -r -a parts <<< "$line"
    n=${#parts[@]}
    (( n < 6 )) && continue

    id=$(trim_ws "${parts[1]}")
    flags=$(trim_ws "${parts[2]}")
    date_field=$(trim_ws "${parts[$((n-2))]}")
    from=$(trim_ws "${parts[$((n-3))]}")

    subject=""
    i=3
    while (( i <= n-4 )); do
      part_trimmed=$(trim_ws "${parts[$i]}")
      if [[ -z "$subject" ]]; then
        subject="$part_trimmed"
      else
        subject+=" | $part_trimmed"
      fi
      i=$((i+1))
    done

    [[ "$id" == "" || "$id" == "ID" ]] && continue
    [[ "$id" =~ ^[-─]+$ ]] && continue

    jq -cn --arg id "$id" --arg flags "$flags" --arg subject "${subject:-No subject}" --arg from "$from" --arg date "$date_field" \
      '{id:$id,flags:$flags,subject:$subject,from:$from,date:$date}' >> "$tmp_lines"
  done <<< "$table"

  jq -s '.' "$tmp_lines" 2>/dev/null || echo '[]'
}

if ! health_check; then
  exit 0
fi

PREV_STATE=$(load_json_object_file "$STATE_FILE")
NEW_STATE="$PREV_STATE"
COUNT=0

SENDER_CACHE=$(sanitize_sender_cache "$(load_json_object_file "$SENDER_CACHE_FILE")" "$SCORING_CACHE_THRESHOLD")
CACHE_UPDATES='{}'

ENVELOPES=$(fetch_envelopes_json 2>/dev/null || echo '[]')
ENVELOPE_COUNT=$(printf '%s' "$ENVELOPES" | jq -r 'length' 2>/dev/null || echo 0)
if ! [[ "$ENVELOPE_COUNT" =~ ^[0-9]+$ ]] || (( ENVELOPE_COUNT == 0 )); then
  log "No envelopes returned or parse failed"
  exit 0
fi

TMP_ITEMS=$(make_tmp)
TMP_ENV_ITEMS=$(make_tmp)
printf '%s\n' "$ENVELOPES" | jq -c '.[]?' 2>/dev/null > "$TMP_ENV_ITEMS" || true

while IFS= read -r env_item; do
  id=$(printf '%s' "$env_item" | jq -r 'try .id // empty catch empty' 2>/dev/null || true)
  [[ -z "$id" ]] && continue

  bus_id="ionos-${id}"
  prev=$(printf '%s' "$PREV_STATE" | jq -r --arg id "$bus_id" 'try .[$id] // "" catch ""' 2>/dev/null || true)
  [[ -n "$prev" ]] && continue

  flags=$(printf '%s' "$env_item" | jq -r 'try .flags // "" catch ""' 2>/dev/null || true)
  if [[ "$IONOS_QUERY_MODE" == "unread" ]] && printf '%s' "$flags" | grep -qi "seen"; then
    continue
  fi

  subject=$(printf '%s' "$env_item" | jq -r 'try .subject // "No subject" catch "No subject"' 2>/dev/null | tr -d '\000' | cut -c1-200)
  from=$(printf '%s' "$env_item" | jq -r 'try .from // "" catch ""' 2>/dev/null | tr -d '\000' | cut -c1-180)
  date_field=$(printf '%s' "$env_item" | jq -r 'try .date // "" catch ""' 2>/dev/null | tr -d '\000' | cut -c1-100)

  if [[ -z "$from" || -z "$subject" || "$subject" == "No subject" ]]; then
    hdr=$(ionos_fetch_message_headers "$id")
    hdr_subject=$(printf '%s' "$hdr" | jq -r '.subject // empty' 2>/dev/null || true)
    hdr_from=$(printf '%s' "$hdr" | jq -r '.from // empty' 2>/dev/null || true)
    hdr_date=$(printf '%s' "$hdr" | jq -r '.date // empty' 2>/dev/null || true)
    [[ -n "$hdr_subject" ]] && subject=$(printf '%s' "$hdr_subject" | cut -c1-200)
    [[ -n "$hdr_from" ]] && from=$(printf '%s' "$hdr_from" | cut -c1-180)
    [[ -n "$hdr_date" ]] && date_field=$(printf '%s' "$hdr_date" | cut -c1-100)
  fi

  domain=$(extract_sender_domain "$from")
  gate_result=$(sender_gate_score "$domain" "$SENDER_CACHE" "$SCORING_CACHE_THRESHOLD")
  gate="${gate_result%%|*}"
  gate_score="${gate_result#*|}"

  if [[ -n "$gate" && -n "$gate_score" ]]; then
    log "Gate1 cache hit [$gate]: $id domain=$domain score=$gate_score"
    jq -cn \
      --arg bus_id "$bus_id" --arg msg_id "$id" --arg subject "$subject" --arg from "$from" --arg date "$date_field" \
      --arg domain "$domain" --arg gate "$gate" --argjson importance "$gate_score" \
      '{bus_id:$bus_id,msg_id:$msg_id,subject:$subject,from:$from,date:$date,domain:$domain,gate:$gate,importance:$importance}' >> "$TMP_ITEMS"
  else
    body_excerpt=$(ionos_fetch_body_excerpt "$id")
    log "Gate1 miss -> Gate2 queued: $id domain=${domain:-unknown}"
    jq -cn \
      --arg bus_id "$bus_id" --arg msg_id "$id" --arg subject "$subject" --arg from "$from" --arg date "$date_field" \
      --arg domain "$domain" --arg body_excerpt "$body_excerpt" \
      '{bus_id:$bus_id,msg_id:$msg_id,subject:$subject,from:$from,date:$date,domain:$domain,gate:"gate2_pending",body_excerpt:$body_excerpt}' >> "$TMP_ITEMS"
  fi
done < "$TMP_ENV_ITEMS"

PENDING_BATCH=$(jq -s '[.[] | select(.gate == "gate2_pending") | {msg_id, sender: .from, subject, body: .body_excerpt}]' "$TMP_ITEMS" 2>/dev/null || echo '[]')
PENDING_COUNT=$(printf '%s' "$PENDING_BATCH" | jq -r 'length' 2>/dev/null || echo 0)

SCORE_MAP='{}'
if [[ "$PENDING_COUNT" =~ ^[0-9]+$ ]] && (( PENDING_COUNT > 0 )); then
  log "Gate2 LLM batch scoring $PENDING_COUNT email(s)"
  offset=0
  while (( offset < PENDING_COUNT )); do
    chunk=$(printf '%s' "$PENDING_BATCH" | jq -c --argjson o "$offset" --argjson n "$SCORING_BATCH_SIZE" '.[$o:($o+$n)]' 2>/dev/null || echo '[]')
    chunk_count=$(printf '%s' "$chunk" | jq -r 'length' 2>/dev/null || echo 0)

    if [[ "$chunk_count" =~ ^[0-9]+$ ]] && (( chunk_count > 0 )); then
      if LLM_SCORES=$(call_openrouter_batch "$chunk"); then
        chunk_map=$(printf '%s' "$LLM_SCORES" | jq -c '
          reduce .[] as $i ({}; .[$i.msg_id] = $i.score)
        ' 2>/dev/null || echo '{}')
        SCORE_MAP=$(jq -cn --argjson a "$SCORE_MAP" --argjson b "$chunk_map" '$a + $b' 2>/dev/null || echo "$SCORE_MAP")
      else
        log "Gate2 LLM call failed for chunk offset=$offset; regex fallback will be used"
      fi
    fi

    offset=$((offset + SCORING_BATCH_SIZE))
  done
fi

while IFS= read -r item; do
  [[ -z "$item" ]] && continue

  bus_id=$(printf '%s' "$item" | jq -r 'try .bus_id // empty catch empty' 2>/dev/null || true)
  msg_id=$(printf '%s' "$item" | jq -r 'try .msg_id // empty catch empty' 2>/dev/null || true)
  subject=$(printf '%s' "$item" | jq -r 'try .subject // "No subject" catch "No subject"' 2>/dev/null || true)
  from=$(printf '%s' "$item" | jq -r 'try .from // "" catch ""' 2>/dev/null || true)
  date_field=$(printf '%s' "$item" | jq -r 'try .date // "" catch ""' 2>/dev/null || true)
  domain=$(printf '%s' "$item" | jq -r 'try .domain // "" catch ""' 2>/dev/null || true)
  gate=$(printf '%s' "$item" | jq -r 'try .gate // "" catch ""' 2>/dev/null || true)

  [[ -z "$bus_id" || -z "$msg_id" ]] && continue

  importance=""
  if [[ "$gate" == "gate1_high" || "$gate" == "gate1_low" ]]; then
    importance=$(printf '%s' "$item" | jq -r 'try .importance // 0.5 catch 0.5' 2>/dev/null || echo "0.5")
  else
    llm_score=$(printf '%s' "$SCORE_MAP" | jq -r --arg id "$msg_id" 'try .[$id] // empty catch empty' 2>/dev/null || true)
    if [[ -n "$llm_score" ]]; then
      importance="$llm_score"
      gate="gate2_llm"
      SENDER_CACHE=$(apply_cache_updates "$SENDER_CACHE" "$(cache_updates_add '{}' "$domain" "$importance")")
      CACHE_UPDATES=$(cache_updates_add "$CACHE_UPDATES" "$domain" "$importance")
    else
      importance=$(regex_fallback_score "$from")
      gate="gate2_regex_fallback"
    fi
  fi

  if ! [[ "$importance" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    importance="0.5"
  fi

  payload=$(jq -cn \
    --arg subject "$subject" --arg from "$from" --arg date "$date_field" --arg msg_id "$msg_id" \
    '{subject: $subject, from: $from, date: $date, msg_id: $msg_id}')

  log "Scored: msg=$msg_id gate=$gate score=$importance"
  if awk -v s="$importance" 'BEGIN{exit !(s > 0.4)}'; then
    emit_event "$bus_id" "email_important" "$importance" "$payload"
    COUNT=$((COUNT + 1))
  fi

  NEW_STATE=$(printf '%s' "$NEW_STATE" | jq -c --arg id "$bus_id" --arg ts "$NOW" 'try .[$id] = $ts catch .' 2>/dev/null || echo "$NEW_STATE")
done < "$TMP_ITEMS"

if [[ -z "$DRY_RUN" ]]; then
  if ! safe_write_json_atomic "$STATE_FILE" "$NEW_STATE"; then
    log "WARN: Failed to persist state file: $STATE_FILE"
  fi

  if ! persist_sender_cache_updates "$CACHE_UPDATES"; then
    log "WARN: Failed to persist sender cache updates"
  fi
fi

log "IONOS connector complete. Emitted $COUNT event(s)."
