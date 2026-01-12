# Video Identifier Refactor Plan

## Overview

Replace the current 9-step bash pipeline with a cleaner orchestrator and steps that populate the new JSON metadata schema (`disk-metadata.json` and `<video>.metadata.json`).

**Tech Stack:** Bash for orchestration and shell operations, TypeScript for data processing and API calls.

---

## New Directory Structure

```
/video-identifier/
├── orchestrator.sh              # Main entry point
├── lib/
│   ├── common.sh                # Shared bash utilities
│   └── ts/                      # TypeScript modules
│       ├── package.json
│       ├── tsconfig.json
│       ├── metadata.ts          # JSON read/write helpers
│       ├── llm.ts               # LLM API client
│       ├── imdb.ts              # IMDB database queries
│       └── tmdb.ts              # TMDB API client
├── steps/
│   ├── step1-init.sh            # Initialize metadata & extract subtitles
│   ├── step2-analyze-subtitles.ts   # Gap detection & play-all detection
│   ├── step3-analyze-disk.ts    # Disk structure analysis
│   ├── step4-extract-nouns.ts   # LLM proper noun extraction
│   ├── step5-imdb-search.ts     # IMDB candidate search
│   ├── step6-generate-synopsis.ts   # LLM plot synopsis generation
│   ├── step7-match-content.ts   # LLM content matching
│   ├── step8-tmdb-validate.ts   # TMDB API validation
│   └── step9-output.sh          # Generate Jellyfin output
└── DOC/
    ├── disk-metadata-schema.md  # Schema documentation
    └── pipeline-plan.md         # This file
```

---

## Orchestrator Design

### orchestrator.sh

```bash
#!/bin/bash
# Main orchestrator - runs steps sequentially, checks status after each

DISK_DIR="${1:?Usage: orchestrator.sh <disk_directory>}"

# Steps array - each step updates disk-metadata.json status
STEPS=(
  "step1-init.sh"
  "step2-analyze-subtitles.ts"
  "step3-analyze-disk.ts"
  "step4-extract-nouns.ts"
  "step5-imdb-search.ts"
  "step6-generate-synopsis.ts"
  "step7-match-content.ts"
  "step8-tmdb-validate.ts"
  "step9-output.sh"
)

for i in "${!STEPS[@]}"; do
  step_num=$((i + 1))
  step_file="${STEPS[$i]}"

  # Check if should skip (already completed or error)
  if should_skip_step "$DISK_DIR" "$step_num"; then
    continue
  fi

  # Update status to in_progress
  update_status "$DISK_DIR" "$step_num" "in_progress"

  # Run step (bash or TypeScript)
  if [[ "$step_file" == *.ts ]]; then
    npx ts-node "steps/$step_file" "$DISK_DIR"
  else
    bash "steps/$step_file" "$DISK_DIR"
  fi

  exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    update_status "$DISK_DIR" "$step_num" "error" "Step failed with code $exit_code"
    exit $exit_code
  fi

  # Mark completed
  update_status "$DISK_DIR" "$step_num" "completed"
done

echo "Pipeline completed successfully"
```

---

## Step Definitions

### Step 1: Initialize & Extract Subtitles (Bash)
**File:** `step1-init.sh`

**Purpose:** Create initial JSON files and extract subtitles from MKVs

**Actions:**
1. Create `disk-metadata.json` with:
   - version, generated timestamp
   - disk.name (from directory or MKV metadata)
   - disk.name_parsed (parse season/disc from name)
   - disk.source_path
   - status.current_step = 1

2. For each MKV file, create `<video>.metadata.json` with:
   - version, generated
   - filename
   - duration_seconds, duration_minutes (from mkvmerge -J)
   - subtitles.languages = [] (populated next)

3. Extract subtitles from each MKV:
   - Detect subtitle type (VOBSUB, PGS, text)
   - Extract to SRT (OCR if needed via Tesseract/pgsrip)
   - Update subtitles.languages array

**Outputs:**
- `disk-metadata.json` (initial)
- `<video>.metadata.json` for each MKV
- `*.srt` subtitle files

---

### Step 2: Analyze Subtitles (TypeScript)
**File:** `step2-analyze-subtitles.ts`

**Purpose:** Parse SRT files to detect gaps and segments

**Actions:**
1. For each video metadata file:
   - Parse corresponding SRT file(s)
   - **Adaptive gap detection:**
     - Collect all inter-subtitle gaps
     - Calculate median and standard deviation of gaps
     - Flag gaps that are statistical outliers (>3 std dev above median, or >10x median)
     - This adapts to different content types automatically
   - Calculate segment durations between significant gaps
   - Update: subtitles.gaps[], subtitles.segments[], subtitles.gap_stats{}

   **Alternative approaches (if adaptive doesn't work well):**
   - Fixed threshold (e.g., >45 seconds)
   - Percentage-based (gap > 1% of video duration)
   - Multi-pass with manual threshold adjustment per disk

2. Extract dialogue text:
   - **Use English subtitles only** (eng/en language codes)
   - Strip timestamps and formatting
   - Save as `<video>.dialogue.txt` (for LLM processing)

**Updates to `<video>.metadata.json`:**
```json
{
  "subtitles": {
    "languages": ["eng", "spa"],
    "gap_stats": {
      "total_gaps": 847,
      "median_gap_seconds": 2.1,
      "std_dev_seconds": 1.8,
      "outlier_threshold_seconds": 7.5
    },
    "gaps": [
      {"position_seconds": 2700, "gap_duration_seconds": 95, "is_outlier": true}
    ],
    "segments": [2700, 2700]
  }
}
```

---

### Step 3: Analyze Disk Structure (TypeScript)
**File:** `step3-analyze-disk.ts`

**Purpose:** Analyze video durations and detect patterns

**Actions:**
1. Read all video metadata files
2. Calculate `videos_summary`:
   - total_count
   - durations_seconds array
   - Identify outliers (short intros, long play-all)
   - Calculate main_content stats (mean, variance, std_dev)
   - Detect play_all (duration ≈ sum of others)
   - Determine pattern (episodic, single_feature, mixed)

3. Build `episode_hints`:
   - Sort videos by filename for assumed_order
   - Set starting_episode from disk name or default to 1
   - Set season_hint from disk.name_parsed
   - Initialize multi_part_groups = []

4. Set initial `content_type` guess based on pattern

5. Mark `is_play_all` in video metadata files

**Updates to `disk-metadata.json`:**
- videos_summary (complete)
- episode_hints (initial)
- content_type (initial guess)

**Updates to `<video>.metadata.json`:**
- is_play_all

---

### Step 4: Extract Proper Nouns (TypeScript)
**File:** `step4-extract-nouns.ts`

**Purpose:** Use LLM to extract character names and proper nouns from dialogue

**Actions:**
1. For each video (skip play-all):
   - Read `<video>.dialogue.txt`
   - Call LLM to extract proper nouns with occurrence counts
   - Update video metadata: proper_nouns

2. Aggregate all proper nouns to disk level:
   - Sum counts across all videos
   - Update disk-metadata.json: proper_nouns

**LLM Prompt:**
```
Extract all proper nouns (character names, place names, organization names)
from this dialogue. Return as JSON: {"name": count, ...}

[dialogue text]
```

**Updates:**
- `<video>.metadata.json`: proper_nouns
- `disk-metadata.json`: proper_nouns (aggregated)

---

### Step 5: IMDB Candidate Search (TypeScript)
**File:** `step5-imdb-search.ts`

**Purpose:** Search IMDB database for matching titles

**Actions:**
1. Build search criteria from:
   - disk.name_parsed.title
   - Top proper nouns (character names)
   - Main content durations
   - content_type guess

2. Query IMDB database:
   - Search by title keywords (from `disk.name_parsed.title` if available - **often not useful or missing**)
   - Search by character names (more reliable - use top proper nouns to find matching cast)
   - **Search both movie AND TV types** - don't filter exclusively by content_type guess
     - Many franchises have both (e.g., Superman has movies and TV series)
     - Let the matching/scoring determine correct type
   - Score by character name matches (proper nouns vs IMDB cast)
   - Score by runtime match (video duration vs IMDB runtime)
   - Include type in results but don't exclude based on initial guess

3. Update disk-metadata.json:
   - imdb_candidates array (top 10-20 matches)
   - Refine content_type based on best matches

**Updates to `disk-metadata.json`:**
```json
{
  "imdb_candidates": [
    {"tconst": "tt0944947", "title": "Game of Thrones", "year": 2011, "type": "tvSeries", "score": 95.5}
  ],
  "content_type": "tv"
}
```

---

### Step 6: Generate Plot Synopses (TypeScript)
**File:** `step6-generate-synopsis.ts`

**Purpose:** Generate LLM plot summaries for each video

**Actions:**
1. For each video where is_play_all = false:
   - Read dialogue text
   - Call LLM to generate plot synopsis (300-500 words)
   - Update video metadata: plot_synopsis

2. For play-all videos:
   - Set plot_synopsis = "skipped:play_all"

**LLM Prompt:**
```
Based on this dialogue from a video, write a plot synopsis (300-500 words)
that captures the main story, characters, and key events.

[dialogue text]
```

**Updates to `<video>.metadata.json`:**
- plot_synopsis

---

### Step 7: Match Content to IMDB (TypeScript)
**File:** `step7-match-content.ts`

**Purpose:** Use LLM judgment to match videos to IMDB candidates

**Data Sources:**
- **Local IMDB database** (MariaDB with imported IMDB datasets from datasets.imdbws.com)
- No external API needed - all IMDB data is queried locally
- Episode synopses/titles come from `title_basics` and `title_episode` tables

**Actions:**
1. For each video (not play-all):
   - Get our LLM-generated `plot_synopsis`
   - Get `imdb_candidates` from disk metadata
   - For TV: fetch episode list from local IMDB database (titles, synopses, season/episode numbers)
   - **LLM uses judgment** to compare our synopsis against IMDB data:
     - Plot similarity
     - Character name matches
     - Runtime alignment
     - Episode order context
   - Populate matches array with scores and reasoning

2. Use episode_hints to improve matching:
   - If position=1 and starting_episode=1, bias toward S01E01
   - If previous video matched E01, this one likely E02

3. Detect multi-part episodes:
   - Look for "Part 1", "Part 2" in IMDB titles
   - Group consecutive videos with same base title
   - Update episode_hints.multi_part_groups

4. Update episode_hints.sequential_confidence based on match consistency

**LLM Prompt:**
```
Match this plot synopsis to the most likely IMDB entry.
Consider: character names, plot points, episode order.

Synopsis: [plot_synopsis]

Candidates:
1. tt1234567 - "Episode Title" (S01E01) - "IMDB synopsis..."
2. ...

Return JSON: [{"imdb_id": "tt...", "confidence": "high|medium|low", "score": 95, "reasoning": "..."}]
```

**Updates:**
- `<video>.metadata.json`: matches[]
- `disk-metadata.json`: episode_hints.multi_part_groups, sequential_confidence

---

### Step 8: TMDB Validation & Synopsis Comparison (TypeScript)
**File:** `step8-tmdb-validate.ts`

**Purpose:** Cross-validate matches with TMDB API and use LLM to compare synopses

**Actions:**
1. For each video with matches:
   - Get **top 3 matches** from matches array
   - Look up each IMDB ID in TMDB API (find by external ID)
   - Fetch TMDB overview (synopsis) for each

2. **LLM Synopsis Comparison:**
   - Provide LLM with:
     - Our generated `plot_synopsis`
     - TMDB synopses for top 3 candidates
   - LLM compares and ranks which TMDB synopsis best matches ours
   - This can confirm or re-rank the matches

3. Update tmdb_validation:
   - Record validation for best match
   - Note if LLM comparison changed the ranking
   - Compare: title, year, runtime, season/episode
   - Calculate confidence based on synopsis match + metadata match

**TMDB API Calls:**
- `GET /find/{imdb_id}?external_source=imdb_id`
- `GET /movie/{tmdb_id}` or `GET /tv/{tmdb_id}/season/{s}/episode/{e}`

**LLM Prompt for Synopsis Comparison:**
```
Compare our plot synopsis against these 3 TMDB synopses.
Which one is the best match?

Our Synopsis:
[plot_synopsis]

Candidate 1 (tt1480055 - "Winter Is Coming" S01E01):
[tmdb_overview_1]

Candidate 2 (tt1668746 - "The Kingsroad" S01E02):
[tmdb_overview_2]

Candidate 3 (tt1829962 - "Lord Snow" S01E03):
[tmdb_overview_3]

Return JSON: {
  "best_match": "tt1480055",
  "confidence": "high",
  "reasoning": "Plot points about King Robert's visit match..."
}
```

**Updates to `<video>.metadata.json`:**
```json
{
  "tmdb_validation": {
    "confidence": "high",
    "imdb_id": "tt1480055",
    "tmdb_id": 63056,
    "tmdb_type": "tv",
    "tmdb_title": "Winter Is Coming",
    "tmdb_year": 2011,
    "tmdb_season": 1,
    "tmdb_episode": 1,
    "tmdb_overview": "...",
    "runtime_match": true,
    "discrepancies": [],
    "api_error": null
  }
}
```

---

### Step 9: Output Generation (Bash)
**File:** `step9-output.sh`

**Purpose:** Generate Jellyfin-compatible output structure

**Actions:**
1. Determine best_match for disk:
   - For TV: use series info from most confident matches
   - For movies: use best match from main feature video

2. Create output directory structure:
   - Movies: `/output/Movies/Title (Year) [imdbid-ttXXX]/`
   - TV: `/output/Shows/Series (Year) [imdbid-ttXXX]/Season XX/`

3. For each video with matches:
   - Create hard link or copy to output
   - Rename to Jellyfin format
   - **Copy ALL subtitle files** (all languages, not just English)
   - Convert language codes: eng→en, spa→es, fra→fr, etc.

4. **Handle extras and unknown videos:**
   - Videos without matches → copy to `extras/` folder
   - Play-all videos → copy to `extras/`
   - Short clips/intros → copy to `extras/`
   - Include all SRT files for extras as well

5. **Handle unidentified disks:**
   - If no match score is above 60, OR `best_match` is null, OR `status.error` is set:
     - Copy entire disk contents to `/output/unknown/DISK_NAME/`
     - Preserve all metadata JSON files for manual review
     - Preserve all SRT files
   - Set `status.output_complete = true` and `status.output_location = "unknown"`

6. Update disk-metadata.json:
   - best_match
   - status.output_complete = true
   - status.output_location ("movies", "shows", or "unknown")

**Unknown Disk Output Structure:**
```
/output/unknown/
├── GAME_OF_THRONES_S01_D1/          # Disk that failed identification
│   ├── disk-metadata.json           # Preserved for manual review
│   ├── title_t00.mkv
│   ├── title_t00.metadata.json
│   ├── title_t00.en.srt
│   ├── title_t01.mkv
│   ├── title_t01.metadata.json
│   └── ...
└── UNKNOWN_DISC_2/
    └── ...
```

**Unknown Disk Criteria (any of these):**
- No match has a score above 60
- `best_match` is null after Step 7
- All videos have empty `matches[]` arrays
- `status.error` is set (pipeline failed at any step)

**Movie Output Structure:**
```
/output/Movies/Inception (2010) [imdbid-tt1375666]/
├── Inception (2010) [imdbid-tt1375666].mkv
├── Inception (2010) [imdbid-tt1375666].en.srt
├── Inception (2010) [imdbid-tt1375666].es.srt
├── Inception (2010) [imdbid-tt1375666].fr.srt
└── extras/
    ├── title_t00.mkv              # Short intro
    ├── title_t00.en.srt
    ├── title_t02.mkv              # Behind the scenes
    └── title_t02.en.srt
```

**Multiple Cuts/Editions (Director's Cut, Extended, etc.):**

Jellyfin supports multiple versions of the same movie in one folder using suffix notation:
```
/output/Movies/Blade Runner (1982) [imdbid-tt0083658]/
├── Blade Runner (1982) [imdbid-tt0083658] - [Theatrical Cut].mkv
├── Blade Runner (1982) [imdbid-tt0083658] - [Directors Cut].mkv
├── Blade Runner (1982) [imdbid-tt0083658] - [Final Cut].mkv
└── extras/
```

**Detection Challenge - NOT YET SOLVED:**
- How do we detect which cut a video is?
- Possible indicators:
  - Runtime differences (Director's cuts are usually longer)
  - Multiple feature-length videos with similar durations (~5-15 min difference)
  - IMDB/TMDB may list different runtimes for different cuts
  - Disk name might contain "Directors Cut" or "Extended"
- **Current approach:** If multiple feature-length videos match the same movie, place longest in main, others in extras with original filename
- **Future enhancement:** Add edition detection logic and proper Jellyfin suffix naming

**TV Output Structure:**
```
/output/Shows/Game of Thrones (2011) [imdbid-tt0944947]/
├── Season 01/
│   ├── Game of Thrones S01E01 Winter Is Coming.mkv
│   ├── Game of Thrones S01E01 Winter Is Coming.en.srt
│   ├── Game of Thrones S01E01 Winter Is Coming.es.srt
│   ├── Game of Thrones S01E02 The Kingsroad.mkv
│   ├── Game of Thrones S01E02 The Kingsroad.en.srt
│   └── Game of Thrones S01E02 The Kingsroad.es.srt
└── extras/
    ├── title_t02.mkv              # Play-all video
    ├── title_t02.en.srt
    ├── title_t05.mkv              # Unmatched/unknown video
    └── title_t05.en.srt
```

---

## Data Flow Summary

```
Step 1 (Bash)
├── Creates: disk-metadata.json (initial)
├── Creates: <video>.metadata.json (initial)
└── Creates: *.srt files

Step 2 (TS)
└── Updates: <video>.metadata.json (subtitles.gaps, segments)

Step 3 (TS)
├── Updates: disk-metadata.json (videos_summary, episode_hints, content_type)
└── Updates: <video>.metadata.json (is_play_all)

Step 4 (TS)
├── Updates: <video>.metadata.json (proper_nouns)
└── Updates: disk-metadata.json (proper_nouns aggregated)

Step 5 (TS)
└── Updates: disk-metadata.json (imdb_candidates, content_type refined)

Step 6 (TS)
└── Updates: <video>.metadata.json (plot_synopsis)

Step 7 (TS)
├── Updates: <video>.metadata.json (matches[])
└── Updates: disk-metadata.json (episode_hints.multi_part_groups)

Step 8 (TS)
└── Updates: <video>.metadata.json (tmdb_validation)

Step 9 (Bash)
├── Updates: disk-metadata.json (best_match, status.output_complete)
└── Creates: Jellyfin output structure
```

---

## TypeScript Module Structure

### lib/ts/metadata.ts
```typescript
// Read/write JSON metadata files
export function readDiskMetadata(diskDir: string): DiskMetadata;
export function writeDiskMetadata(diskDir: string, data: DiskMetadata): void;
export function readVideoMetadata(diskDir: string, filename: string): VideoMetadata;
export function writeVideoMetadata(diskDir: string, filename: string, data: VideoMetadata): void;
export function getAllVideoMetadata(diskDir: string): VideoMetadata[];
export function updateStatus(diskDir: string, step: number, status: string, error?: string): void;
```

### lib/ts/llm.ts
```typescript
// LLM API client (OpenAI-compatible)
export async function extractProperNouns(dialogue: string): Promise<Record<string, number>>;
export async function generateSynopsis(dialogue: string): Promise<string>;
export async function matchToIMDB(synopsis: string, candidates: IMDBCandidate[]): Promise<Match[]>;
```

### lib/ts/imdb.ts
```typescript
// IMDB database queries
export async function searchByTitle(title: string, type?: string): Promise<IMDBCandidate[]>;
export async function searchByCharacters(characters: string[]): Promise<IMDBCandidate[]>;
export async function getEpisodeList(seriesId: string, season?: number): Promise<Episode[]>;
export async function getTitleDetails(tconst: string): Promise<TitleDetails>;
```

### lib/ts/tmdb.ts
```typescript
// TMDB API client
export async function findByIMDBId(imdbId: string): Promise<TMDBResult | null>;
export async function getMovieDetails(tmdbId: number): Promise<MovieDetails>;
export async function getEpisodeDetails(tmdbId: number, season: number, episode: number): Promise<EpisodeDetails>;
```

---

## Error Handling

Each step updates `status` in disk-metadata.json:
```json
{
  "status": {
    "current_step": 5,
    "completed_steps": [1, 2, 3, 4],
    "error": null,
    "output_complete": false
  }
}
```

On error:
```json
{
  "status": {
    "current_step": 5,
    "completed_steps": [1, 2, 3, 4],
    "error": "IMDB connection failed: timeout",
    "output_complete": false
  }
}
```

Orchestrator checks status before each step and can resume from last completed.

---

## Verification

1. Run on known TV disc (multi-episode)
   - Verify episode_hints.assumed_order is correct
   - Verify matches[] populated for each video
   - Verify tmdb_validation confidence is high
   - Verify Jellyfin output structure correct

2. Run on known movie disc
   - Verify content_type = "movie"
   - Verify single main feature identified
   - Verify outliers correctly identified
   - Verify output naming correct

3. Run on disc with play-all
   - Verify play_all_detected = true
   - Verify is_play_all = true on correct video
   - Verify plot_synopsis = "skipped:play_all"
   - Verify play-all excluded from output

4. Run on disc with multi-part episode
   - Verify multi_part_groups populated
   - Verify Part 1 and Part 2 matched correctly
