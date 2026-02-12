# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

FuzzyMatcher is a high-performance fuzzy string matching library for Swift. It provides two matching modes — **Damerau-Levenshtein edit distance** (default, penalty-driven) and **Smith-Waterman local alignment** (bonus-driven) — both with multi-stage prefiltering and zero-allocation hot paths.

**Requirements:** Swift 6.2+, macOS 26+

## Build Commands

```bash
swift build                    # Debug build
swift build -c release         # Release build
swift test                     # Run all tests
swift test --filter TestName   # Run specific test (e.g., --filter EditDistanceTests)
swift package --package-path Benchmarks benchmark  # Run benchmarks (builds release first)
```

## Architecture

### Matching Modes

The library supports two matching algorithms selected via `MatchConfig.algorithm`:

- **Edit Distance** (default) — Penalty-driven scoring using Damerau-Levenshtein. Multi-phase pipeline: exact → prefix → substring → subsequence → acronym. Best for typo tolerance, prefix-aware search, and short queries.
- **Smith-Waterman** — Bonus-driven local alignment (similar to nucleo/fzf). Single DP pass + acronym fallback. Best for multi-word queries, high throughput, and code/file search.

Both modes share the same API surface, zero-allocation hot path, and `score(_:against:buffer:)` entry point. See `MATCHING_MODES.md` for a detailed comparison.

### Core Components

The library follows a pipeline architecture:

1. **Query Preparation** (`FuzzyQuery.swift`) - Precomputes lowercased form, character bitmask, trigrams, and `containsSpaces` flag for the query
2. **Prefiltering** (`Prefilters.swift`) - Three-stage fast rejection: length bounds (O(1)), 37-bit character bitmask (O(1)), trigram similarity (O(n))
3. **Edit Distance** (`EditDistance.swift`) - Damerau-Levenshtein with prefix and substring variants using rolling array optimization
4. **Smith-Waterman** (`SmithWaterman.swift`, `FuzzyMatcher+SmithWaterman.swift`) - Local alignment DP with tiered boundary bonuses, multi-word atom splitting, and integer arithmetic
5. **Scoring** (`ScoringBonuses.swift`, `WordBoundary.swift`) - Position-based bonuses for word boundaries, consecutive matches, and gap penalties (edit distance mode)
6. **Acronym Matching** (`FuzzyMatcher.swift`) - Word-initial character matching for abbreviations (e.g., "bms" → "Bristol-Myers Squibb") — used by both modes
7. **Result** (`ScoredMatch.swift`, `MatchKind.swift`) - Final score (0.0-1.0) with match type (exact/prefix/substring/acronym)

### Key Design Patterns

- **Zero-allocation hot path**: `ScoringBuffer` provides reusable arrays for the score() method
- **Thread safety**: All types are `Sendable`; each thread uses its own buffer
- **UTF-8 processing**: Direct byte operations via `withContiguousStorageIfAvailable` for performance
- **Prepare-once pattern**: Query preparation is separate from scoring for repeated use

### Main Entry Point

`FuzzyMatcher.swift` orchestrates the edit distance scoring pipeline via decomposed phase methods (`checkExactMatch`, `scorePrefix`, `scoreSubstring`, `scoreSubsequence`, `scoreAcronym`) coordinated through a `ScoringState` struct. `FuzzyMatcher+SmithWaterman.swift` handles Smith-Waterman scoring with a single DP pass and optional atom splitting. `FuzzyMatcher+Convenience.swift` provides convenience wrappers. The `score(_:against:buffer:)` method dispatches to the appropriate implementation based on `MatchConfig.algorithm`.

**High-performance API** (zero allocations — use for hot paths):
```swift
// Edit distance (default)
let matcher = FuzzyMatcher()
// Smith-Waterman mode
let swMatcher = FuzzyMatcher(config: .smithWaterman)

let query = matcher.prepare("searchTerm")
var buffer = matcher.makeBuffer()
if let match = matcher.score(candidate, against: query, buffer: &buffer) { ... }
```

**Convenience API** (allocates internally — use for quick use or small sets):
```swift
let matcher = FuzzyMatcher()
if let match = matcher.score("candidate", against: "search") { ... }
let top5 = matcher.topMatches(candidates, against: query, limit: 5)
let all = matcher.matches(candidates, against: query)
```

### Configuration

`MatchConfig.swift` selects the matching algorithm and contains shared + mode-specific parameters:

**Shared:** `minScore` (default: 0.3)

**Edit Distance** (`EditDistanceConfig`):
- `maxEditDistance` (2), `longQueryMaxEditDistance` (3), `longQueryThreshold` (13)
- `prefixWeight` (1.5), `substringWeight` (1.0), `acronymWeight` (1.0)
- `wordBoundaryBonus` (0.1), `consecutiveBonus` (0.05)
- `gapPenalty` (`.affine(open: 0.03, extend: 0.005)`)
- `firstMatchBonus` (0.15), `firstMatchBonusRange` (10), `lengthPenalty` (0.003)

**Smith-Waterman** (`SmithWatermanConfig`):
- `scoreMatch` (16), `penaltyGapStart` (3), `penaltyGapExtend` (1)
- `bonusConsecutive` (4), `bonusBoundary` (8), `bonusBoundaryWhitespace` (10), `bonusBoundaryDelimiter` (9), `bonusCamelCase` (5)
- `bonusFirstCharMultiplier` (2), `splitSpaces` (true)

## Testing

Tests use Swift Testing framework (`@Test` macro, `#expect()` assertions). Test files mirror source structure:
- `EditDistanceTests.swift` - Core edit distance algorithm tests
- `SmithWatermanTests.swift` - Smith-Waterman alignment and scoring tests
- `PrefilterTests.swift` / `TrigramTests.swift` - Fast rejection tests
- `ScoringBonusTests.swift` / `WordBoundaryTests.swift` - Ranking tests (edit distance mode)
- `AcronymMatchTests.swift` - Word-initial abbreviation matching tests
- `EdgeCaseTests.swift` - Boundary conditions

## Performance

**Always benchmark before and after any performance-related change.** Do not speculatively optimize without measuring.

For **iterative performance work**, use the comparison benchmark suite against nucleo (Rust) — this gives realistic per-category timings against a real competitor on the full 271K instrument corpus:

```bash
bash Comparison/run-benchmarks.sh --fm-ed --nucleo  # Quick: FuzzyMatch(ED) vs nucleo only
bash Comparison/run-benchmarks.sh                # Full: all matchers
```

The Swift Package Benchmarks (`swift package --package-path Benchmarks benchmark`) measure micro-benchmarks and concurrency scenarios, but the comparison suite is the primary tool for evaluating real-world performance during development.

Compare results before and after your change. If a "performance optimization" shows no improvement or causes a regression, roll it back.

When updating tables in `COMPARISON.md`, always re-run both scripts and update from their output:

```bash
bash Comparison/run-benchmarks.sh   # Performance comparison (nucleo, RapidFuzz, FuzzyMatch)
python3 Comparison/run-quality.py   # Quality comparison (FuzzyMatcher, nucleo, RapidFuzz, fzf)
```

Update the hardware/OS info block in `COMPARISON.md` each time. Take numbers directly from script output — do not hand-edit the tables.

## Comparison Suite Prerequisites

Running the comparison benchmarks and quality scripts (`Comparison/run-benchmarks.sh`, `Comparison/run-quality.py`) requires:

- **Rust** (for nucleo benchmarks): `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`
- **rapidfuzz-cpp** (for RapidFuzz benchmarks): `brew install rapidfuzz-cpp`
- **fzf** (for quality comparison): `brew install fzf`

## Fuzzing

The `Fuzz/` directory contains a libFuzzer-based fuzz target that validates invariants (score range, self-match, buffer reuse, etc.) over random inputs. **Linux only** — Swift's `-sanitize=fuzzer` requires the open-source toolchain, not Xcode.

```bash
bash Fuzz/run.sh              # build only
bash Fuzz/run.sh run          # build + run (Ctrl-C to stop)
bash Fuzz/run.sh run -max_total_time=300  # run for 5 minutes
```

## Adding Test Queries

All benchmark and quality queries live in `Resources/queries.tsv` (4-column TSV: `query\tfield\tcategory\texpected_name`). This single file drives:
- Performance benchmarks (`Comparison/bench-fuzzymatch`, `bench-nucleo`, `bench-rapidfuzz`)
- Quality comparison (`Comparison/run-quality.py`) — including ground truth evaluation

To add a new query, append a line to `queries.tsv`:
```
Goldman Sachs	name	exact_name	Goldman Sachs
```

**Fields:**
- Column 1: `query` — the search text
- Column 2: `field` — which corpus field to search (`symbol`, `name`, or `isin`)
- Column 3: `category` — one of the 9 categories below
- Column 4: `expected_name` — ground truth expected result name (case-insensitive substring match against result names)

**Ground truth rules:**
- `expected_name` is matched as a **case-insensitive substring** against result `name` fields. This avoids brittleness from symbol prefixes (`4AAPL`) and name variations.
- **Top-N**: Top-1 for `exact_name`, `exact_isin`, `substring`, and `multi_word`. Top-5 for `typo`, `prefix`, and `abbreviation` — these categories produce many equally-valid candidates (tied edit distances, ambiguous short prefixes, literal substring matches competing with acronyms) where the correct result anywhere in the top 5 is a success for search UX.
- **`_SKIP_`**: Use for queries with no definitive expected answer — exact symbol lookups (any instrument with the matching symbol is valid), symbol-with-spaces derivatives, and single-char/short ambiguous prefix queries.
- When adding a query, **always include the expected_name column**.

Valid fields: `symbol`, `name`, `isin`

Categories (9):
- `exact_symbol` — user knows the exact ticker (AAPL, JPM, SHEL)
- `exact_name` — user types company name, proper or lowercase (Goldman Sachs, apple, berkshire hathaway)
- `exact_isin` — ISIN lookup, full or partial prefix (US0378331005, US59491)
- `prefix` — progressive typing, first few chars (gol, berks, ishare, AA)
- `typo` — misspellings: transpositions, dropped chars, adjacent keys, doubled chars (Goldamn, blakstone, Voeing, Gooldman)
- `substring` — keyword that appears within longer names (DAX, Bond, ETF, iShares, High Yield)
- `multi_word` — multi-word descriptive search for fund products (ishares usd treasury, vanguard ftse europe)
- `symbol_spaces` — derivative-style symbols with spaces (AP7 X6)
- `abbreviation` — first letter of each word in long company names (icag for International Consolidated Airlines Group, bms for Bristol-Myers Squibb)

No other files need editing — all harnesses load queries from the TSV at runtime (they ignore the 4th column).

## Documentation

- `DAMERAU_LEVENSHTEIN.md` - Detailed Damerau-Levenshtein algorithm documentation with pseudocode and complexity analysis
- `SMITH_WATERMAN.md` - Smith-Waterman local alignment algorithm documentation
- `MATCHING_MODES.md` - High-level comparison of both matching modes

## Prepare Release

When asked to "prepare release", execute the following steps. **Maximize parallelism** — benchmarks and quality runs are independent of each other and of the documentation review tasks, so launch them concurrently.

1. **Clean stale results**: Remove old benchmark and quality output files from `/tmp/` to ensure fresh data. **Ask the user for confirmation before deleting.**
   ```bash
   rm -f /tmp/bench-*-latest.txt /tmp/quality-*-latest.json
   ```
2. **Run all tests**: `swift test` — all tests must pass before proceeding.
3. **Build all harnesses** (sequential, one-time — prevents concurrent build races):
   ```bash
   swift build -c release --package-path Comparison/bench-fuzzymatch
   (cd Comparison/bench-nucleo && cargo build --release)
   make -C Comparison/bench-rapidfuzz
   (cd Comparison/quality-fuzzymatch && swift build -c release)
   (cd Comparison/quality-nucleo && cargo build --release)
   make -C Comparison/quality-rapidfuzz
   ```
4. **Run benchmarks and quality in parallel with `--skip-build`**: Launch each matcher/mode as a separate background process to utilize all cores. Both scripts support per-matcher flags (`--fm-ed`, `--fm-sw`, `--nucleo`, `--rf-wratio`, `--rf-partial`, `--fzf`) and `--skip-build` to skip the build step (already done in step 3). Use `--fm` or `--rf` as shorthand to run both modes of a matcher:

   **Performance benchmarks** (5 parallel processes):
   ```bash
   bash Comparison/run-benchmarks.sh --fm-ed --skip-build
   bash Comparison/run-benchmarks.sh --fm-sw --skip-build
   bash Comparison/run-benchmarks.sh --nucleo --skip-build
   bash Comparison/run-benchmarks.sh --rf-wratio --skip-build
   bash Comparison/run-benchmarks.sh --rf-partial --skip-build
   ```

   **Quality comparison** (6 parallel processes):
   ```bash
   python3 Comparison/run-quality.py --fm-ed --skip-build
   python3 Comparison/run-quality.py --fm-sw --skip-build
   python3 Comparison/run-quality.py --nucleo --skip-build
   python3 Comparison/run-quality.py --rf-wratio --skip-build
   python3 Comparison/run-quality.py --rf-partial --skip-build
   python3 Comparison/run-quality.py --fzf --skip-build
   ```

   All 11 processes can run concurrently. Use parallel subagents (Task tool with Bash) to launch them simultaneously. While benchmarks run, proceed with documentation review (steps 7-9).

   **Output files**: After parallel runs complete, results are available in `/tmp/`:
   - Performance: `/tmp/bench-fuzzymatch-latest.txt`, `/tmp/bench-fuzzymatch-sw-latest.txt`, `/tmp/bench-nucleo-latest.txt`, `/tmp/bench-rapidfuzz-wratio-latest.txt`, `/tmp/bench-rapidfuzz-partial-latest.txt`
   - Quality: `/tmp/quality-fuzzymatch-latest.json`, `/tmp/quality-fuzzymatch-sw-latest.json`, `/tmp/quality-nucleo-latest.json`, `/tmp/quality-rapidfuzz-wratio-latest.json`, `/tmp/quality-rapidfuzz-partial-latest.json`, `/tmp/quality-fzf-latest.json`

   Read these files to collate results for COMPARISON.md — do not re-run all matchers together just to generate the comparison table.

5. **Run microbenchmarks**: `swift package --package-path Benchmarks benchmark`. Update the microbenchmark table in README.md with fresh numbers.
6. **Update COMPARISON.md**: Once all benchmark and quality runs complete, replace performance and quality tables with fresh output. Update the hardware/OS info block.
7. **Review DAMERAU_LEVENSHTEIN.md and SMITH_WATERMAN.md**: Analyze the current implementation and ensure the algorithm documentation accurately reflects the code — update any sections that are out of date (prefilter pipeline, scoring logic, data structures, complexity analysis, etc.).
8. **Review README.md**: Ensure it reflects the current state of the project — performance claims, feature list, API examples, and any other content that may have changed.
9. **Update DocC documentation**: Review and update all DocC documentation (source-level `///` comments and any `.docc` catalog files) to accurately reflect the current API, parameters, return types, and behavior. Ensure new public APIs are documented and outdated descriptions are corrected.
10. **Report**: Summarize what was updated and any discrepancies found.

Note: Do NOT include Ifrit or Contains in the benchmark or quality runs unless explicitly requested by the user. Both are extremely slow to benchmark and would dominate the runtime. Use existing reference numbers for Ifrit and Contains in COMPARISON.md and only re-run when explicitly asked. Add a note in COMPARISON.md: "Note: Ifrit and Contains were not included in this run. Run with --ifrit --contains for a full comparison."

## Agent Usage

Always use subagents (the Task tool) when possible and beneficial. Prefer launching parallel subagents for independent work such as:
- Exploring multiple files or directories simultaneously
- Running research queries that don't depend on each other
- Investigating separate parts of the codebase in parallel

This maximizes throughput and keeps the main context window focused.
