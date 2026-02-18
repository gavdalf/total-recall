# Agent Integration Guide

## Quick Setup

1. Install the skill:
   ```bash
   clawdhub install total-recall
   # OR
   git clone https://github.com/gavdalf/total-recall.git ~/your-workspace/skills/total-recall
   ```

2. Run setup:
   ```bash
   OPENCLAW_WORKSPACE=~/your-workspace bash skills/total-recall/scripts/setup.sh
   ```

3. Add to your agent's startup procedure (e.g., AGENTS.md):
   ```
   OPENCLAW_WORKSPACE=~/your-workspace bash skills/total-recall/scripts/session-recovery.sh
   ```

4. Add cron jobs (via OpenClaw cron or system crontab):
   ```
   # Observer — every 15 minutes
   */15 * * * * OPENCLAW_WORKSPACE=~/your-workspace bash ~/your-workspace/skills/total-recall/scripts/observer-agent.sh

   # Reflector — hourly check
   0 * * * * OPENCLAW_WORKSPACE=~/your-workspace bash ~/your-workspace/skills/total-recall/scripts/reflector-agent.sh
   ```

5. Add to your agent's context/system prompt:
   ```
   At session startup, read memory/observations.md for cross-session context.
   ```

## Configuration

See [SKILL.md](SKILL.md) for full configuration options, environment variables, and advanced setup.

## Pre-Compaction Hook

For maximum protection, configure OpenClaw's `memoryFlush` to run the observer in `--flush` mode before context compaction. See SKILL.md for details.
