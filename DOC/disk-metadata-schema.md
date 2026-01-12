# Metadata Schema Specification

Version: 1.0

## Overview

Two types of JSON metadata files are used:
1. **`disk-metadata.json`** - One per disc directory, contains disk-level data
2. **`<videoname>.metadata.json`** - One per video file, contains video-specific data

---

## disk-metadata.json

One file per disc directory containing disk-level identification and aggregated data.

### Schema

```json
{
  "version": "1.0",
  "generated": "<ISO 8601 timestamp>",
  "disk": {
    "name": "<string>",
    "name_parsed": {
      "title": "<string>",
      "season": "<number|null>",
      "disc": "<number|null>"
    },
    "source_path": "<string>"
  },
  "videos_summary": {
    "total_count": "<number>",
    "durations_seconds": ["<number>"],
    "main_content": {
      "count": "<number>",
      "filenames": ["<string>"],
      "durations_seconds": ["<number>"],
      "mean_seconds": "<number>",
      "variance_seconds": "<number>",
      "std_dev_seconds": "<number>"
    },
    "outliers": {
      "short": ["<filename>"],
      "long": ["<filename>"]
    },
    "play_all_detected": {
      "detected": "<boolean>",
      "play_all_file": "<filename|null>",
      "play_all_duration_seconds": "<number|null>",
      "episodes_total_seconds": "<number|null>",
      "difference_seconds": "<number|null>"
    },
    "pattern": "<episodic|single_feature|mixed|unknown>"
  },
  "episode_hints": {
    "assumed_order": [
      {
        "filename": "<string>",
        "position": "<number>",
        "episode_guess": "<number|null>",
        "part_of_multi": "<string|null>"
      }
    ],
    "starting_episode": "<number|null>",
    "season_hint": "<number|null>",
    "multi_part_groups": [
      {
        "group_id": "<string>",
        "parts": ["<filename>"],
        "combined_title_hint": "<string|null>"
      }
    ],
    "sequential_confidence": "<high|medium|low|none>"
  },
  "proper_nouns": {
    "<name>": "<occurrence_count>"
  },
  "content_type": "<movie|tv|hybrid|unknown>",
  "imdb_candidates": [
    {
      "tconst": "<string>",
      "title": "<string>",
      "year": "<number>",
      "type": "<string>",
      "score": "<number>"
    }
  ],
  "best_match": {
    "tconst": "<string>",
    "title": "<string>",
    "year": "<number>",
    "confidence": "<high|medium|low>",
    "reasoning": "<string>"
  },
  "status": {
    "current_step": "<number>",
    "completed_steps": ["<number>"],
    "error": "<string|null>",
    "output_complete": "<boolean>",
    "output_location": "<movies|shows|unknown|null>"
  }
}
```

### Field Descriptions

#### Root Level

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version (currently "1.0") |
| `generated` | string | ISO 8601 timestamp of last update |

#### disk

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Raw disk name (from MKV metadata or directory name) |
| `name_parsed.title` | string | Extracted title from disk name |
| `name_parsed.season` | number\|null | Parsed season number, if detected |
| `name_parsed.disc` | number\|null | Parsed disc number, if detected |
| `source_path` | string | Full path to source directory |

#### videos_summary

Duration analysis across all videos to detect episodic patterns.

| Field | Type | Description |
|-------|------|-------------|
| `total_count` | number | Total number of video files |
| `durations_seconds` | array | All video durations in seconds |
| `main_content.count` | number | Number of videos after removing outliers |
| `main_content.filenames` | array | Filenames of main content videos |
| `main_content.durations_seconds` | array | Durations of main content videos |
| `main_content.mean_seconds` | number | Mean duration of main content |
| `main_content.variance_seconds` | number | Variance in durations |
| `main_content.std_dev_seconds` | number | Standard deviation in durations |
| `outliers.short` | array | Filenames of videos too short (intros, extras) |
| `outliers.long` | array | Filenames of videos too long (compilations, specials) |
| `play_all_detected.detected` | boolean | True if a "play all" concatenated video was found |
| `play_all_detected.play_all_file` | string\|null | Filename of the play-all video |
| `play_all_detected.play_all_duration_seconds` | number\|null | Duration of play-all video |
| `play_all_detected.episodes_total_seconds` | number\|null | Sum of individual episode durations |
| `play_all_detected.difference_seconds` | number\|null | Difference (for validation) |
| `pattern` | string | Detected pattern: episodic, single_feature, mixed, unknown |

**Play-All Detection Logic:**
- If one video's duration ≈ sum of other similar-length videos (within 5%), it's likely a "play all"
- The play-all file should be excluded from episode matching
- Useful for: skipping duplicate processing, validating episode detection

**Pattern Detection Logic:**
- `episodic`: Multiple videos with similar durations (low variance, std_dev < 300s)
- `single_feature`: One long video (>60 min) with optional short extras
- `mixed`: Videos of significantly different lengths
- `unknown`: Insufficient data to determine

#### episode_hints

Inferred episode ordering and multi-part relationships based on disk structure.

| Field | Type | Description |
|-------|------|-------------|
| `assumed_order` | array | Videos in assumed playback order |
| `assumed_order[].filename` | string | Video filename |
| `assumed_order[].position` | number | Position in sequence (1-based) |
| `assumed_order[].episode_guess` | number\|null | Guessed episode number based on position |
| `assumed_order[].part_of_multi` | string\|null | Group ID if part of multi-part episode |
| `starting_episode` | number\|null | First episode number (from disk name or prior disks) |
| `season_hint` | number\|null | Season number hint (from disk name parsing) |
| `multi_part_groups` | array | Detected multi-part episodes (Part 1, Part 2, etc.) |
| `multi_part_groups[].group_id` | string | Unique identifier for the group |
| `multi_part_groups[].parts` | array | Filenames in order (Part 1, Part 2, etc.) |
| `multi_part_groups[].combined_title_hint` | string\|null | Shared title if detected |
| `sequential_confidence` | string | Confidence in episode ordering: high, medium, low, none |

**Episode Ordering Logic:**
- Files sorted by filename (title_t00, title_t01, etc.) typically match episode order
- If disk is "Season 1 Disc 2" and Disc 1 had 4 episodes, starting_episode = 5
- Multi-part detection: Look for "Part 1"/"Part 2" in LLM-generated synopsis or IMDB titles
- Sequential confidence based on: consistent durations, filename patterns, IMDB episode number matches

#### proper_nouns

Aggregated proper nouns across all videos on the disk. Used to narrow down franchise candidates.

```json
"proper_nouns": {
  "Ned Stark": 47,
  "Jon Snow": 38,
  "Winterfell": 15
}
```

#### content_type

| Value | Description |
|-------|-------------|
| `movie` | Single feature film |
| `tv` | TV series episodes |
| `hybrid` | Mixed content (TV movie, special, etc.) |
| `unknown` | Could not determine type |

#### imdb_candidates

Array of potential IMDB matches, sorted by score descending.

| Field | Type | Description |
|-------|------|-------------|
| `tconst` | string | IMDB title ID (e.g., "tt0944947") |
| `title` | string | Primary title |
| `year` | number | Release year |
| `type` | string | IMDB title type (movie, tvSeries, tvMiniSeries, tvMovie, video) |
| `score` | number | Match score (higher is better) |

#### best_match

The selected best match after LLM analysis. Null if not yet determined.

| Field | Type | Description |
|-------|------|-------------|
| `tconst` | string | IMDB title ID |
| `title` | string | Title |
| `year` | number | Release year |
| `confidence` | string | high, medium, or low |
| `reasoning` | string | LLM-generated explanation for the match |

#### status

| Field | Type | Description |
|-------|------|-------------|
| `current_step` | number | Currently executing step (1-9) |
| `completed_steps` | array | List of completed step numbers |
| `error` | string\|null | Error message if pipeline failed |
| `output_complete` | boolean | True if output was successfully generated |
| `output_location` | string\|null | Where output was placed: "movies", "shows", "unknown", or null if not yet output |

---

## <videoname>.metadata.json

One file per video, named to match the video file (e.g., `title_t00.mkv` → `title_t00.metadata.json`).

### Schema

```json
{
  "version": "1.0",
  "generated": "<ISO 8601 timestamp>",
  "filename": "<string>",
  "duration_seconds": "<number>",
  "duration_minutes": "<number>",
  "subtitles": {
    "languages": ["<lang_code>"],
    "gap_stats": {
      "total_gaps": "<number>",
      "median_gap_seconds": "<number>",
      "std_dev_seconds": "<number>",
      "outlier_threshold_seconds": "<number>"
    },
    "gaps": [
      {
        "position_seconds": "<number>",
        "gap_duration_seconds": "<number>",
        "is_outlier": "<boolean>"
      }
    ],
    "segments": ["<duration_seconds>"]
  },
  "is_play_all": "<boolean>",
  "proper_nouns": {
    "<name>": "<occurrence_count>"
  },
  "plot_synopsis": "<string|null|'skipped:play_all'>",
  "matches": [
    {
      "imdb_id": "<string>",
      "type": "<movie|episode>",
      "title": "<string>",
      "year": "<number>",
      "season": "<number|null>",
      "episode": "<number|null>",
      "confidence": "<high|medium|low>",
      "score": "<number>"
    }
  ],
  "tmdb_validation": {
    "confidence": "<high|medium|low|none|null>",
    "imdb_id": "<string|null>",
    "tmdb_id": "<number|null>",
    "tmdb_type": "<movie|tv|null>",
    "tmdb_title": "<string|null>",
    "tmdb_year": "<number|null>",
    "tmdb_season": "<number|null>",
    "tmdb_episode": "<number|null>",
    "tmdb_overview": "<string|null>",
    "runtime_match": "<boolean|null>",
    "discrepancies": ["<string>"],
    "api_error": "<string|null>"
  }
}
```

### Field Descriptions

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version |
| `generated` | string | ISO 8601 timestamp of last update |
| `filename` | string | Video filename (e.g., "title_t00.mkv") |
| `duration_seconds` | number | Video duration in seconds |
| `duration_minutes` | number | Video duration in minutes (rounded) |
| `subtitles.languages` | array | Language codes found (e.g., ["eng", "spa"]) |
| `subtitles.gap_stats` | object | Statistics about all inter-subtitle gaps (for adaptive threshold) |
| `subtitles.gap_stats.total_gaps` | number | Total number of gaps analyzed |
| `subtitles.gap_stats.median_gap_seconds` | number | Median gap duration |
| `subtitles.gap_stats.std_dev_seconds` | number | Standard deviation of gap durations |
| `subtitles.gap_stats.outlier_threshold_seconds` | number | Calculated threshold for significant gaps |
| `subtitles.gaps` | array | Array of significant gaps (statistical outliers) |
| `subtitles.gaps[].position_seconds` | number | Position in video where gap starts |
| `subtitles.gaps[].gap_duration_seconds` | number | Duration of the gap itself |
| `subtitles.gaps[].is_outlier` | boolean | True if gap exceeds outlier threshold |
| `subtitles.segments` | array | Duration of each segment between significant gaps (for pattern detection) |
| `is_play_all` | boolean | True if this video is a concatenated "play all" of other episodes |
| `proper_nouns` | object | Proper nouns in this video with occurrence counts |
| `plot_synopsis` | string\|null | LLM-generated plot summary. Null if not yet generated. Set to "skipped:play_all" if skipped due to being a play-all video |
| `matches` | array | Array of potential IMDB matches, sorted by score descending |
| `tmdb_validation` | object | TMDB API cross-validation results (for best match) |

#### matches

Array of potential IMDB matches for this video. First entry is the best match.

| Field | Type | Description |
|-------|------|-------------|
| `imdb_id` | string | IMDB title ID (e.g., "tt1375666") |
| `type` | string | "movie" or "episode" |
| `title` | string | Episode or movie title |
| `year` | number | Release year |
| `season` | number\|null | Season number (episodes only) |
| `episode` | number\|null | Episode number (episodes only) |
| `confidence` | string | high, medium, or low |
| `score` | number | Match score (higher is better) |

#### tmdb_validation

Cross-validation with TMDB API to confirm IMDB match.

| Field | Type | Description |
|-------|------|-------------|
| `confidence` | string | Validation confidence: high, medium, low, none, or null (not yet validated) |
| `imdb_id` | string\|null | IMDB ID used for TMDB lookup (e.g., "tt1375666") |
| `tmdb_id` | number\|null | TMDB ID for the title |
| `tmdb_type` | string\|null | TMDB content type: "movie" or "tv" |
| `tmdb_title` | string\|null | Title from TMDB |
| `tmdb_year` | number\|null | Release year from TMDB |
| `tmdb_season` | number\|null | Season number from TMDB (TV only) |
| `tmdb_episode` | number\|null | Episode number from TMDB (TV only) |
| `tmdb_overview` | string\|null | Synopsis from TMDB (for validation against LLM-generated synopsis) |
| `runtime_match` | boolean\|null | True if TMDB runtime matches video duration (±5 min) |
| `discrepancies` | array | List of differences found (e.g., "year mismatch: IMDB 2010, TMDB 2011") |
| `api_error` | string\|null | Error message if TMDB API call failed |

**Confidence Levels:**
- `high`: TMDB found, title/year match, runtime matches
- `medium`: TMDB found, title matches but minor discrepancies
- `low`: TMDB found but significant discrepancies
- `none`: No TMDB match found for IMDB ID
- `null`: Not yet validated

---

## Examples

### TV Series Disc

**disk-metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "disk": {
    "name": "GAME_OF_THRONES_S01_D1",
    "name_parsed": {
      "title": "Game of Thrones",
      "season": 1,
      "disc": 1
    },
    "source_path": "/source/GAME_OF_THRONES_S01_D1"
  },
  "videos_summary": {
    "total_count": 3,
    "durations_seconds": [3420, 3300, 6720],
    "main_content": {
      "count": 2,
      "filenames": ["title_t00.mkv", "title_t01.mkv"],
      "durations_seconds": [3420, 3300],
      "mean_seconds": 3360,
      "variance_seconds": 3600,
      "std_dev_seconds": 60
    },
    "outliers": {
      "short": [],
      "long": ["title_t02.mkv"]
    },
    "play_all_detected": {
      "detected": true,
      "play_all_file": "title_t02.mkv",
      "play_all_duration_seconds": 6720,
      "episodes_total_seconds": 6720,
      "difference_seconds": 0
    },
    "pattern": "episodic"
  },
  "episode_hints": {
    "assumed_order": [
      {"filename": "title_t00.mkv", "position": 1, "episode_guess": 1, "part_of_multi": null},
      {"filename": "title_t01.mkv", "position": 2, "episode_guess": 2, "part_of_multi": null}
    ],
    "starting_episode": 1,
    "season_hint": 1,
    "multi_part_groups": [],
    "sequential_confidence": "high"
  },
  "proper_nouns": {
    "Ned Stark": 47,
    "Jon Snow": 38,
    "Daenerys Targaryen": 25,
    "Tyrion Lannister": 22,
    "Winterfell": 15
  },
  "content_type": "tv",
  "imdb_candidates": [
    {
      "tconst": "tt0944947",
      "title": "Game of Thrones",
      "year": 2011,
      "type": "tvSeries",
      "score": 95.5
    }
  ],
  "best_match": {
    "tconst": "tt0944947",
    "title": "Game of Thrones",
    "year": 2011,
    "confidence": "high",
    "reasoning": "Character names Ned Stark, Jon Snow match main cast. Episode runtimes match series format."
  },
  "status": {
    "current_step": 9,
    "completed_steps": [1, 2, 3, 4, 5, 7, 9],
    "error": null,
    "output_complete": true,
    "output_location": "shows"
  }
}
```

**title_t00.metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t00.mkv",
  "duration_seconds": 3420,
  "duration_minutes": 57,
  "subtitles": {
    "languages": ["eng", "spa"],
    "gaps": [],
    "segments": [3420]
  },
  "is_play_all": false,
  "proper_nouns": {
    "Ned Stark": 23,
    "Robert Baratheon": 18,
    "Winterfell": 8,
    "Jon Snow": 7
  },
  "plot_synopsis": "In the Seven Kingdoms of Westeros, Lord Ned Stark of Winterfell is visited by his old friend King Robert Baratheon, who asks him to serve as Hand of the King. Meanwhile, across the Narrow Sea, exiled Targaryen siblings plot their return.",
  "matches": [
    {
      "imdb_id": "tt1480055",
      "type": "episode",
      "title": "Winter Is Coming",
      "year": 2011,
      "season": 1,
      "episode": 1,
      "confidence": "high",
      "score": 95.5
    }
  ],
  "tmdb_validation": {
    "confidence": "high",
    "imdb_id": "tt1480055",
    "tmdb_id": 63056,
    "tmdb_type": "tv",
    "tmdb_title": "Winter Is Coming",
    "tmdb_year": 2011,
    "tmdb_season": 1,
    "tmdb_episode": 1,
    "tmdb_overview": "Jon Arryn, the Hand of the King, is dead. King Robert Baratheon plans to ask his oldest friend, Eddard Stark, to take Jon's place.",
    "runtime_match": true,
    "discrepancies": [],
    "api_error": null
  }
}
```

**title_t01.metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t01.mkv",
  "duration_seconds": 3300,
  "duration_minutes": 55,
  "subtitles": {
    "languages": ["eng", "spa"],
    "gaps": [],
    "segments": [3300]
  },
  "is_play_all": false,
  "proper_nouns": {
    "Tyrion Lannister": 15,
    "Catelyn Stark": 12,
    "Jon Snow": 10,
    "Arya Stark": 8
  },
  "plot_synopsis": "Bran's fall has left him comatose. Ned prepares to travel south with the king while Jon Snow decides to join the Night's Watch. Catelyn receives a warning about the Lannisters.",
  "matches": [
    {
      "imdb_id": "tt1668746",
      "type": "episode",
      "title": "The Kingsroad",
      "year": 2011,
      "season": 1,
      "episode": 2,
      "confidence": "high",
      "score": 94.2
    }
  ],
  "tmdb_validation": {
    "confidence": "high",
    "imdb_id": "tt1668746",
    "tmdb_id": 63057,
    "tmdb_type": "tv",
    "tmdb_title": "The Kingsroad",
    "tmdb_year": 2011,
    "tmdb_season": 1,
    "tmdb_episode": 2,
    "tmdb_overview": "While Bran recovers from his fall, Ned takes only his daughters to King's Landing. Jon Snow goes north to join the Night's Watch.",
    "runtime_match": true,
    "discrepancies": [],
    "api_error": null
  }
}
```

**title_t02.metadata.json** (Play-All Video)
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t02.mkv",
  "duration_seconds": 6720,
  "duration_minutes": 112,
  "subtitles": {
    "languages": ["eng", "spa"],
    "gaps": [
      {"position_seconds": 3420, "gap_duration_seconds": 5}
    ],
    "segments": [3420, 3295]
  },
  "is_play_all": true,
  "proper_nouns": {
    "Ned Stark": 47,
    "Jon Snow": 38,
    "Tyrion Lannister": 22
  },
  "plot_synopsis": "skipped:play_all",
  "matches": [],
  "tmdb_validation": {
    "confidence": null,
    "imdb_id": null,
    "tmdb_id": null,
    "tmdb_type": null,
    "tmdb_title": null,
    "tmdb_year": null,
    "tmdb_season": null,
    "tmdb_episode": null,
    "tmdb_overview": null,
    "runtime_match": null,
    "discrepancies": [],
    "api_error": "skipped:play_all"
  }
}
```

---

### Movie Disc

**disk-metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "disk": {
    "name": "INCEPTION_2010",
    "name_parsed": {
      "title": "Inception",
      "season": null,
      "disc": null
    },
    "source_path": "/source/INCEPTION_2010"
  },
  "videos_summary": {
    "total_count": 3,
    "durations_seconds": [120, 8880, 300],
    "main_content": {
      "count": 1,
      "filenames": ["title_t01.mkv"],
      "durations_seconds": [8880],
      "mean_seconds": 8880,
      "variance_seconds": 0,
      "std_dev_seconds": 0
    },
    "outliers": {
      "short": ["title_t00.mkv", "title_t02.mkv"],
      "long": []
    },
    "play_all_detected": {
      "detected": false,
      "play_all_file": null,
      "play_all_duration_seconds": null,
      "episodes_total_seconds": null,
      "difference_seconds": null
    },
    "pattern": "single_feature"
  },
  "episode_hints": {
    "assumed_order": [],
    "starting_episode": null,
    "season_hint": null,
    "multi_part_groups": [],
    "sequential_confidence": "none"
  },
  "proper_nouns": {
    "Dom Cobb": 89,
    "Arthur": 45,
    "Mal": 38,
    "Ariadne": 32,
    "Fischer": 28
  },
  "content_type": "movie",
  "imdb_candidates": [
    {
      "tconst": "tt1375666",
      "title": "Inception",
      "year": 2010,
      "type": "movie",
      "score": 98.2
    }
  ],
  "best_match": {
    "tconst": "tt1375666",
    "title": "Inception",
    "year": 2010,
    "confidence": "high",
    "reasoning": "Plot involves dream extraction and inception. Character names match cast."
  },
  "status": {
    "current_step": 9,
    "completed_steps": [1, 2, 3, 4, 5, 6, 9],
    "error": null,
    "output_complete": true,
    "output_location": "movies"
  }
}
```

**title_t00.metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t00.mkv",
  "duration_seconds": 8880,
  "duration_minutes": 148,
  "subtitles": {
    "languages": ["eng"],
    "gaps": [],
    "segments": [8880]
  },
  "is_play_all": false,
  "proper_nouns": {
    "Dom Cobb": 89,
    "Arthur": 45,
    "Mal": 38,
    "Ariadne": 32,
    "Fischer": 28
  },
  "plot_synopsis": "Dom Cobb is a skilled thief who specializes in extraction - stealing valuable secrets from deep within the subconscious during dream states. His rare ability has made him a coveted player in corporate espionage but has also cost him everything he loves. Cobb is offered a chance at redemption when he is tasked with inception: planting an idea in someone's mind rather than stealing one.",
  "matches": [
    {
      "imdb_id": "tt1375666",
      "type": "movie",
      "title": "Inception",
      "year": 2010,
      "season": null,
      "episode": null,
      "confidence": "high",
      "score": 98.2
    },
    {
      "imdb_id": "tt1790736",
      "type": "movie",
      "title": "Inception: The Cobol Job",
      "year": 2010,
      "season": null,
      "episode": null,
      "confidence": "low",
      "score": 45.1
    }
  ],
  "tmdb_validation": {
    "confidence": "high",
    "imdb_id": "tt1375666",
    "tmdb_id": 27205,
    "tmdb_type": "movie",
    "tmdb_title": "Inception",
    "tmdb_year": 2010,
    "tmdb_season": null,
    "tmdb_episode": null,
    "tmdb_overview": "Cobb, a skilled thief who commits corporate espionage by infiltrating the subconscious of his targets is offered a chance to regain his old life as payment for a task considered to be impossible: inception.",
    "runtime_match": true,
    "discrepancies": [],
    "api_error": null
  }
}
```

---

### Failed Pipeline

**disk-metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "disk": {
    "name": "UNKNOWN_DISC",
    "name_parsed": {
      "title": "Unknown Disc",
      "season": null,
      "disc": null
    },
    "source_path": "/source/UNKNOWN_DISC"
  },
  "videos_summary": {
    "total_count": 1,
    "durations_seconds": [5400],
    "main_content": {
      "count": 1,
      "filenames": ["title_t00.mkv"],
      "durations_seconds": [5400],
      "mean_seconds": 5400,
      "variance_seconds": 0,
      "std_dev_seconds": 0
    },
    "outliers": {
      "short": [],
      "long": []
    },
    "play_all_detected": {
      "detected": false,
      "play_all_file": null,
      "play_all_duration_seconds": null,
      "episodes_total_seconds": null,
      "difference_seconds": null
    },
    "pattern": "unknown"
  },
  "episode_hints": {
    "assumed_order": [],
    "starting_episode": null,
    "season_hint": null,
    "multi_part_groups": [],
    "sequential_confidence": "none"
  },
  "proper_nouns": {},
  "content_type": "unknown",
  "imdb_candidates": [],
  "best_match": null,
  "status": {
    "current_step": 1,
    "completed_steps": [],
    "error": "No subtitles found in any video file",
    "output_complete": true,
    "output_location": "unknown"
  }
}
```

**Note:** A disk is considered "unknown" and placed in `/output/unknown/` when any of these conditions are met:
- No match has a score above 60
- `best_match` is null after matching steps
- All videos have empty `matches[]` arrays
- `status.error` is set (pipeline failed at any step)
```

**title_t00.metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t00.mkv",
  "duration_seconds": 5400,
  "duration_minutes": 90,
  "subtitles": {
    "languages": [],
    "gaps": [],
    "segments": [5400]
  },
  "is_play_all": false,
  "proper_nouns": {},
  "plot_synopsis": null,
  "matches": [],
  "tmdb_validation": {
    "confidence": null,
    "imdb_id": null,
    "tmdb_id": null,
    "tmdb_type": null,
    "tmdb_title": null,
    "tmdb_year": null,
    "tmdb_season": null,
    "tmdb_episode": null,
    "tmdb_overview": null,
    "runtime_match": null,
    "discrepancies": [],
    "api_error": null
  }
}
```

---

### Multi-Episode File (with gaps)

Shows a single MKV containing multiple episodes, detected via gaps. This is essentially a "play all" file when there are no separate episode files on the disc.

**title_t00.metadata.json**
```json
{
  "version": "1.0",
  "generated": "2024-01-15T10:30:00Z",
  "filename": "title_t00.mkv",
  "duration_seconds": 10800,
  "duration_minutes": 180,
  "subtitles": {
    "languages": ["eng"],
    "gaps": [
      {"position_seconds": 2700, "gap_duration_seconds": 95},
      {"position_seconds": 5490, "gap_duration_seconds": 90},
      {"position_seconds": 8280, "gap_duration_seconds": 85}
    ],
    "segments": [2700, 2700, 2700, 2430]
  },
  "is_play_all": true,
  "proper_nouns": {
    "Jerry Seinfeld": 45,
    "George Costanza": 38,
    "Elaine Benes": 32,
    "Kramer": 28
  },
  "plot_synopsis": "skipped:play_all",
  "matches": [
    {
      "imdb_id": "tt0098904",
      "type": "episode",
      "title": "Seinfeld",
      "year": 1989,
      "season": 3,
      "episode": null,
      "confidence": "medium",
      "score": 72.5
    }
  ],
  "tmdb_validation": {
    "confidence": "low",
    "imdb_id": "tt0098904",
    "tmdb_id": 1400,
    "tmdb_type": "tv",
    "tmdb_title": "Seinfeld",
    "tmdb_year": 1989,
    "tmdb_season": 3,
    "tmdb_episode": null,
    "tmdb_overview": null,
    "runtime_match": false,
    "discrepancies": ["runtime mismatch: video 180 min, expected ~23 min per episode", "no specific episode match"],
    "api_error": null
  }
}
```

**Pattern Detection**: The `segments` array `[2700, 2700, 2700, 2430]` shows consistent ~45-minute segments, indicating 4 TV episodes. The similar durations help confirm this is episodic content rather than a movie.

**Note**: Even though `is_play_all` is true, if this is the *only* video on the disc (no separate episode files), it may still need to be processed for episode matching via gap analysis.

---

## File Naming Convention

| File Type | Location | Naming |
|-----------|----------|--------|
| Disk metadata | Disc directory | `disk-metadata.json` |
| Video metadata | Disc directory | `<basename>.metadata.json` |

**Example directory structure:**
```
/source/GAME_OF_THRONES_S01_D1/
├── disk-metadata.json
├── title_t00.mkv
├── title_t00.metadata.json
├── title_t00.eng.srt
├── title_t01.mkv
├── title_t01.metadata.json
├── title_t01.eng.srt
└── ...
```
