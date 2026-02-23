# Changelog

All notable changes to Total Recall are documented here.

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
