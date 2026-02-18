---
name: total-recall
description: "The only memory skill that watches on its own. No database. No vectors. No manual saves. Just an LLM observer that compresses your conversations into prioritised notes, consolidates when they grow, and recovers anything missed. Five layers of redundancy, zero maintenance. ~$0.10/month. While other memory skills ask you to remember to remember, this one just pays attention."
metadata:
  openclaw:
    emoji: "🧠"
    requires:
      bins: ["jq", "curl"]
    env:
      - key: OPENROUTER_API_KEY
        label: "OpenRouter API key (for LLM calls)"
        required: true
    config:
      memorySearch:
        description: "Enable memory search on observations.md for cross-session recall"
---

# Total Recall — Autonomous Agent Memory

**The only memory skill that watches on its own.**

No database. No vectors. No manual saves. Just an LLM observer that compresses your conversations into prioritised notes, consolidates when they grow, and recovers anything missed. Five layers of redundancy, zero maintenance. ~$0.10/month.

While other memory skills ask you to remember to remember, this one just pays attention.

## Architecture

```
Layer 1: Observer (cron, every 15-30 min)
    ↓ compresses recent messages → observations.md
Layer 2: Reflector (auto-triggered when observations > 8000 words)
    ↓ consolidates, removes superseded info → 40-60% reduction
Layer 3: Session Recovery (runs on every /new or /reset)
    ↓ catches any session the Observer missed
Layer 4: Reactive Watcher (inotify daemon, Linux only)
    ↓ triggers Observer after 40+ new JSONL writes, 5-min cooldown
Layer 5: Pre-compaction hook (memoryFlush)
    ↓ emergency capture before OpenClaw compacts context
```

## What It Does

- **Observer** reads recent session transcripts (JSONL), sends them to an LLM (Gemini Flash), and appends compressed observations to `observations.md` with priority levels (🔴 high, 🟡 medium, 🟢 low)
- **Reflector** kicks in when observations grow too large, consolidating related items and dropping stale low-priority entries
- **Session Recovery** runs at session start, checks if the previous session was captured, and does an emergency observation if not
- **Reactive Watcher** watches the session directory with inotify so high-activity periods get captured faster than the cron interval
- **Pre-compaction hook** fires when OpenClaw is about to compact context, ensuring nothing is lost

## Quick Start

### 1. Install the skill
```bash
clawdhub install total-recall
```

### 2. Set your OpenRouter API key
Add to your `.env` or OpenClaw config:
```bash
OPENROUTER_API_KEY=sk-or-v1-xxxxx
```

### 3. Run the setup script
```bash
bash skills/total-recall/scripts/setup.sh
```

This will:
- Create the memory directory structure (`memory/`, `logs/`, backups)
- On Linux with inotify + systemd: install the reactive watcher service
- Print cron job and agent configuration instructions for you to add manually

### 4. Configure your agent to load observations

Add to your agent's workspace context (e.g., `MEMORY.md` or system prompt):
```
At session startup, read `memory/observations.md` for cross-session context.
```

Or use OpenClaw's `memoryFlush.systemPrompt` to inject a startup instruction.

## Platform Support

| Platform | Observer + Reflector + Recovery | Reactive Watcher |
|----------|-------------------------------|-----------------|
| Linux (Debian/Ubuntu/etc.) | ✅ Full support | ✅ With inotify-tools |
| macOS | ✅ Full support | ❌ Not available (cron-only) |

All core scripts use portable bash — `stat`, `date`, and `md5` commands are handled cross-platform via `_compat.sh`.

## Configuration

All scripts read from environment variables with sensible defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `OPENROUTER_API_KEY` | (required) | OpenRouter API key for LLM calls |
| `MEMORY_DIR` | `$OPENCLAW_WORKSPACE/memory` | Where observations.md lives |
| `SESSIONS_DIR` | `~/.openclaw/agents/main/sessions` | OpenClaw session transcripts |
| `OBSERVER_MODEL` | `google/gemini-2.5-flash` | Primary model for compression |
| `OBSERVER_FALLBACK_MODEL` | `google/gemini-2.0-flash-001` | Fallback if primary fails |
| `OBSERVER_LOOKBACK_MIN` | `15` | Minutes to look back (daytime) |
| `OBSERVER_MORNING_LOOKBACK_MIN` | `480` | Minutes to look back (before 8am) |
| `OBSERVER_LINE_THRESHOLD` | `40` | Lines before reactive trigger (Linux) |
| `OBSERVER_COOLDOWN_SECS` | `300` | Cooldown between reactive triggers (Linux) |
| `REFLECTOR_WORD_THRESHOLD` | `8000` | Words before reflector runs |
| `OPENCLAW_WORKSPACE` | `~/clawd` | Workspace root |

## Files Created

```
memory/
  observations.md          # The main observation log (loaded at startup)
  observation-backups/     # Reflector backups (last 10 kept)
  .observer-last-run       # Timestamp of last observer run
  .observer-last-hash      # Dedup hash of last processed messages
logs/
  observer.log
  reflector.log
  session-recovery.log
  observer-watcher.log
```

## Cron Jobs

The setup script creates these OpenClaw cron jobs:

| Job | Schedule | Description |
|-----|----------|-------------|
| `memory-observer` | Every 15 min | Compress recent conversation |
| `memory-reflector` | Hourly | Consolidate if observations are large |

## Reactive Watcher (Linux only)

The reactive watcher uses `inotifywait` to detect session activity and trigger the observer faster than cron alone. It requires Linux with `inotify-tools` installed.

On macOS, the watcher is not available — the 15-minute cron provides full coverage.

```bash
# Install inotify-tools (Debian/Ubuntu)
sudo apt install inotify-tools

# Check watcher status
systemctl --user status total-recall-watcher

# View logs
journalctl --user -u total-recall-watcher -f
```

## Cost

Using Gemini 2.5 Flash via OpenRouter:
- ~$0.05-0.15/month for typical usage (observer + reflector)
- ~15-30 cron runs/day, each processing a few hundred tokens

## How It Works (Technical)

### Observer
1. Finds recently modified session JSONL files
2. Filters out subagent/cron sessions
3. Extracts user + assistant messages from the lookback window
4. Deduplicates using MD5 hash comparison
5. Sends to LLM with the observer prompt (priority-based compression)
6. Appends result to `observations.md`
7. If observations > word threshold, triggers reflector

### Reflector
1. Backs up current observations
2. Sends entire log to LLM with consolidation instructions
3. Validates output is shorter than input (sanity check)
4. Replaces observations with consolidated version
5. Cleans old backups (keeps last 10)

### Session Recovery
1. Runs at every `/new` or `/reset`
2. Hashes recent lines of the last session file
3. Compares against stored hash from last observer run
4. If mismatch: runs observer in recovery mode (4-hour lookback)
5. Fallback: raw message extraction if observer fails

### Reactive Watcher
1. Uses `inotifywait` to monitor session directory
2. Counts JSONL writes to main session files only
3. After 40+ lines: triggers observer (with 5-min cooldown)
4. Resets counter when cron/external observer runs detected

## Customizing the Prompts

The observer and reflector system prompts are in `prompts/`:
- `prompts/observer-system.txt` — controls how conversations are compressed
- `prompts/reflector-system.txt` — controls how observations are consolidated

Edit these to match your agent's personality and priorities.

## Inspired By

This system is inspired by how human memory works during sleep — the hippocampus (observer) captures experiences, and during sleep consolidation (reflector), important memories are strengthened while noise is discarded.

Read more: [Your AI Has an Attention Problem](https://gavlahh.substack.com/p/your-ai-has-an-attention-problem)

*"Get your ass to Mars." — Well, get your agent's memory to work.*
