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
| `OPENCLAW_WORKSPACE` | `~/your-workspace` | Workspace root |

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

---

## Dream Cycle

The Dream Cycle is an optional nightly agent that runs after hours to consolidate `observations.md`. It archives stale items and adds semantic hooks so nothing useful is actually lost. Context stays lean; everything remains findable.

**Status: Phase 2 COMPLETE as of 28 Feb 2026. All 6 work packages live and validated.**

### What It Does

- Classifies every observation by impact (critical / high / medium / low / minimal) and age
- Archives items that have passed their relevance threshold
- Adds a semantic hook for each archived item (specific keywords + archive reference)
- Validates the result; rolls back automatically if something goes wrong

### Setup

1. **Run setup** — setup.sh creates the required Dream Cycle directories automatically.

2. **Add the nightly cron job:**
   ```
   # Dream Cycle — nightly at 3am
   0 3 * * * OPENCLAW_WORKSPACE=~/your-workspace bash ~/your-workspace/skills/total-recall/scripts/dream-cycle.sh preflight
   ```

3. **Configure your cron agent** — use `prompts/dream-cycle-prompt.md` as the system prompt for the nightly agent. Models: Claude Sonnet for the Dreamer (analysis + decisions), Gemini Flash for the Observer (cheap, fast).

4. **Dry run first** — set `READ_ONLY_MODE=true` in your cron agent payload for the first 2-3 nights. Check `memory/dream-logs/` after each run to verify what it would have archived.

5. **Go live** — switch to `READ_ONLY_MODE=false` once satisfied.

### Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DREAM_TOKEN_TARGET` | `8000` | Token target for observations.md after consolidation |
| `DREAM_PHASE` | (unset = 1) | Feature phase: Phase 2 is live (WP0/WP0.5/WP1). Phase 2 adds multi-hook, confidence scoring, type classification. |
| `READ_ONLY_MODE` | `false` | Set `true` for dry-run analysis without writes |

### Results (3 Nights)

| Night | Mode | Before | After | Reduction | Archived |
|-------|------|--------|-------|-----------|----------|
| Night 1 | Dry run | 9,445 tokens | 8,309 tokens | 12% | 53 items |
| Night 2 | Dry run | 16,900 tokens | 6,800 tokens | 60% | 248 items |
| Night 3 | Live | 11,688 tokens | 2,930 tokens | 75% | 15 items, 0 false archives |

Cost per run: ~$0.003.

### Files

| File | Description |
|------|-------------|
| `scripts/dream-cycle.sh` | Shell helper: preflight, archive, update-observations, write-log, write-metrics, validate, rollback |
| `prompts/dream-cycle-prompt.md` | Agent prompt for the nightly Dream Cycle run |
| `dream-cycle/README.md` | Dream Cycle quick reference |
| `schemas/observation-format.md` | Extended observation format for Phase 2 type classification |

### Directories Created

```
memory/
  archive/
    observations/        # Archived items (one .md file per night)
  dream-logs/            # Nightly run reports
  .dream-backups/        # Pre-run safety backups
research/
  dream-cycle-metrics/
    daily/               # JSON metrics per night
```

### Phase 2+ Roadmap

*Updated: 2026-02-28 — Phase 2 complete, all work packages live.*

**Key insight from research:** Agent capability to use retrieval tools matters more than the retrieval mechanism itself. Simple filesystem tools often beat fancy memory frameworks. This validates our markdown-based approach.

**Rollout approach:** Dry-run-overnight + morning-review + immediate-live. The 7-day plan was compressed to 5 days. Full Phase 2 completed 28 Feb 2026, one day ahead of the 1 Mar target.

| Phase | Focus | Status |
|-------|-------|--------|
| **Phase 1** | Archive & trim, semantic hooks | ✅ LIVE |
| **Phase 2 — WP0** | Multi-hook generation (4-5 search phrasings per archive) | ✅ LIVE (25 Feb) |
| **Phase 2 — WP0.5** | Confidence metadata (0.0-1.0 score + source attribution) | ✅ LIVE (25 Feb) |
| **Phase 2 — WP1** | Type system — 7 memory types + TTL classification | ✅ LIVE (25 Feb) |
| **Phase 2 — WP3** | Chunking — compress related observations into single entries | ✅ LIVE (26 Feb) |
| **Phase 2 — WP2** | Importance decay — per-type daily decay curves | ✅ LIVE (28 Feb 2026) |
| **Phase 2 — WP4** | Pattern promotion pipeline — staging proposals for human review | ✅ LIVE (28 Feb 2026) |
| **Full Phase 2** | All work packages live | ✅ COMPLETE (28 Feb 2026) |
| **Phase 3** | Contradiction detection, retrieval validation loop | Future |

**Completed rollout schedule:**

| Night/Morning | What | Status |
|---------------|------|--------|
| Tue 24 night (02:30) | WP0 + WP0.5 + WP1 dry run | ✅ DONE |
| Wed 25 morning (07:01) | Approved — WP0/WP0.5/WP1 LIVE (66.1% reduction) | ✅ DONE |
| Thu 26 night (02:30) | WP3 chunking dry run | ✅ DONE |
| Thu 26 morning | Review — WP3 LIVE (74.9% reduction, 6 chunks from 36 obs) | ✅ DONE |
| Fri 27 night (02:30) | WP2 importance decay dry run | ✅ DONE |
| Fri 27 morning | Review — WP2 LIVE (25 obs decayed, 0 lost) | ✅ DONE |
| Sat 28 night (02:30) | WP4 pattern promotion dry run | ✅ DONE |
| Sat 28 morning | Review — WP4 LIVE, Phase 2 complete | ✅ DONE |

**Phase 2 work packages:**
- **WP0 Multi-hook** — 4-5 alternative search phrasings per archived item (30-50% recall improvement)
- **WP0.5 Confidence** — 0.0-1.0 score + source attribution (explicit/implicit/inference/weak/uncertain)
- **WP3 Chunking** — compress 3+ related observations into a single entry with synthesised finding
- **WP2 Importance decay** — 7 memory types (fact, preference, goal, habit, event, rule, context) with per-type TTL and daily decay
- **WP4 Pattern promotion** — multi-day patterns → staged proposals in `memory/dream-staging/` for human approval

**Phase 3 preview:**
- **Contradiction detection** — NLI-based, flag conflicting facts
- **Retrieval validation** — measure retrieval quality, not just archival accuracy

See `research/dream-cycle-strategy.md` and `research/dream-cycle-phase2-scope.md` for full design docs.

Set `DREAM_PHASE=2` in your cron payload to enable Phase 2 behaviour.

---

## Inspired By

This system is inspired by how human memory works during sleep — the hippocampus (observer) captures experiences, and during sleep consolidation (reflector), important memories are strengthened while noise is discarded.

Read more: [Your AI Has an Attention Problem](https://gavlahh.substack.com/p/your-ai-has-an-attention-problem)

*"Get your ass to Mars." — Well, get your agent's memory to work.*
