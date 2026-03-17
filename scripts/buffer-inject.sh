#!/usr/bin/env bash
# buffer-inject.sh — AIE v2 mid-session insight injection
# Runs after preconscious-select.sh, compares buffer hash with last injection,
# and fires a system event into the main session if the buffer has meaningfully changed.
#
# Cron: xx:37 every 2hrs (2 min after preconscious-select at xx:35)
#
# Uses: openclaw system event --text "..." --mode now

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_compat.sh"
source "$SCRIPT_DIR/aie-config.sh"
aie_init

BUFFER_FILE="$(aie_get "paths.preconscious_buffer" "$AIE_WORKSPACE/memory/preconscious-buffer.md")"
RUMINATION_DIR="$(aie_get "paths.rumination_dir" "$AIE_WORKSPACE/memory/rumination")"
STATE_FILE="$AIE_MEMORY_DIR/.buffer-inject-state.json"
LOG_FILE="$AIE_LOGS_DIR/buffer-inject.log"
LOCK_FILE="$AIE_MEMORY_DIR/.buffer-inject.lock"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [buffer-inject] $*" | tee -a "$LOG_FILE"
}

load_env() {
  aie_load_env
}

is_quiet_hours() {
  aie_is_quiet_hours
}

get_gateway_token() {
  # Read directly from config file — avoids CLI arg leakage
  local openclaw_config
  openclaw_config="$(aie_get "paths.openclaw_config" "$HOME/.openclaw/openclaw.json")"
  if [[ -f "$openclaw_config" ]]; then
    jq -r '.gateway.auth.token // empty' "$openclaw_config" 2>/dev/null || true
  fi
}

get_buffer_content_hash() {
  # FIX: Hash only the insight lines, stripping the timestamp header
  # so that unchanged insights don't look "new" just because the timestamp changed
  if [[ -f "$BUFFER_FILE" ]]; then
    grep -E '^[🧠📋👁️🚨📝💭]' "$BUFFER_FILE" 2>/dev/null | sha256sum | awk '{print $1}'
  else
    echo "none"
  fi
}

get_last_injected_hash() {
  if [[ -f "$STATE_FILE" ]]; then
    jq -r '.last_hash // "none"' "$STATE_FILE" 2>/dev/null || echo "none"
  else
    echo "none"
  fi
}

save_state() {
  local hash="$1"
  local tmp
  tmp="$(mktemp)"
  jq -n \
    --arg hash "$hash" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{last_hash: $hash, last_injected_at: $ts}' > "$tmp" && mv "$tmp" "$STATE_FILE" || {
      log "WARN: Failed to save state file"
    }
}

extract_top_insights() {
  # FIX: Match all emoji patterns that preconscious-select.sh produces
  grep -E '^[🧠📋👁️🚨📝💭]' "$BUFFER_FILE" 2>/dev/null | head -5 | while IFS= read -r line; do
    echo "  $line"
  done
}

main() {
  log "=== Buffer inject START ==="

  # FIX: Load env FIRST before reading any env-sourced variables
  load_env

  # FIX: Set gateway vars AFTER load_env so .env values are picked up
  local GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
  local GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-ws://127.0.0.1:18789}"

  if is_quiet_hours; then
    log "Quiet hours active. Skipping."
    log "=== Buffer inject END ==="
    exit 0
  fi

  if [[ ! -f "$BUFFER_FILE" ]]; then
    log "No buffer file at $BUFFER_FILE. Skipping."
    log "=== Buffer inject END ==="
    exit 0
  fi

  # FIX: Use flock to prevent concurrent runs from double-sending
  if ! portable_flock_try "$LOCK_FILE"; then
    log "Another instance is running. Skipping."
    log "=== Buffer inject END ==="
    exit 0
  fi
  trap 'portable_flock_release "$LOCK_FILE"' EXIT

  local current_hash last_hash
  current_hash="$(get_buffer_content_hash)"
  last_hash="$(get_last_injected_hash)"

  if [[ "$current_hash" == "$last_hash" ]]; then
    log "Buffer insights unchanged since last injection. Skipping."
    log "=== Buffer inject END ==="
    exit 0
  fi

  log "Buffer insights changed (old=${last_hash:0:8}..., new=${current_hash:0:8}...). Preparing injection..."

  local insights
  insights="$(extract_top_insights)"

  if [[ -z "$insights" ]]; then
    log "No insights extracted from buffer. Skipping."
    log "=== Buffer inject END ==="
    exit 0
  fi

  local event_text
  event_text="$(printf '🧠 AIE Mid-Session Update — New insights from latest rumination:\n\n%s\n\nReview memory/preconscious-buffer.md for full context. Surface anything relevant naturally.' "$insights")"

  # FIX: Token via env var to avoid ps-visible CLI arg leakage
  # Priority: OPENCLAW_GATEWAY_TOKEN env var > config file fallback
  local token="${GATEWAY_TOKEN:-}"
  if [[ -z "$token" ]]; then
    token="$(get_gateway_token)"
  fi

  local cmd_args=(
    system event
    --text "$event_text"
    --mode now
    --timeout 15000
  )

  if [[ -z "$token" ]]; then
    log "ERROR: No gateway token found in env or config. Cannot inject."
    log "=== Buffer inject END ==="
    exit 1
  fi

  log "Sending system event to main session..."
  local result exit_code=0
  # Pass token via OPENCLAW_GATEWAY_TOKEN env var — invisible to ps
  result="$(OPENCLAW_GATEWAY_TOKEN="$token" openclaw "${cmd_args[@]}" 2>&1)" || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log "WARN: System event failed (exit $exit_code): $result"
    log "=== Buffer inject END ==="
    exit 1
  fi

  log "System event sent successfully."
  save_state "$current_hash"
  log "State updated. Injection complete."
  log "=== Buffer inject END ==="
}

main "$@"
