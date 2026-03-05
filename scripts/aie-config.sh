#!/usr/bin/env bash
# Shared configuration loader for AIE scripts.

if [[ -n "${AIE_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
readonly AIE_CONFIG_SH_LOADED=1

AIE_CONFIG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIE_REPO_ROOT="$(cd "${AIE_CONFIG_SCRIPT_DIR}/.." && pwd)"
AIE_DEFAULT_WORKSPACE="${OPENCLAW_WORKSPACE:-$AIE_REPO_ROOT}"
AIE_CONFIG_FILE="${AIE_CONFIG_FILE:-${AIE_DEFAULT_WORKSPACE}/config/aie.yaml}"

aie__load_json() {
  local workspace="$1"
  local config_file="$2"
  local python_output
  if ! python_output="$(
    WORKSPACE="$workspace" CONFIG_FILE="$config_file" python3 <<'PY'
import json
import os
from copy import deepcopy
from pathlib import Path

try:
    import yaml
except ModuleNotFoundError:
    raise SystemExit(
        "Missing Python dependency: PyYAML. Install it with: pip install pyyaml"
    )

workspace = os.path.abspath(os.path.expanduser(os.environ["WORKSPACE"]))
config_file = os.environ["CONFIG_FILE"]
home = os.path.expanduser("~")

defaults = {
    "workspace": workspace,
    "paths": {
        "workspace": workspace,
        "memory_dir": f"{workspace}/memory",
        "events_bus": f"{workspace}/memory/events/bus.jsonl",
        "sensor_state_dir": f"{workspace}/memory/sensor-state",
        "rumination_dir": f"{workspace}/memory/rumination",
        "followups_file": f"{workspace}/memory/rumination/follow-ups.jsonl",
        "observations_file": f"{workspace}/memory/observations.md",
        "preconscious_buffer": f"{workspace}/memory/preconscious-buffer.md",
        "logs_dir": f"{workspace}/logs",
        "health_data_dir": f"{workspace}/health/data",
        "env_file": f"{workspace}/.env",
        "perplexity_search_script": "",
        "openclaw_config": f"{home}/.openclaw/openclaw.json",
    },
    "profile": {
        "assistant_name": "Max",
        "primary_user_name": "the user",
        "household_context": "their household",
        "family_labels": [],
        "timezone": "UTC",
        "location_label": "",
    },
    "api": {
        "http_referer": "https://github.com/gavdalf/total-recall",
    },
    "models": {
        "rumination": "google/gemini-2.5-flash",
        "classification": "google/gemini-2.5-flash",
        "enrichment": "google/gemini-2.5-flash",
        "ambient_actions": "google/gemini-2.5-flash",
    },
    "connectors": {
        "high_importance_senders": [],  # empty by default; users add their own
        "calendar": {
            "enabled": False,
            "provider": "gog",
            "account": "",
            "calendar_id": "primary",
            "lookahead_days": 2,
            "max_events": 50,
            "keyring_password": "",
        },
        "todoist": {
            "enabled": False,
        },
        "ionos": {
            "enabled": False,
            "account": "ionos",
            "unread_limit": 10,
        },
        "gmail": {
            "enabled": False,
            "provider": "gog",
            "account": "",
            "unread_query": "is:unread",
            "max_messages": 10,
            "keyring_password": "",
        },
        "fitbit": {
            "enabled": False,
            "sleep_target_hours": 7.5,
            "short_sleep_minutes": 360,
            "great_sleep_minutes": 480,
            "watch_off_minutes": 180,
            "watch_uncertain_minutes": 300,
            "resting_hr_threshold": 65,
            "weight_target_lbs": 157,
            "steps_milestone": 10000,
        },
        "filewatch": {
            "enabled": True,
            "watch_files": [
                "{memory_dir}/observations.md",
                "{memory_dir}/{today}.md",
                "{memory_dir}/favorites.md",
            ],
        },
    },
    "notifications": {
        "quiet_hours": {
            "enabled": True,
            "timezone": "UTC",
            "start_hour": 22,
            "end_hour": 7,
        },
        "telegram": {
            "enabled": False,
            "bot_token": "",
            "chat_id": "",
        },
        "discord": {
            "enabled": False,
            "webhook_url": "",
        },
        "webhook": {
            "enabled": False,
            "url": "",
            "headers": {},
        },
    },
    "thresholds": {
        "rumination_cooldown_seconds": 1800,
        "rumination_staleness_seconds": 14400,
        "sensor_prune_hours": 48,
        "emergency": {
            "importance": 0.85,
            "expires_within_seconds": 14400,
            "max_alerts_per_day": 2,
        },
    },
    "ambient_actions": {
        "enabled": True,
        "max_actions": 5,
        "action_budget_seconds": 60,
        "weather_url": "https://wttr.in",
        "places": {
            "enabled": False,
            "default_lat": 0.0,
            "default_lng": 0.0,
            "default_limit": 3,
        },
        "tool_settings": {
            "calendar_lookup": {
                "gog_account": "",
                "gog_keyring_password": "",
            },
            "gmail_search": {
                "gog_account": "",
                "gog_keyring_password": "",
            },
            "gmail_read": {
                "gog_account": "",
                "gog_keyring_password": "",
            },
            "ionos_search": {
                "account": "ionos",
            },
            "fitbit_data": {
                "enabled": True,
            },
            "openrouter_balance": {
                "enabled": True,
            },
            "web_search": {
                "enabled": False,
                "script": "",
            },
            "places_lookup": {
                "enabled": False,
            },
        },
    },
}


def merge(base, override):
    for key, value in (override or {}).items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


config = deepcopy(defaults)
if os.path.exists(config_file):
    with open(config_file, "r", encoding="utf-8") as fh:
        loaded = yaml.safe_load(fh) or {}
    if not isinstance(loaded, dict):
        raise SystemExit("AIE config must be a YAML mapping at the top level")
    merge(config, loaded)

today = __import__("datetime").datetime.now(__import__("datetime").UTC).strftime("%Y-%m-%d")
config["workspace"] = os.path.abspath(os.path.expanduser(str(config.get("workspace") or workspace)))

def expand_path(value, base_dir):
    text = os.path.expandvars(os.path.expanduser(str(value)))
    candidate = Path(text)
    if not candidate.is_absolute():
        candidate = Path(base_dir) / candidate
    return str(candidate.resolve())

config["paths"]["workspace"] = expand_path(config["paths"].get("workspace", config["workspace"]), workspace)
config["workspace"] = config["paths"]["workspace"]
path_context = {
    "workspace": config["paths"]["workspace"],
    "memory_dir": expand_path(config["paths"]["memory_dir"], config["workspace"]),
    "today": today,
}

def format_value(value):
    if isinstance(value, str):
        return value.format(**path_context)
    if isinstance(value, list):
        return [format_value(item) for item in value]
    if isinstance(value, dict):
        return {key: format_value(item) for key, item in value.items()}
    return value

config = format_value(config)
for key, value in list(config["paths"].items()):
    if isinstance(value, str):
        formatted = value
        if key.endswith("_script") and not formatted:
            config["paths"][key] = ""
        else:
            config["paths"][key] = expand_path(formatted, config["workspace"])

print(json.dumps(config))
PY
  )"; then
    echo "$python_output" >&2
    return 1
  fi
  printf '%s\n' "$python_output"
}

aie_init() {
  export AIE_WORKSPACE="${AIE_WORKSPACE:-$AIE_DEFAULT_WORKSPACE}"
  export OPENCLAW_WORKSPACE="$AIE_WORKSPACE"

  if [[ -z "${AIE_CONFIG_JSON:-}" ]]; then
    AIE_CONFIG_JSON="$(aie__load_json "$AIE_WORKSPACE" "$AIE_CONFIG_FILE")"
    export AIE_CONFIG_JSON
  fi

  AIE_WORKSPACE="$(aie_get "workspace" "$AIE_WORKSPACE")"
  export AIE_WORKSPACE OPENCLAW_WORKSPACE="$AIE_WORKSPACE"

  AIE_MEMORY_DIR="$(aie_get "paths.memory_dir" "$AIE_WORKSPACE/memory")"
  AIE_ENV_FILE="$(aie_get "paths.env_file" "$AIE_WORKSPACE/.env")"
  AIE_LOGS_DIR="$(aie_get "paths.logs_dir" "$AIE_WORKSPACE/logs")"
  AIE_SENSOR_STATE_DIR="$(aie_get "paths.sensor_state_dir" "$AIE_WORKSPACE/memory/sensor-state")"
  export AIE_MEMORY_DIR AIE_ENV_FILE AIE_LOGS_DIR AIE_SENSOR_STATE_DIR
}

aie_get() {
  local path="$1"
  local default_value="${2-}"
  AIE_PATH="$path" AIE_DEFAULT="$default_value" python3 <<'PY'
import json
import os

data = json.loads(os.environ["AIE_CONFIG_JSON"])
path = os.environ["AIE_PATH"]
default = os.environ.get("AIE_DEFAULT", "")

value = data
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        value = default
        break

if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
elif isinstance(value, (dict, list)):
    print(json.dumps(value))
else:
    print(value)
PY
}

aie_bool() {
  [[ "$(aie_get "$1" "false")" == "true" ]]
}

aie_load_env() {
  if [[ -f "$AIE_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$AIE_ENV_FILE" 2>/dev/null || true
    set +a
  fi
}

aie_ensure_dirs() {
  mkdir -p "$AIE_MEMORY_DIR" "$AIE_LOGS_DIR" "$AIE_SENSOR_STATE_DIR"
}

aie_notification_channel_enabled() {
  local channel="$1"
  aie_bool "notifications.${channel}.enabled"
}

aie_sender_matches_importance() {
  local sender="$1"
  local senders_json
  senders_json="$(aie_get "connectors.high_importance_senders" "[]")"

  SENDER_TEXT="$sender" SENDERS_JSON="$senders_json" python3 <<'PY'
import json
import os
import sys

sender = os.environ.get("SENDER_TEXT", "").lower()
try:
    patterns = json.loads(os.environ.get("SENDERS_JSON", "[]"))
except json.JSONDecodeError:
    patterns = []

for pattern in patterns:
    if pattern and str(pattern).lower() in sender:
        sys.exit(0)

sys.exit(1)
PY
}

aie_is_quiet_hours() {
  local enabled timezone start_hour end_hour hour
  enabled="$(aie_get "notifications.quiet_hours.enabled" "true")"
  [[ "$enabled" == "true" ]] || return 1

  timezone="$(aie_get "notifications.quiet_hours.timezone" "$(aie_get "profile.timezone" "UTC")")"
  start_hour="$(aie_get "notifications.quiet_hours.start_hour" "22")"
  end_hour="$(aie_get "notifications.quiet_hours.end_hour" "7")"
  hour="$(TZ="$timezone" date +%H)"

  if ((10#$start_hour > 10#$end_hour)); then
    ((10#$hour >= 10#$start_hour || 10#$hour < 10#$end_hour))
  else
    ((10#$hour >= 10#$start_hour && 10#$hour < 10#$end_hour))
  fi
}
