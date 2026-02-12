# OpenClaw Memory — Agent Installation Guide

> Give these instructions to your OpenClaw agent and it will install the memory system itself.
> Just paste this into your chat or add it to your workspace.

---

## Hey Agent 👋

Your owner wants you to install **OpenClaw Memory** — a five-layer memory protection system that prevents you from losing important information when context compaction fires.

**What it does:** Continuously observes your conversations, extracts durable facts, and saves them to files that survive compaction. You'll remember things across sessions instead of starting fresh every time.

**What you need before starting:**
- An OpenRouter API key (ask your owner if you don't have one)
- Your workspace directory (usually `~/clawd` or wherever your AGENTS.md lives)
- bash, jq, and curl installed (check with `which bash jq curl`)
- Linux: `inotify-tools` installed (`apt install inotify-tools`)
- macOS: `fswatch` installed (`brew install fswatch`)

---

## Installation Steps

### Step 1: Clone the repo

```bash
git clone https://github.com/gavdalf/openclaw-memory.git /tmp/openclaw-memory
cd /tmp/openclaw-memory
```

### Step 2: Set your paths

```bash
# Set these to match YOUR setup
export WORKSPACE_DIR="$HOME/clawd"          # Your agent workspace
export OPENCLAW_DIR="$HOME/.openclaw"        # OpenClaw data directory
```

### Step 3: Copy scripts and prompts

```bash
# Create directories if they don't exist
mkdir -p "$WORKSPACE_DIR"/{scripts,prompts,logs,memory,memory/observation-backups}

# Copy scripts
cp scripts/observer.sh "$WORKSPACE_DIR/scripts/"
cp scripts/reflector.sh "$WORKSPACE_DIR/scripts/"
cp scripts/watcher.sh "$WORKSPACE_DIR/scripts/"
cp scripts/session-recovery.sh "$WORKSPACE_DIR/scripts/"
chmod +x "$WORKSPACE_DIR/scripts/"*.sh

# Copy prompts
cp prompts/observer-system.txt "$WORKSPACE_DIR/prompts/"
cp prompts/reflector-system.txt "$WORKSPACE_DIR/prompts/"
```

### Step 4: Configure your API key

Add your OpenRouter API key to your workspace `.env` file:

```bash
echo 'OPENROUTER_API_KEY=your-key-here' >> "$WORKSPACE_DIR/.env"
```

Or export it directly:
```bash
export OPENROUTER_API_KEY="your-key-here"
```

**Model:** The default is `google/gemini-2.5-flash` via OpenRouter (~$0.001 per run). You can change this by setting `OBSERVER_MODEL` in your environment.

### Step 5: Set up the cron job (Observer)

Use the OpenClaw `cron` tool to create a job that runs the observer every 15 minutes:

```json
{
  "name": "memory-observer",
  "schedule": {
    "kind": "every",
    "everyMs": 900000
  },
  "payload": {
    "kind": "agentTurn",
    "message": "Run the memory observer. Execute: source $WORKSPACE_DIR/.env && bash $WORKSPACE_DIR/scripts/observer.sh 2>&1. Reply with the last line of output only.",
    "model": "google/gemini-2.5-flash"
  },
  "sessionTarget": "isolated",
  "delivery": { "mode": "none" },
  "enabled": true
}
```

### Step 6: Configure the pre-compaction hook (memoryFlush)

This is the critical safety net. Add this to your `openclaw.json` config (or ask your owner to add it via the OpenClaw config):

```json
{
  "agents": {
    "defaults": {
      "compaction": {
        "memoryFlush": {
          "enabled": true,
          "instruction": "MEMORY FLUSH: Run `source $WORKSPACE_DIR/.env && bash $WORKSPACE_DIR/scripts/observer.sh --flush` to capture recent conversation before compaction. Then write any key facts from the current conversation to $WORKSPACE_DIR/memory/$(date +%Y-%m-%d).md"
        }
      }
    }
  }
}
```

**Important:** Replace `$WORKSPACE_DIR` with your actual path (e.g., `/root/clawd`) in the config — environment variables don't expand in JSON config files.

### Step 7: Start the reactive watcher (optional but recommended)

The watcher triggers the observer immediately during heavy conversations (instead of waiting for the 15-min cron):

```bash
# Start in background
nohup bash "$WORKSPACE_DIR/scripts/watcher.sh" > "$WORKSPACE_DIR/logs/watcher.log" 2>&1 &

# To auto-start on reboot, add to crontab:
(crontab -l 2>/dev/null; echo "@reboot bash $WORKSPACE_DIR/scripts/watcher.sh >> $WORKSPACE_DIR/logs/watcher.log 2>&1 &") | crontab -
```

### Step 8: Add session recovery to your startup

Add this to your AGENTS.md (or equivalent) in the "Session Start" section:

```markdown
## Session Start — First Thing
1. Run `bash ~/clawd/scripts/session-recovery.sh` to check if the last session was observed
2. Load `memory/observations.md` (your cross-session memory)
3. Load today's `memory/YYYY-MM-DD.md`
4. Load yesterday's `memory/YYYY-MM-DD.md`
```

### Step 9: Verify it works

```bash
# Check observer runs without errors
source "$WORKSPACE_DIR/.env"
bash "$WORKSPACE_DIR/scripts/observer.sh"
# Should either create observations or say "no new content"

# Check observations file exists
cat "$WORKSPACE_DIR/memory/observations.md"
```

---

## How It Works (Quick Summary)

Five layers protect your memory:

| Layer | Trigger | What It Does |
|-------|---------|--------------|
| 1. Observer Cron | Every 15 min | Extracts facts from session transcripts |
| 2. Reactive Watcher | 40+ new lines | Fast capture during active conversations |
| 3. Pre-Compaction Hook | ~172k tokens | Emergency capture before compaction fires |
| 4. Session Recovery | Every /new | Catches what was missed during session resets |
| 5. Git Recovery | Every /new | Detects uncommitted file changes |

**Cost:** ~$0.10-0.20/month using Gemini Flash via OpenRouter.

---

## Troubleshooting

**"OPENROUTER_API_KEY not set"** → Make sure your .env file has the key and you're sourcing it before running scripts.

**Observer produces empty observations** → Check that session JSONL files exist in `$OPENCLAW_DIR/agents/main/sessions/`. OpenClaw writes these in real-time.

**Watcher not triggering** → Verify `inotify-tools` (Linux) or `fswatch` (macOS) is installed. Check `logs/watcher.log` for errors.

**Reflector not running** → It only triggers when observations.md exceeds ~8,000 words. This is normal — it might take days to accumulate enough.

---

## Tell Your Owner

Once installed, let your owner know:
- ✅ Memory system is active
- ✅ Observer runs every 15 minutes
- ✅ Pre-compaction hook is configured
- ✅ Session recovery is in your startup procedure
- 💰 Expected cost: ~$0.10-0.20/month
- 📁 Observations saved to: `memory/observations.md`
