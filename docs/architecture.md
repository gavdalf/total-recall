# Architecture

## Overview

The memory system operates as an external layer on top of OpenClaw's native compaction. It writes to plain Markdown files on disk that survive compaction entirely.

## The Session Handoff Problem

OpenClaw agents face a unique challenge when users manually trigger `/new` or `/reset` during active conversations:

- The **reactive watcher** has a 5-minute cooldown between triggers (to avoid spam during long conversations)
- If `/new` happens during that cooldown, the watcher won't fire again
- The **15-minute cron** hasn't run yet
- The **pre-compaction hook** only fires on automatic compaction (not manual resets)
- Result: Recent conversation is lost between sessions

**Session Recovery** (Layer 5) solves this by comparing the last session file's hash against what was already observed. If there's a mismatch at startup, it triggers an emergency capture.

## Components

### Observer Agent (`scripts/observer.sh`)
- Reads recent session JSONL transcripts
- Extracts durable facts via LLM (Gemini 2.5 Flash recommended)
- Appends to `memory/observations.md` with priority markers
- Runs every 15 minutes via cron + reactively via watcher
- Supports `--flush` mode for pre-compaction emergency capture

### Reflector Agent (`scripts/reflector.sh`)
- Consolidates observations when they exceed ~8000 words
- Merges duplicates, removes outdated entries, compresses low-priority items
- Backs up before reflecting (safety net)
- Sanity check: rejects output if larger than input

### Reactive Watcher (`scripts/watcher.sh`)
- Uses inotify (Linux) or fswatch (macOS) to watch session files
- Triggers observer after 40 new JSONL writes (configurable)
- 5-minute cooldown between triggers
- Filters to main sessions only (skips subagent/cron sessions)

### Pre-Compaction Hook
- OpenClaw's `memoryFlush` config fires a silent agent turn before compaction
- We configure it to run the observer in `--flush` mode first
- 2-hour lookback, skip dedup — maximum capture before context is lost

### Session Recovery (`scripts/session-recovery.sh`)
- Runs at session startup (BEFORE loading observations)
- Checks if the last session file matches the last observed hash
- If not, triggers emergency observer capture
- Works without git — uses MD5 hash of last 50 lines from session file
- Catches the gap between manual `/new` resets and the next observer run

## Data Flow

```
User conversations → Session JSONL files (raw, real-time)
    ↓
Observer (5 triggers: every 15 min + reactive + pre-compaction + session recovery + manual)
    ↓
observations.md (prioritised facts, ~5000 tokens)
    ↓
Reflector (when >8000 words, consolidate)
    ↓
Session startup: run session-recovery.sh → load observations.md + favorites.md + daily memory
```

## Five-Layer Architecture

1. **⏰ Observer Cron** — Every 15 minutes, guaranteed baseline coverage
2. **🎯 Reactive Watcher** — Fires after 40 JSONL writes (during heavy conversations)
3. **🛡️ Pre-Compaction Hook** — Emergency capture right before automatic compaction
4. **📝 Session Startup Load** — Reads all saved memory files at start of every session
5. **🔄 Session Recovery** — Checks for missed observations when user manually resets session

This redundancy ensures **no conversation is lost**, even during edge cases like manual resets during watcher cooldowns.

## Why External Files?

Compaction only affects the in-memory conversation transcript. Our files live on disk, completely independent. This means:

1. Compaction can't destroy our saved facts
2. Multiple sessions can share the same memory files
3. The files are human-readable and debuggable
4. No changes to OpenClaw core required

---

## Recommended Session Configuration

With the memory system active, you can safely extend your session idle timeouts. The observer captures everything important, so a fresh session start loads curated context rather than raw conversation noise.

**Suggested config (openclaw.json):**

```json
{
  "session": {
    "reset": {
      "mode": "daily",
      "atHour": 5,
      "idleMinutes": 360
    },
    "resetByType": {
      "group": {
        "mode": "daily",
        "atHour": 5,
        "idleMinutes": 180
      }
    }
  }
}
```

**Why these values:**
- **Daily reset at 5am** — Think of it like sleep. Your agent consolidates memories overnight and wakes up fresh with everything important loaded from observations. Extending to weekly/monthly just accumulates noise and hits compaction more often.
- **DM idle: 6 hours** (up from default 2) — Gives you continuity during the day. Step away for dinner, come back, session is still alive.
- **Group idle: 3 hours** (up from default 1) — Less aggressive timeout for group conversations.

**Why not longer?** Every fresh session loads the curated observation file (~4.5% of context) instead of carrying around hours of raw conversation noise. Daily resets are a feature, not a bug — they're the "sleep cycle" that keeps your agent's memory healthy.
