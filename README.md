# OpenClaw Memory — Five-Layer Memory Protection

> Your AI has the same attention problem you do — and we fixed it the same way your brain does.

A drop-in memory system for [OpenClaw](https://openclaw.ai) agents that eliminates post-compaction amnesia through continuous observation, reflection, and reactive triggers.

## The Problem

OpenClaw's context compaction is lossy by design. It takes 200k tokens of conversation and crushes it to ~10-20k tokens of summary. Specifics get lost: exact numbers, subtle decisions, the reasoning behind choices.

## The Solution

Five layers of protection that work **with** (not against) native compaction:

1. ⏰ **Observer Cron** (every 15 min) — Continuously extracts durable facts from session transcripts
2. 🎯 **Reactive Watcher** (inotify/fswatch) — Fires within seconds during heavy conversations
3. 🛡️ **Pre-Compaction Hook** (memoryFlush) — Emergency capture right before compaction fires
4. 📝 **Session Startup** — Loads all saved memory at the start of every new session
5. 🔄 **Session Recovery** (startup check) — Catches any observations missed by the watcher during manual resets

**Cost:** ~$0.10-0.20/month using Gemini 2.5 Flash via OpenRouter.
**Context overhead:** ~4.5% of window (saves 20-30% that would be wasted re-explaining).

## Quick Start

### Option A: Let your agent install it (recommended) 🤖

Just tell your OpenClaw agent:

> Read https://raw.githubusercontent.com/gavdalf/openclaw-memory/main/INSTALL-AGENT.md and follow the instructions to install OpenClaw Memory.

Your agent will read the guide, install the scripts, configure the cron jobs, and set up the pre-compaction hooks — all by itself. You just approve the steps.

### Option B: Install manually

```bash
# 1. Clone this repo
git clone https://github.com/gavdalf/openclaw-memory.git
cd openclaw-memory

# 2. Run the installer
./install.sh

# 3. Done — memory system is active
```

## Architecture

```
Session JSONL files (raw transcripts)
    ↓ (every 15 min + reactive triggers + pre-compaction + session recovery)
Observer Agent (compress via LLM → observations.md)
    ↓ (when observations > 8000 words)
Reflector Agent (consolidate → compressed observations.md)
    ↓ (session startup)
Agent loads: observations.md + favorites.md + daily memory
```

See [docs/architecture.md](docs/architecture.md) for the full breakdown.

## Requirements

- OpenClaw (any recent version)
- bash, jq, curl
- An LLM API key (OpenRouter recommended — Gemini 2.5 Flash is ~$0.001/run)
- `inotify-tools` (Linux) or `fswatch` (macOS) for the reactive watcher

## Inspired By

- [Mastra Observational Memory](https://mastra.ai) (94.87% on LongMemEval benchmark)
- Stanford Generative Agents (Park et al., 2023)
- MemGPT/Letta tiered memory architecture
- Cognitive science: hippocampal replay during sleep transitions

## License

MIT

## Session Configuration Tip

With the memory system running, we recommend extending your idle timeouts (the observer preserves context across resets):

```json
"session": {
  "reset": { "mode": "daily", "atHour": 5, "idleMinutes": 360 },
  "resetByType": { "group": { "mode": "daily", "atHour": 5, "idleMinutes": 180 } }
}
```

See [docs/architecture.md](docs/architecture.md) for the full rationale.
