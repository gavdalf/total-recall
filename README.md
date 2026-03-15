# Total Recall

Autonomous memory for OpenClaw-style agents.

Total Recall v2.0 keeps the existing v1.x stack intact:

- Observer
- Reflector
- Session Recovery
- Reactive Watcher
- Dream Cycle

It also adds the Ambient Intelligence Engine (AIE): a configurable sensor and rumination pipeline that can watch external systems, think about what changed, maintain a preconscious buffer, and surface urgent items.

Prerequisites: `python3`, `jq`, `curl`, and `PyYAML`.

Install PyYAML with:

```bash
python3 -m pip install PyYAML
# or on Debian/Ubuntu:
sudo apt install python3-yaml
```

`setup.sh` will verify all dependencies are present before continuing.

## Architecture

### v1.x memory loop

```text
Observer -> observations.md -> Reflector -> Dream Cycle -> session recovery / watcher
```

### v2.0 Ambient Intelligence Engine

```text
sensor-sweep
  -> enabled connectors emit events to memory/events/bus.jsonl
  -> rumination-engine reads new events and writes structured insights
  -> preconscious-select scores recent insights into memory/preconscious-buffer.md
  -> ambient-actions optionally enriches insights with read-only lookups
  -> emergency-surface pushes urgent alerts through configured channels
  -> buffer-inject sends the latest buffer back into the live session
```

The AIE flow is additive. None of the v1.x scripts are removed or replaced.

## Quick Start

### v1.x setup

```bash
git clone https://github.com/gavdalf/total-recall.git
cd total-recall
bash scripts/setup.sh
```

### AIE setup

1. Review [`config/aie.yaml`](config/aie.yaml).
2. Set `workspace` if you do not want to use the repo root.
3. Enable only the connectors and notification channels you actually use.
4. Add credentials to `./.env` or your shell environment.
5. Run a dry pass:

```bash
bash scripts/sensor-sweep.sh --dry-run
bash scripts/rumination-engine.sh --dry-run
bash scripts/preconscious-select.sh --dry-run
bash scripts/ambient-actions.sh --dry-run-actions
```

6. Schedule the AIE loop once the dry run looks correct:

```bash
*/15 * * * * OPENCLAW_WORKSPACE=/path/to/total-recall bash /path/to/total-recall/scripts/sensor-sweep.sh >> /path/to/total-recall/logs/sensor-sweep.log 2>&1
17,47 * * * * OPENCLAW_WORKSPACE=/path/to/total-recall bash /path/to/total-recall/scripts/preconscious-select.sh >> /path/to/total-recall/logs/rumination.log 2>&1
19,49 * * * * OPENCLAW_WORKSPACE=/path/to/total-recall bash /path/to/total-recall/scripts/emergency-surface.sh >> /path/to/total-recall/logs/emergency-surface.log 2>&1
```

Minimal first-run path:

- leave every connector disabled except `filewatch`
- keep notifications disabled
- set only the model IDs you want under `models`
- add the API key required by your chosen model provider

## AIE Configuration

All new AIE behavior is controlled by [`config/aie.yaml`](config/aie.yaml).

### Top-level sections

- `workspace`: root directory for memory, logs, health data, and `.env`
- `paths`: all file and directory locations used by AIE scripts
- `profile`: assistant/user labels and timezone used in prompts and quiet hours
- `api`: shared API metadata such as the outbound HTTP referer
- `models`: model IDs for rumination, classification, enrichment, and ambient actions
- `connectors`: per-connector enable flags, high-importance sender patterns, and connector-specific settings
- `notifications`: quiet hours plus Telegram, Discord, and generic webhook delivery
- `thresholds`: cooldowns, pruning windows, emergency thresholds
- `ambient_actions`: global action toggle plus read-only tool settings

### Connector toggles

Each connector now checks its own `enabled` flag before doing any work:

- `connectors.calendar.enabled`
- `connectors.todoist.enabled`
- `connectors.ionos.enabled`
- `connectors.gmail.enabled`
- `connectors.fitbit.enabled`
- `connectors.filewatch.enabled`

The orchestrator in [`scripts/sensor-sweep.sh`](scripts/sensor-sweep.sh) also skips disabled connectors.

### Model settings

Set your own model IDs here:

```yaml
models:
  rumination: <model-id>
  classification: <model-id>
  enrichment: <model-id>
  ambient_actions: <model-id>
```

The AIE scripts no longer hardcode user-specific model selections.

### Notification settings

```yaml
notifications:
  quiet_hours:
    enabled: true
    timezone: UTC
    start_hour: 22
    end_hour: 7
  telegram:
    enabled: false
    bot_token: ""
    chat_id: ""
  discord:
    enabled: false
    webhook_url: ""
  webhook:
    enabled: false
    url: ""
    headers: {}
```

`emergency-surface.sh` will only send through enabled channels. If no channel is enabled, it exits without error.

### Path settings

Everything that was previously tied to `~/clawd` is now configurable under `paths`, including:

- event bus
- sensor state
- rumination directory
- preconscious buffer
- health data
- log directory
- `.env` file
- optional web search helper path

### Threshold settings

Key defaults:

```yaml
thresholds:
  rumination_cooldown_seconds: 1800
  rumination_staleness_seconds: 14400
  sensor_prune_hours: 48
  emergency:
    importance: 0.85
    expires_within_seconds: 14400
    max_alerts_per_day: 2
```

### Connector reference

`calendar`

- `account`
- `calendar_id`
- `lookahead_days`
- `max_events`
- `keyring_password`

`gmail`

- `account`
- `query` (default `newer_than:3h`)
- `max_messages`
- `keyring_password`

`ionos`

- `account`
- `query` (`recent` or `unread`)
- `max_messages`

`connectors.scoring`

- `model`
- `batch_size`
- `cache_threshold`
- `sender_cache_file`

`connectors.high_importance_senders`

- list of sender substrings that should raise email importance (default: empty)
- add patterns for senders you care about most: your employer, accountant, school, doctor, bank, tax authority, etc.
- example: `["mycompany", "school", "hospital", "accountant", "bank"]`

`fitbit`

- `sleep_target_hours`
- `short_sleep_minutes`
- `great_sleep_minutes`
- `watch_off_minutes`
- `watch_uncertain_minutes`
- `resting_hr_threshold`
- `weight_target_lbs`
- `steps_milestone`

`filewatch`

- `watch_files`

### Ambient action reference

`ambient_actions`

- `enabled`
- `max_actions`
- `action_budget_seconds`
- `weather_url`
- `places.default_lat`
- `places.default_lng`
- `places.default_limit`

`ambient_actions.tool_settings`

- `calendar_lookup.gog_account`
- `calendar_lookup.gog_keyring_password`
- `gmail_search.gog_account`
- `gmail_search.gog_keyring_password`
- `gmail_read.gog_account`
- `gmail_read.gog_keyring_password`
- `ionos_search.account`
- `fitbit_data.enabled`
- `openrouter_balance.enabled`
- `web_search.enabled`
- `web_search.script`
- `places_lookup.enabled`

### Action resolution system

`ambient-actions.sh` reads enriched rumination insights and decides what to do with them. Five action types are supported, each with guardrails to prevent runaway behaviour:

| Action | Description | Guardrails |
|--------|-------------|------------|
| `ask` | Surfaces a question to the user via preconscious buffer | Max 3/run |
| `learn` | Stores a confirmed fact to `learned-facts.json` | Importance >= 0.7, dedup, max 5/run |
| `draft` | Prepares content for user review in `drafts/` | Importance >= 0.75, max 2/run |
| `notify` | Sends an urgent alert via emergency-surface | Importance >= 0.85, max 2/day, quiet hours respected |
| `remind` | Creates a time-based nudge in `reminders.jsonl` | Auto-surfaces when due, max 3/run |

#### Runtime files

The AIE creates several files in `memory/rumination/` during operation:

- `learned-facts.json` — facts the engine has confirmed and stored autonomously
- `reminders.jsonl` — pending time-based nudges
- `drafts/` — content prepared for user review (one `.md` file per draft)
- `cycle-state.json` — working memory: tracks lookups between cycles with TTL-based dedup (4hr window)

#### Agent startup

For best results, have your agent read `memory/rumination/learned-facts.json` and check `memory/rumination/drafts/` at session start. This surfaces what the AIE has learned and prepared between sessions.

## Existing v1.x Notes

The original observer / reflector / dream-cycle flow still works as before. The v1.x scripts continue to read their existing environment variables and paths. The new AIE config does not remove that compatibility layer.

See:

- [`dream-cycle/README.md`](dream-cycle/README.md)
- [`SKILL.md`](SKILL.md)
- [`docs/architecture.md`](docs/architecture.md)

## Repository Layout

| Path | Purpose |
|------|---------|
| `scripts/observer-agent.sh` | v1.x observer |
| `scripts/reflector-agent.sh` | v1.x reflector |
| `scripts/dream-cycle.sh` | v1.x nightly consolidation helper |
| `scripts/sensor-sweep.sh` | AIE connector orchestrator |
| `scripts/rumination-engine.sh` | AIE reasoning pass |
| `scripts/preconscious-select.sh` | buffer scorer/selector |
| `scripts/ambient-actions.sh` | read-only enrichment loop |
| `scripts/emergency-surface.sh` | urgent alert surfacing |
| `scripts/buffer-inject.sh` | inject buffer back into active session |
| `scripts/connectors/*.sh` | pluggable AIE sensors |
| `config/aie.yaml` | AIE runtime configuration |

## License

MIT. See [`LICENSE`](LICENSE).
