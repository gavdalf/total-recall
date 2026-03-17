# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Total Recall is an autonomous memory system for OpenClaw AI agents. It has two layers:

- **v1.x (Observer/Reflector/Dream Cycle)**: Session compression, consolidation, nightly archival
- **v2.x (Ambient Intelligence Engine / AIE)**: Sensor-driven pipeline that observes external data sources, ruminates via LLM, and surfaces insights

All scripts are bash. No build system, no traditional tests. Runtime data lives in `memory/`, logs in `logs/`.

## Running & Verification

```bash
# Syntax check (most useful verification)
bash -n scripts/rumination-engine.sh

# Dry-run the AIE pipeline stages
bash scripts/sensor-sweep.sh --dry-run
bash scripts/rumination-engine.sh --dry-run
bash scripts/preconscious-select.sh --dry-run
bash scripts/ambient-actions.sh --dry-run-actions

# v1.x scripts
bash scripts/observer-agent.sh
bash scripts/reflector-agent.sh
bash scripts/dream-cycle.sh preflight

# Setup (creates dirs, checks deps, installs services)
bash scripts/setup.sh
```

## Architecture

### AIE Pipeline (v2.x) — executed via cron every 15 min

```
sensor-sweep.sh → connectors/*.sh → memory/events/bus.jsonl
    → rumination-engine.sh (LLM reasoning, classification, tool execution, enrichment)
    → memory/rumination/YYYY-MM-DD.jsonl
    → preconscious-select.sh → memory/preconscious-buffer.md (top 5 insights)
    → emergency-surface.sh (urgent alerts via Telegram/Discord/webhook)
    → ambient-actions.sh (ask/learn/draft/notify/remind actions)
```

### v1.x Memory Loop — still active alongside AIE

```
Session JSONL → observer-agent.sh → memory/observations.md
    → reflector-agent.sh (consolidation when >8000 words)
    → dream-cycle.sh (nightly archival to memory/archive/)
```

### Key Shared Libraries

- **`_compat.sh`**: Cross-platform (Linux/macOS) helpers — portable flock, timeout, date, md5, jq ascii_upcase. All scripts source this.
- **`aie-config.sh`**: YAML config loader via embedded Python. Access values with `aie_get "path.key" "default"`.
- **`aie-tools.sh`**: Shared utilities — `extract_json`, `call_openrouter`, `run_tool`, JSON extraction with 5-level fallback.
- **`google-api.sh`**: Google API abstraction (`gog`/`gws`/custom CLI).

### Configuration

- **`config/aie.yaml`**: Primary config — models, connectors, thresholds, notifications, profile
- **`.env`**: API keys (`LLM_API_KEY` / `OPENROUTER_API_KEY`), not tracked in git

## Critical Patterns & Pitfalls

### Heredoc Assignment

**Never** use `$(cat << EOF ... EOF)` — bash parser breaks on complex content inside `$(...)`. Use:

```bash
IFS= read -r -d '' VAR << 'EOF'
...content...
EOF
VAR="${VAR%$'\n'}"  # read -d '' preserves trailing newline; $(cat) would strip it
```

For variable expansion in heredoc content, use unquoted delimiter:

```bash
IFS= read -r -d '' VAR << EOF
...content with ${VARS}...
EOF
VAR="${VAR%$'\n'}"
```

Note: `read -d ''` returns exit code 1 on EOF (no null byte in heredoc). This is harmless without `set -e` — do not add `|| true` unless the script uses `set -e`. Heredoc delimiters (`<<`, not `<<-`) must be at column 0 regardless of surrounding indentation.

### Shell Portability (macOS)

- No `flock` — use `portable_flock_exec` (mkdir-based locks)
- No `timeout` — use `portable_timeout` (perl fallback)
- `date` syntax differs — use `date_days_offset`, `date_days_ago`, `date_hours_ago`, `date_minutes_ago`
- `md5sum` doesn't exist — use `md5_hash` from `_compat.sh`
- `stat` flags differ — use `file_mtime`
- jq < 1.7 lacks `ascii_upcase` — check `$_jq_has_ascii_upcase` after calling `jq_check_ascii_upcase`

### Script Conventions

- Scripts use `set -uo pipefail` (not `-e`). Unset variables will error.
- File writes are atomic: write to tmpfile, then `mv`.
- Lock files use `.lock` suffix with `portable_flock_exec`.
- LLM responses are parsed via `extract_json` (5-level fallback chain).
- All connector scripts follow the pattern: read config → fetch data → emit events to `bus.jsonl`.

## Dependencies

- bash, python3 (3.9+), jq, curl, PyYAML (`pip install pyyaml`)
- Optional: inotify-tools (Linux watcher), fswatch (macOS watcher)
- LLM API via OpenRouter (default) or Anthropic direct
