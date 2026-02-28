# 🧠 Total Recall — Autonomous Agent Memory

**The only memory system that watches on its own.**

No database. No vectors. No manual saves. Just an LLM observer that compresses your conversations into prioritised notes, consolidates when they grow, and recovers anything missed. Five layers of redundancy, zero maintenance. ~$0.10/month.

While other memory skills ask you to remember to remember, this one just pays attention.

## How It Works

```
Layer 1: Observer (cron, every 15 min)
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

Inspired by how human memory works during sleep — the hippocampus captures experiences, and during consolidation, important memories are strengthened while noise is discarded.

## Install via ClawdHub

```bash
clawdhub install total-recall
bash skills/total-recall/scripts/setup.sh
```

## Install from GitHub

```bash
git clone https://github.com/gavdalf/total-recall.git
cd total-recall
bash scripts/setup.sh
```

See [SKILL.md](SKILL.md) for full documentation, configuration, and platform support.

## What's Inside

| Component | Description |
|-----------|-------------|
| `scripts/observer-agent.sh` | Compresses recent conversations via LLM |
| `scripts/reflector-agent.sh` | Consolidates when observations grow large |
| `scripts/session-recovery.sh` | Catches missed sessions on /new |
| `scripts/observer-watcher.sh` | Reactive inotify trigger (Linux) |
| `scripts/dream-cycle.sh` | Nightly memory consolidation helper (Dream Cycle) |
| `scripts/staging-review.sh` | Review, approve, or reject pattern promotion proposals |
| `scripts/backfill-importance.sh` | One-time backfill for pre-WP2 observations lacking importance scores |
| `scripts/setup.sh` | One-command setup (dirs, watcher service) |
| `scripts/_compat.sh` | Cross-platform helpers (Linux + macOS) |
| `prompts/` | LLM system prompts for observer + reflector |
| `prompts/dream-cycle-prompt.md` | Agent prompt for the nightly Dream Cycle run |
| `dream-cycle/` | Dream Cycle documentation |

## Platform Support

| Platform | Observer + Reflector + Recovery | Reactive Watcher |
|----------|-------------------------------|-----------------|
| Linux | ✅ Full support | ✅ With inotify-tools |
| macOS | ✅ Full support | ❌ Cron-only mode |

## Cost

~$0.03–0.10/month using DeepSeek v3.2 via OpenRouter.

## LLM Provider Configuration

Total Recall uses OpenAI-compatible chat completion APIs. You can switch providers without editing scripts.

### Environment variables

```bash
LLM_BASE_URL="${LLM_BASE_URL:-https://openrouter.ai/api/v1}"
LLM_API_KEY="${LLM_API_KEY:-$OPENROUTER_API_KEY}"   # backward-compatible fallback
LLM_MODEL="${LLM_MODEL:-deepseek/deepseek-v3.2}"
OBSERVER_MODEL="${OBSERVER_MODEL:-$LLM_MODEL}"              # Observer-specific override
OBSERVER_FALLBACK_MODEL="${OBSERVER_FALLBACK_MODEL:-google/gemini-2.5-flash}"  # fallback if primary fails
```

- `LLM_BASE_URL`: Base URL for your provider API (default: OpenRouter)
- `LLM_API_KEY`: API key for your provider (defaults to `OPENROUTER_API_KEY` for backward compatibility)
- `LLM_MODEL`: Model ID sent to the provider (default: `deepseek/deepseek-v3.2`)
- `OBSERVER_MODEL`: Override model for the Observer only (defaults to `LLM_MODEL`)
- `OBSERVER_FALLBACK_MODEL`: Fallback if primary Observer model fails (default: `google/gemini-2.5-flash`)

### Why DeepSeek v3.2?

We tested Gemini 2.5 Flash, Grok 4.1 Fast, DeepSeek v3.2, and GPT-4o Mini across deduplication, scoring accuracy, and noise rejection. DeepSeek v3.2 won on scoring consistency (cron noise correctly at 1-2, important events at 7+), perfect noise rejection (3/3 NO_OBSERVATIONS on pure heartbeat traffic), and strong dedup. It's also 6x cheaper than Flash on output tokens ($0.40/M vs $2.50/M).

### Provider examples

```bash
# OpenRouter (default behavior)
export OPENROUTER_API_KEY="your-openrouter-key"

# Ollama (local)
export LLM_BASE_URL="http://localhost:11434/v1"
export LLM_API_KEY="ollama"            # any non-empty value
export LLM_MODEL="llama3.1:8b"

# LM Studio (local server)
export LLM_BASE_URL="http://localhost:1234/v1"
export LLM_API_KEY="lm-studio"         # any non-empty value
export LLM_MODEL="local-model"

# Together.ai
export LLM_BASE_URL="https://api.together.xyz/v1"
export LLM_API_KEY="your-together-key"
export LLM_MODEL="meta-llama/Llama-3.3-70B-Instruct-Turbo"

# Groq
export LLM_BASE_URL="https://api.groq.com/openai/v1"
export LLM_API_KEY="your-groq-key"
export LLM_MODEL="llama-3.3-70b-versatile"
```

`OPENROUTER_API_KEY` remains supported for existing setups.

---

## Total Recall: Dream Cycle

The overnight memory consolidation system. While you sleep, an agent reviews `observations.md`, archives stale items, and adds semantic hooks so nothing useful is actually lost. It keeps your context lean without throwing anything away.

Production results (v1.5.0 Phase 2 complete):

| Night | Mode | Before | After | Reduction | Notes |
|-------|------|--------|-------|-----------|-------|
| Night 1 | Dry run | 9,445 tokens | 8,309 tokens | 12% | 53 items archived |
| Night 2 | Dry run | 16,900 tokens | 6,800 tokens | 60% | 248 items archived |
| Night 3 | Live | 11,688 tokens | 2,930 tokens | 75% | 15 items, 0 false archives |
| Phase 2 WP3 | Chunking + multi-hook | 11,015 tokens | 2,769 tokens | **74.9%** | 6 chunks from 36 observations |
| Phase 2 full | WP2 Decay + WP4 Patterns | 4,200 tokens | 2,435 tokens | **42%** | 46 obs analysed, 12 archived, 0 false archives |

Cost per run: ~$0.001. Models: Claude Sonnet (Dreamer) + DeepSeek v3.2 (Observer, configurable via `OBSERVER_MODEL`).

### Phase 2 Features (v1.5.0, all packages live)

**WP0: Multi-Hook Retrieval** — 4-5 alternative semantic hooks per archived item. Addresses vocabulary mismatch so searches using different words still find the memory.

**WP0.5: Confidence Scoring** — Every observation gets a confidence score (0.0-1.0) and source type (`explicit`, `implicit`, `inference`, `weak`, `uncertain`). High-confidence items are preserved longer.

**WP1: Memory Type System** — 7 types with per-type TTLs: `event` (14d), `fact` (90d), `preference` (180d), `goal` (365d), `habit` (365d), `rule` (never), `context` (30d). Embedded as HTML metadata comments, invisible in rendered markdown.

**WP3: Observation Chunking** — Clusters of 3+ related observations are compressed into a single chunk entry (74.9% token reduction validated). Source observations are archived; a chunk hook replaces them.

**WP2: Importance Decay** — Per-type daily decay applied to `dc:importance` scores. Decay rates: `event` (-0.5/day), `fact` (-0.1/day), `preference` (-0.02/day), `rule`/`habit`/`goal` (no decay). Archive threshold is 3.0. First live run: 25 observations decayed, zero items lost.

**WP4: Pattern Promotion Pipeline** — Scans 7 days of dream logs for recurring themes (3+ occurrences across 3+ separate calendar days). Writes promotion proposals to `memory/dream-staging/` for human review. The `staging-review.sh` script handles list, show, approve, and reject. Confidence for model capability patterns is capped at `low` until 14 days of evidence. The `context` type is never promoted.

### How the Dream Cycle Works

Nine stages run in sequence each night:

```
Stage 1: Preflight + backup
Stage 2: Read observations.md, favorites.md, today's daily file
Stage 3: Apply importance decay (WP2) per memory type before classification
Stage 4: Classify each observation by type and impact
Stage 5: Chunk clusters of 3+ related observations (WP3)
Stage 6: Apply future-date protection (never archive reminders or deadlines)
Stage 7: Decide archive set based on age + type thresholds
Stage 8: Write archive file (memory/archive/observations/YYYY-MM-DD.md)
Stage 9: Add multi-hook semantic search hooks (WP0), scan for patterns (WP4), atomically update observations.md, validate, write dream log + metrics
```

Nothing is deleted. Every archived item gets a semantic hook in `observations.md` pointing back to the archive file, so your agent can still find it.

### Setup: Dream Cycle Cron

The Dream Cycle runs as a nightly cron via OpenClaw. Add a cron job at 3am (or whenever you sleep):

```
# Dream Cycle — nightly at 3am
0 3 * * * OPENCLAW_WORKSPACE=~/your-workspace bash ~/your-workspace/skills/total-recall/scripts/dream-cycle.sh preflight
```

The actual analysis is run by a sub-agent using the prompt in `prompts/dream-cycle-prompt.md`. See [SKILL.md](SKILL.md) for the full setup and model configuration.

Start with `READ_ONLY_MODE=true` for the first few nights. Check the dream log in `memory/dream-logs/`. When you're happy with what it would archive, switch to write mode.

### Dream Cycle Directories

The Dream Cycle writes to:

```
memory/
  archive/
    observations/        # Archived items (one file per night)
    chunks/              # Chunked observation groups (WP3)
  dream-logs/            # Nightly run reports
  dream-staging/         # Pattern promotion proposals awaiting human review (WP4)
  .dream-backups/        # Pre-run backups of observations.md
research/
  dream-cycle-metrics/
    daily/               # JSON metrics for each night
```

---

## Articles

- [Your AI Has an Attention Problem](https://gavlahh.substack.com/p/your-ai-has-an-attention-problem) — How and why we built Total Recall
- [I Published an AI Memory Fix. Then I Found the Hole.](https://gavlahh.substack.com/p/i-published-an-ai-memory-fix-then) — Finding and fixing our own blind spots
- [Do Agents Dream of Electric Sheep? I Built One That Does.](https://gavlahh.substack.com/p/do-agents-dream) — The Dream Cycle: nightly memory consolidation with real numbers
- Part 2: The Wisdom Builder (Phase 2 complete, WP2 Decay + WP4 Pattern Promotion) — coming soon

## License

MIT — see [LICENSE](LICENSE).

*"Get your ass to Mars." — Well, get your agent's memory to work.*

---

*v1.5.0*
