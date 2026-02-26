# Changelog

All notable changes to Total Recall are documented here.

## [1.3.0] - 2026-02-26

### Phase 2 — Multi-Hook Retrieval, Confidence Scoring, Type System, Observation Chunking

Four Phase 2 work packages are now validated, live, and formally released.

#### WP0: Multi-Hook Retrieval
- Dream Cycle generates 4-5 alternative semantic hooks per archived observation
- Addresses vocabulary mismatch: searches using different words than the original still find the memory
- Hooks use synonyms, related terms, problem descriptions, and solution descriptions
- Validated in production since 2026-02-24

#### WP0.5: Confidence Scoring
- Every observation now receives a confidence score (0.0–1.0) and source type classification
- Source types: `explicit`, `implicit`, `inference`, `weak`, `uncertain`
- High-confidence observations (>0.7) preserved longer; low-confidence (<0.3) archived sooner
- Contradictions are flagged and the higher-confidence entry is retained
- Schema extended: `dc:confidence` and `dc:source` metadata fields added to `observation-format.md`
- Validated in production since 2026-02-24

#### WP1: Memory Type System (formally released)
- 7 observation types with per-type TTLs: `event` (14d), `fact` (90d), `preference` (180d), `goal` (365d), `habit` (365d), `rule` (never), `context` (30d)
- Type metadata embedded as HTML comments (`<!-- dc:type=X dc:ttl=Y ... -->`)
- Phase 1 observations (untagged) remain fully valid — backward compatible
- Code was in repo since v1.1.0; now production-validated and formally released

#### WP3: Observation Chunking
- Dream Cycle compresses clusters of 3+ related observations into single summary chunk entries
- Chunk archive written to `memory/archive/chunks/YYYY-MM-DD.md` via `dream-cycle.sh chunk`
- Source observations archived; a single chunk hook replaces them in `observations.md`
- **Production metrics (2026-02-26):**
  - 74.9% token reduction (11,015 → 2,769 tokens)
  - 6 chunks created from 36 source observations
  - Zero false archives
  - All validation gates passing

### Coming Next
- **WP2: Importance Decay** — per-type daily decay on `dc:importance` scores (in development)
- **Pattern Promotion** — recurring observations automatically promoted to `habit` or `rule` type

## [1.2.0] - 2026-02-25

### Added
- Configurable LLM provider support via environment variables
  - `LLM_BASE_URL` - API endpoint (default: OpenRouter)
  - `LLM_API_KEY` - API key (default: falls back to OPENROUTER_API_KEY)
  - `LLM_MODEL` - Model name (default: google/gemini-2.5-flash)
- Works with any OpenAI-compatible API: Ollama, LM Studio, Together.ai, Groq, etc.

### Changed
- Observer and Reflector scripts now use configurable endpoints instead of hardcoded OpenRouter

### Experimental (not yet production-tested)
- Dream Cycle Phase 2 chunking infrastructure (`cmd_chunk`, Stage 4b prompt)
- Will be promoted to stable after validation passes

## [v1.1.0] — 2026-02-23

### Added
- **Dream Cycle (Layer 6)** — nightly memory consolidation at 2:30am
  - 9-stage pipeline: Preflight, Read, Classify, Collapse duplicates, Future-date protection, Archive, Semantic hooks, Write, Validate
  - Git snapshot before every write (automatic rollback on failure)
  - Semantic hooks left behind for searchable archive references
  - Dream logs and metrics JSON output
  - Phase 2 type classification support (feature-flagged via `DREAM_PHASE` env var)
- `scripts/dream-cycle.sh` — file operations helper (archive, update, validate, rollback)
- `prompts/dream-cycle-prompt.md` — full agent prompt for the Dreamer
- `schemas/observation-format.md` — extended observation metadata format
- Setup script now creates dream cycle directories
- README, SKILL.md updated with dream cycle docs and setup instructions

### Fixed
- Hardcoded workspace paths in dream cycle prompt replaced with portable `$SKILL_DIR` variables
- Broken script path in `config/memory-flush.json`
- Wrong path in `templates/AGENTS-snippet.md`

### Results (3 nights, production data)
| Night | Tokens before | Tokens after | Reduction | False archives |
|-------|--------------|--------------|-----------|----------------|
| Night 1 (dry run) | 9,445 | 8,309 | 12% | 0 |
| Night 2 (dry run) | 16,900 | 6,800 | 60% | 0 |
| Night 3 (live) | 11,688 | 2,930 | 75% | 0 |

## [v1.0.0] — 2026-02-18

### Added
- Initial release: Observer, Reflector, Session Recovery, Reactive Watcher
- 5-layer redundancy architecture
- Cross-platform support (Linux + macOS)
- One-command setup via `scripts/setup.sh`
- ClawdHub publication
