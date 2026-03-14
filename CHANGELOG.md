# Changelog

All notable changes to Total Recall are documented here.

## [2.2.0] - 2026-03-14

### Changed: Dream Cycle Performance Split

**The problem:** The Dream Cycle nightly job had accumulated features over 3 weeks of Phase 2 development (decay, type classification, confidence scoring, chunking, 4-5 semantic hooks per item, and 7-day pattern scanning). Each feature was individually justified, but together they pushed run times from ~5 minutes to 13+ minutes. Two consecutive nights hit the 900-second timeout and produced no output at all. That's worse than any individual feature being slightly less thorough.

**The fix:** Split the Dream Cycle into two jobs and trim the fat.

#### Nightly core job (02:30, every night)
Runs decay, classification, confidence scoring, chunking, archiving, and semantic hooks. Everything that directly maintains `observations.md` health.

- **Hooks reduced from 4-5 to 2-3 per archived item.** The 4th and 5th hooks were always the weakest associations ("audio delivery system failure" instead of "TTS timeout"). The top 2-3 cover 95%+ of realistic search queries. This alone cuts ~30% of output tokens.
- **Classification made concise.** The agent was writing paragraph justifications for each observation's type and confidence score. Nothing ever read those justifications. Now it just assigns the values.
- **WP4 pattern scanning removed from nightly run.** This was the biggest time sink: loading 7 separate dream log files and cross-referencing every theme across all of them.

#### Weekly pattern job (03:00, Sundays)
WP4 pattern promotion now runs once a week. Same logic, same thresholds, same output. Reads 7 days of dream logs, scans for recurring themes across 3+ calendar days, writes proposals to `memory/dream-staging/`.

Running this weekly instead of nightly means a qualifying pattern detected on Wednesday won't be surfaced until Sunday. In practice this doesn't matter: staging proposals sit until human review anyway. Nobody was actioning them the morning after.

#### Quality impact
- **Archiving decisions: identical.** Same scoring rubric, same age thresholds, same future-date protection.
- **Validation gates: identical.** Same three gates (zero false archives, token target, reduction percentage).
- **Memory integrity: identical.** Same observations get archived, same hooks get written, same chunks get created.
- **Search recall: marginal reduction.** 2-3 hooks instead of 4-5 means ~5-10% less coverage on unusual search queries for archived observations. Acceptable tradeoff.
- **Pattern detection: delayed, not degraded.** Weekly instead of nightly. Same algorithm, same confidence levels, same human approval requirement.

#### Expected performance
- Nightly core job: estimated ~400s (down from 800s+), well within the 900s timeout
- Weekly pattern job: ~300-500s on its own, plenty of headroom

#### Production context
- 3 weeks of Phase 2 live data: 21 successful runs, ~50% average token reduction, zero false archives across all runs
- The timeout failures were the trigger: two consecutive nights of zero output is worse than slightly fewer semantic hooks

### Results (3 weeks production data, pre-split)

| Period | Avg Tokens Before | Avg Tokens After | Avg Reduction | False Archives |
|--------|------------------|-----------------|---------------|----------------|
| Week 1 (Phase 2 launch) | 8,349 | 3,622 | 57% | 0 |
| Week 2 | 9,330 | 3,290 | 58% | 0 |
| Week 3 | 6,242 | 2,973 | 48% | 0 |

## [2.1.0] - 2026-03-07

### Changed
- Gmail and IONOS connectors now use two-gate email scoring instead of regex-only sender matching
- Gate 1 adds a learned sender cache that builds automatically over time with no manual setup
- Gate 2 adds LLM content triage with configurable model and batch sizing via `config/aie.yaml`
- Gmail default query changed from unread-only to time-window (`newer_than:3h`) to catch emails already read on other devices
- IONOS connector now scores recent messages by default (state dedupe still prevents duplicates)
- Connector hardening improved for macOS/Linux compatibility (timeouts, lock waits, temp cleanup, safer JSON handling)

### Fixed
- `noreply` sender patterns no longer silently suppress important operational emails (deliveries, financial notices, account/security updates)

## [2.0.1] - 2026-03-05

### Fixed
- Lock files moved from `/tmp` to `$WORKSPACE/logs/` to prevent cross-workspace collisions when running multiple agents (thanks @zweice, PR #4)
- Dream cycle auto-creates `favorites.md` with a skeleton if missing instead of failing on first run (thanks @zweice, PR #4)

## [2.0.0] - 2026-03-05

### Added
- Ambient Intelligence Engine configuration in `config/aie.yaml`
- Shared AIE config loader in `scripts/aie-config.sh`
- Pluggable connector toggles for calendar, todoist, ionos, gmail, fitbit, and filewatch
- Notification channel configuration for Telegram, Discord, and generic webhooks
- Configurable model selection for rumination, classification, enrichment, and ambient actions

### Changed
- Sanitised the new AIE scripts to remove user-specific chat IDs, account names, workspace paths, and model IDs
- Replaced hardcoded `~/clawd` path assumptions with configurable workspace and path settings
- Updated `sensor-sweep`, `rumination-engine`, `preconscious-select`, `ambient-actions`, `buffer-inject`, and `emergency-surface` to read shared config defaults
- Updated all AIE connectors to self-check `enabled` state before running
- Rewrote the README with AIE architecture, quick start, and config reference sections

### Notes
- v1.x functionality remains intact and continues to ship alongside the new AIE pipeline

## [1.5.1] - 2026-02-28

### Changed
- Documentation rewritten to be user-facing. Removed internal development phases and work package references.

## [1.5.0] - 2026-02-28

### Added: Importance Decay and Pattern Promotion (Dream Cycle)

Full Dream Cycle feature set now live. All features validated in production.

**Production metrics:** 46 observations analysed, 12 archived, 4,200 to 2,435 tokens (42% reduction), zero false archives.

#### Importance Decay
- Per-type daily decay curves applied to importance scores: `event` (-0.5/day), `fact` (-0.1/day), `preference` (-0.02/day), `rule`/`habit`/`goal` (0, never decay)
- Archive threshold set at 3.0. Items that decay below 3.0 are queued for archival on the next Dream Cycle run
- `cmd_decay` subcommand added to `dream-cycle.sh`
- `scripts/backfill-importance.sh` — one-time backfill for observations that predate importance scoring (requires `ANTHROPIC_API_KEY`)
- First live run: 25 observations decayed, zero items lost

#### Pattern Promotion Pipeline
- Scans 7 days of dream logs for recurring themes: 3+ occurrences across 3+ separate calendar days qualifies as a pattern
- Writes promotion proposals to `memory/dream-staging/` for human review. Never writes directly to `observations.md` or any system file
- `cmd_write_staging` subcommand with path traversal protection, field validation, and enum checks on `type`, `target_file`, and `confidence`
- `scripts/staging-review.sh` helper supports `list`, `show`, `approve`, and `reject` operations
- Confidence capping: model capability patterns are capped at `low` until 14 days of evidence. The `context` type is never promoted
- Human approval required before any staging proposal becomes a memory

## [1.4.0] - 2026-02-28

### Fixed: Observation Bloat (Scoring, Dedup, Decay Threshold)
- **Archive threshold raised from 0.5 to 3.0** — observations that decay below 3.0 importance are now auto-archived. The previous threshold was too low, causing decayed items to accumulate indefinitely
- **Observer scoring prompt tightened** — explicit hard rule added: automated/cron/scheduled actions always score 1-2. Prevents scoring inflation where operational noise (preflight checks, token refreshes, auto-updates) was incorrectly scored 4.0-5.0
- **Dedup fingerprint improved** — increased fingerprint window from 40 to 80 characters and added date/day-name normalisation. Prevents near-duplicate observations from passing the dedup filter when the LLM rephrases slightly
- **Dedup prompt strengthened** — zero-tolerance language with concrete examples of what counts as a duplicate

### Impact
- In production: observations.md reduced from 20.6KB/155 lines to 6.7KB/52 lines (68% reduction)
- ~4,500 fewer tokens loaded per session startup

## [1.3.0] - 2026-02-26

### Added: Multi-Hook Retrieval, Confidence Scoring, Memory Type System, Observation Chunking (Dream Cycle)

Four Dream Cycle features now validated and live.

#### Multi-Hook Retrieval
- Dream Cycle generates 4-5 alternative semantic hooks per archived observation
- Addresses vocabulary mismatch: searches using different words than the original still find the memory
- Hooks use synonyms, related terms, problem descriptions, and solution descriptions

#### Confidence Scoring
- Every observation receives a confidence score (0.0-1.0) and source type classification
- Source types: `explicit`, `implicit`, `inference`, `weak`, `uncertain`
- High-confidence observations (>0.7) preserved longer; low-confidence (<0.3) archived sooner
- Contradictions are flagged; the higher-confidence entry is retained
- Schema extended: `dc:confidence` and `dc:source` metadata fields added to `observation-format.md`

#### Memory Type System
- 7 observation types with per-type TTLs: `event` (14d), `fact` (90d), `preference` (180d), `goal` (365d), `habit` (365d), `rule` (never), `context` (30d)
- Type metadata embedded as HTML comments (`<!-- dc:type=X dc:ttl=Y ... -->`)
- Backward compatible — observations without type tags remain fully valid

#### Observation Chunking
- Dream Cycle compresses clusters of 3+ related observations into single summary chunk entries
- Chunk archive written to `memory/archive/chunks/YYYY-MM-DD.md` via `dream-cycle.sh chunk`
- Source observations archived; a single chunk hook replaces them in `observations.md`
- Production metrics: 74.9% token reduction (11,015 to 2,769 tokens), 6 chunks from 36 source observations, zero false archives

## [1.2.0] - 2026-02-25

### Added
- Configurable LLM provider support via environment variables
  - `LLM_BASE_URL` — API endpoint (default: OpenRouter)
  - `LLM_API_KEY` — API key (defaults to `OPENROUTER_API_KEY` for backward compatibility)
  - `LLM_MODEL` — Model name (default: `deepseek/deepseek-v3.2`)
- Works with any OpenAI-compatible API: Ollama, LM Studio, Together.ai, Groq, etc.

### Changed
- Observer and Reflector scripts now use configurable endpoints instead of hardcoded OpenRouter

## [1.1.0] - 2026-02-23

### Added
- **Dream Cycle (Layer 6)** — nightly memory consolidation
  - 9-stage pipeline: Preflight, Read, Classify, Collapse duplicates, Future-date protection, Archive, Semantic hooks, Write, Validate
  - Git snapshot before every write (automatic rollback on failure)
  - Semantic hooks left behind for searchable archive references
  - Dream logs and metrics JSON output
- `scripts/dream-cycle.sh` — file operations helper (archive, update, validate, rollback)
- `prompts/dream-cycle-prompt.md` — full agent prompt for the Dreamer
- `schemas/observation-format.md` — extended observation metadata format
- Setup script now creates Dream Cycle directories
- README and SKILL.md updated with Dream Cycle docs and setup instructions

### Fixed
- Hardcoded workspace paths in dream cycle prompt replaced with portable `$SKILL_DIR` variables
- Broken script path in `config/memory-flush.json`
- Wrong path in `templates/AGENTS-snippet.md`

### Results (3 nights production data)

| Run | Mode | Before | After | Reduction |
|-----|------|--------|-------|-----------|
| Night 1 | Dry run | 9,445 tokens | 8,309 tokens | 12% |
| Night 2 | Dry run | 16,900 tokens | 6,800 tokens | 60% |
| Night 3 | Live | 11,688 tokens | 2,930 tokens | 75% |

Zero false archives across all runs.

## [1.0.0] - 2026-02-18

### Added
- Initial release: Observer, Reflector, Session Recovery, Reactive Watcher
- 5-layer redundancy architecture
- Cross-platform support (Linux + macOS)
- One-command setup via `scripts/setup.sh`
- ClawdHub publication
