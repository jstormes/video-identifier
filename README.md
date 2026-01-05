# Video Identifier

An automated 9-step pipeline that identifies DVD/Blu-ray video content by analyzing subtitles and dialogue. Uses OCR, LLM analysis, and IMDB database lookups to determine what videos contain, then outputs them in Jellyfin-compatible format.

## Technology Stack

- **Shell scripting** (Bash) for all pipeline logic
- **Docker** containerized (Ubuntu 22.04)
- **OCR**: vobsub2srt, tesseract-ocr, pgsrip
- **LLM**: OpenAI-compatible API (default: qwen3-30b)
- **Database**: MariaDB for IMDB data
- **Media tools**: mkvtoolnix, jq, curl

## Pipeline Steps

| Step | Script | Function |
|------|--------|----------|
| 1 | `step1-extract-srt.sh` | Extract SRT subtitles (VOBSUB/PGS/embedded) |
| 2 | `step2-extract-dialogue.sh` | Extract dialogue with episode boundary detection |
| 3 | `step3-extract-characters.sh` | Extract character names via LLM |
| 4 | `step4-create-metadata.sh` | Create disk metadata (video count, durations, patterns) |
| 5 | `step5-imdb-lookup.sh` | Initial IMDB lookup and content classification (TV/Movie) |
| 6 | `step6-movie-matching.sh` | Movie matching using LLM story summaries |
| 7 | `step7-tv-matching.sh` | TV episode matching against IMDB episode lists |
| 8 | `step8-hybrid-matching.sh` | Hybrid matching for mixed content |
| 9 | `step9-output-movie.sh` | Output movies to Jellyfin-compatible structure |
| 9 | `step9-output-tv.sh` | Output TV shows to Jellyfin-compatible structure |

## Requirements

### External Services

- **LLM Server**: OpenAI-compatible API endpoint
- **MariaDB/MySQL**: IMDB database with the following tables:
  - `title_basics` - Movie/TV metadata
  - `title_principals` - Actor/character info
  - `title_episode` - Episode details
  - `name_basics` - Actor information

### Environment Variables

#### LLM Configuration

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `LLM_BASE_URL` | Base URL for the OpenAI-compatible LLM API endpoint | `http://nas2:8191/v1` | No |
| `LLM_MODEL` | Model name to use for LLM requests | `qwen3-30b` | No |

The LLM is used for:
- Extracting character names from dialogue (Step 3)
- Generating story summaries from dialogue (Steps 6, 7, 8)
- Matching summaries to IMDB entries (Steps 6, 7, 8)

Internal LLM settings (not configurable via environment):
- Connect timeout: 10 seconds
- Default request timeout: 1200 seconds (20 minutes)
- Max retries: 3
- Retry delay: 5 seconds

#### Database Configuration

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `IMDB_HOST` | MariaDB/MySQL server hostname | `nas2` | No |
| `IMDB_USER` | Database username | `imdb` | No |
| `IMDB_PASSWORD` | Database password | (none) | **Yes** |
| `IMDB_DATABASE` | Database name containing IMDB data | `imdb` | No |

**Alternative variable names**: For compatibility, the following MySQL-prefixed variables are also accepted as fallbacks:
- `MYSQL_HOST` → fallback for `IMDB_HOST`
- `MYSQL_USER` → fallback for `IMDB_USER`
- `MYSQL_PASSWORD` → fallback for `IMDB_PASSWORD`
- `MYSQL_DATABASE` → fallback for `IMDB_DATABASE`

#### Output Configuration

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `OUTPUT_DIR` | Base directory for Jellyfin-compatible output | `/output` | No |

Output structure:
```
$OUTPUT_DIR/
└── Movies/
    └── Movie Name (Year) [imdbid-ttXXXXXX]/
        ├── Movie Name (Year) [imdbid-ttXXXXXX].mkv
        ├── Movie Name (Year) [imdbid-ttXXXXXX].en.srt
        └── extras/
            └── (bonus content)
```

#### Pipeline Configuration

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DISC_NAME` | Override the auto-detected disc name | (auto-detected from MKV metadata or directory name) | No |
| `DEBUG` | Enable verbose debug logging to stderr | `false` | No |

**Debug mode**: When `DEBUG=true`, additional diagnostic information is logged including:
- LLM request/response details
- Retry attempts and timing
- Detailed error messages

#### Complete Example

```bash
# Required
export IMDB_PASSWORD="your_secure_password"

# Optional - LLM configuration
export LLM_BASE_URL="http://localhost:8080/v1"
export LLM_MODEL="llama3-70b"

# Optional - Database configuration
export IMDB_HOST="database.local"
export IMDB_USER="imdb_reader"
export IMDB_DATABASE="imdb_data"

# Optional - Output configuration
export OUTPUT_DIR="/mnt/media/movies"

# Optional - Pipeline configuration
export DISC_NAME="My Movie Collection"
export DEBUG="true"
```

## Usage

### Quick Start with Docker Compose

1. Copy the example environment file and configure:
   ```bash
   cp .env.example .env
   # Edit .env and set IMDB_PASSWORD and paths
   ```

2. Process a single disc:
   ```bash
   docker compose run --rm video-identifier /source/MY_DISC_FOLDER
   ```

3. Or run the watcher service to automatically process new discs:
   ```bash
   docker compose --profile watcher up -d video-identifier-watcher
   ```

### Docker Compose Services

| Service | Description |
|---------|-------------|
| `video-identifier` | On-demand processing of a single disc directory |
| `video-identifier-watcher` | Background service that monitors for new discs |

### Running with Docker (Manual)

```bash
docker build -t video-identifier .

docker run -v /path/to/source:/source \
           -v /path/to/output:/output \
           -e IMDB_PASSWORD=yourpassword \
           -e IMDB_HOST=your-db-host \
           -e LLM_BASE_URL=http://your-llm-host:8191/v1 \
           video-identifier /source/DISC_FOLDER
```

### Running the Orchestrator Directly

The main entry point is `orchestrator.sh`, which runs all steps sequentially with error handling and status tracking:

```bash
./orchestrator.sh /path/to/disc/folder
```

## Key Features

- **Multi-language subtitle support**: English, Spanish, French, German, Portuguese, Italian
- **Intelligent episode boundary detection**: Uses gap analysis to detect episode boundaries in multi-episode files
- **Character-based IMDB matching**: Extracts character names and matches against IMDB database with scoring
- **LLM-powered semantic matching**: Uses story summaries for accurate content identification
- **Robust error handling**: Status tracking via `pipeline_status.json`
- **Content classification**: Automatically detects TV series vs movies based on file patterns

## Input/Output

### Input

- Directory containing MKV files with embedded, VOBSUB, or PGS subtitles

### Output

Jellyfin-organized media library with proper naming conventions.

**Movies** (Reference: [Jellyfin Movies Documentation](https://jellyfin.org/docs/general/server/media/movies/)):
```
$OUTPUT_DIR/Movies/
└── Movie Name (Year) [imdbid-ttXXXXXX]/
    ├── Movie Name (Year) [imdbid-ttXXXXXX].mkv
    ├── Movie Name (Year) [imdbid-ttXXXXXX].en.srt
    └── extras/
        └── (bonus content)
```

**TV Shows** (Reference: [Jellyfin Shows Documentation](https://jellyfin.org/docs/general/server/media/shows)):
```
$OUTPUT_DIR/Shows/
└── Series Name (Year) [imdbid-ttXXXXXX]/
    ├── Season 01/
    │   ├── Series Name S01E01 Episode Title.mkv
    │   ├── Series Name S01E01 Episode Title.en.srt
    │   ├── Series Name S01E02 Episode Title.mkv
    │   └── ...
    ├── Season 02/
    │   └── ...
    └── extras/
        └── (bonus content)
```

- Subtitles converted to Jellyfin standard language codes (eng→en, spa→es, etc.)

### Generated Files

| File | Description |
|------|-------------|
| `*.srt` | Extracted subtitles |
| `*.dialogue.txt` | Extracted dialogue with gap markers |
| `CHARACTERS.txt` | Extracted character names |
| `DISK_METADATA.txt` | Disk analysis summary |
| `FRANCHISE_SHORT_LIST.txt` | Matching candidates with scores |
| `MOVIE.txt` / `TV.txt` / `TV_MOVIE.txt` | Content type markers |
| `BEST_GUESS.txt` | Final match result with reasoning |
| `pipeline_status.json` | Execution status tracking |
| `OUTPUT_COMPLETE.txt` | Success marker |
| `UNKNOWN.txt` | Error marker (stops pipeline) |

## Library Modules

- **common.sh**: Utility functions (duration parsing, disc name parsing, logging)
- **llm.sh**: LLM API wrapper and character/summary generation
- **imdb.sh**: IMDB database queries and matching algorithms

## Workflow

1. **Input**: Directory containing MKV files with embedded/VOBSUB/PGS subtitles
2. **Processing**:
   - Extract and OCR subtitles → dialogue → character extraction
   - Analyze structure and patterns → classify as TV/movies
   - Search IMDB using multiple criteria → generate short list
   - Use LLM for semantic matching → confirm identification
3. **Output**: Jellyfin-organized media library with metadata

The system is designed for fully automated batch processing of video collections without manual intervention.
