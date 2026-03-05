# Changelog

All notable changes to Total Recall are documented here.

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
