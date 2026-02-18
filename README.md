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
| `scripts/setup.sh` | One-command setup (dirs, watcher service) |
| `scripts/_compat.sh` | Cross-platform helpers (Linux + macOS) |
| `prompts/` | LLM system prompts for observer + reflector |
| `dream-cycle/` | Total Recall: Dream Cycle (coming soon) |

## Platform Support

| Platform | Observer + Reflector + Recovery | Reactive Watcher |
|----------|-------------------------------|-----------------|
| Linux | ✅ Full support | ✅ With inotify-tools |
| macOS | ✅ Full support | ❌ Cron-only mode |

## Cost

~$0.05–0.15/month using Gemini 2.5 Flash via OpenRouter.

## Total Recall: Dream Cycle

The overnight autonomous self-improvement system — while you sleep, your agent reviews its own performance, identifies improvements, and executes fixes. Coming soon.

## Articles

- [Your AI Has an Attention Problem](https://gavlahh.substack.com/p/your-ai-has-an-attention-problem) — How and why we built Total Recall
- [I Published an AI Memory Fix. Then I Found the Hole.](https://gavlahh.substack.com/p/i-published-an-ai-memory-fix-then) — Finding and fixing our own blind spots

## License

MIT — see [LICENSE](LICENSE).

*"Get your ass to Mars." — Well, get your agent's memory to work.*
