# Total Recall: Dream Cycle

The overnight memory consolidation system. While you sleep, an agent reviews `observations.md`, archives stale items, and adds semantic hooks so nothing useful is actually lost.

**Status: Shipped. Phase 2 live (3 weeks, zero false archives).**

Read more: [Do Agents Dream of Electric Sheep? I Built One That Does.](https://gavlahh.substack.com/p/do-agents-dream)

---

## How It Works

The Dream Cycle runs as two separate jobs:

### Nightly Core (every night, ~7 minutes)

1. **Preflight** — backs up `observations.md`, takes a git snapshot
2. **Importance decay (WP2)** — applies per-type daily decay curves to importance scores. Events fade fast (-0.5/day), rules never decay
3. **Read inputs** — loads `observations.md`, `favorites.md`, today's daily file
4. **Classify** — assigns each observation a type (7 types), confidence score (0.0-1.0), and importance score (0.0-10.0)
5. **Routine-duplicate collapse** — merges repeated operational noise (cron success logs, sync confirmations) into single entries
6. **Chunking (WP3)** — clusters of 3+ related observations are compressed into single summary entries
7. **Future-date protection** — reminders and deadlines are never archived, regardless of score
8. **Archive set** — decides what to archive based on type-aware age + importance thresholds
9. **Write archive** — archived items go to `memory/archive/observations/YYYY-MM-DD.md`
10. **Semantic hooks (WP0)** — each archived item gets 2-3 alternative search hooks so it stays findable via different search terms
11. **Atomic update** — applies the new `observations.md` safely
12. **Validate** — checks token count, writes dream log + metrics JSON; rolls back on failure

### Weekly Pattern Scan (Sundays)

1. **Load dream logs** — reads the last 7 days of nightly dream logs
2. **Cross-reference** — scans for themes that appear across 3+ separate calendar days
3. **Write proposals** — qualifying patterns are written to `memory/dream-staging/` for human review
4. **Never auto-applies** — all proposals require explicit human approval before becoming memories

Nothing is deleted. Every archived item is preserved in the archive and referenced by a hook.

---

## Memory Types

| Type | TTL | Decay Rate | Description |
|------|-----|-----------|-------------|
| `rule` | Never | 0 | Operational rules, hard constraints, policies |
| `goal` | 365 days | 0 | Active goals, targets, milestones |
| `habit` | 365 days | 0 | Recurring behaviours, routines, patterns |
| `preference` | 180 days | -0.02/day | User preferences, decisions, stated likes |
| `fact` | 90 days | -0.1/day | Factual information, configs, versions |
| `context` | 30 days | -0.1/day | Temporary context, session notes, in-progress work |
| `event` | 14 days | -0.5/day | One-off occurrences, daily summaries, status updates |

---

## Files

| File | Description |
|------|-------------|
| `../scripts/dream-cycle.sh` | Shell helper for safe file operations (preflight, archive, update, validate, rollback, decay, chunk, write-staging) |
| `../prompts/dream-cycle-prompt.md` | Agent prompt — paste into your Dream Cycle cron job |
| `../scripts/staging-review.sh` | Helper for reviewing pattern promotion proposals (list, show, approve, reject) |

---

## Quick Setup

1. Run setup (creates required directories):
   ```bash
   bash scripts/setup.sh
   ```

2. Add a nightly cron job (3am or whenever you sleep):
   ```
   0 3 * * * OPENCLAW_WORKSPACE=~/your-workspace bash ~/your-workspace/skills/total-recall/scripts/dream-cycle.sh preflight
   ```

3. Configure your cron agent to use `prompts/dream-cycle-prompt.md` as the system prompt.

4. Set `READ_ONLY_MODE=true` for the first 2-3 nights. Check `memory/dream-logs/` after each run.

5. When satisfied, switch to `READ_ONLY_MODE=false` for live mode.

6. (Optional) Add a weekly pattern scan job on Sundays for WP4 pattern promotion.

---

## Results (3 Weeks Production Data)

| Period | Avg Before | Avg After | Avg Reduction | False Archives |
|--------|-----------|-----------|---------------|----------------|
| Week 1 | 8,349 tokens | 3,622 tokens | 57% | 0 |
| Week 2 | 9,330 tokens | 3,290 tokens | 58% | 0 |
| Week 3 | 6,242 tokens | 2,973 tokens | 48% | 0 |

Cost per run: ~$0.003-0.01. Models: Claude Sonnet (Dreamer) + Gemini Flash (Observer).

---

## Outputs

```
memory/
  archive/
    observations/        # Nightly archive files (YYYY-MM-DD.md)
    chunks/              # Chunked observation summaries (YYYY-MM-DD.md)
  dream-logs/            # Run reports (YYYY-MM-DD.md)
  dream-staging/         # Pattern promotion proposals (pending human review)
  .dream-backups/        # Pre-run backups of observations.md
research/
  dream-cycle-metrics/
    daily/               # JSON metrics (YYYY-MM-DD.json)
```

---

See [SKILL.md](../SKILL.md) for full documentation.
