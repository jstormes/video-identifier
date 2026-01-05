#!/bin/bash
#
# Step 7: TV Matching (if TV.txt exists)
#
# For each video file less than 45 minutes:
# - Use the LLM to write a 6K story summary
# - Using the LLM and the FRANCHISE_SHORT_LIST.txt try to match the story
#   to an episode title and if available the season from DISK_METADATA.txt
# - Write those guesses into BEST_GUESS.txt
#
# Usage: step7-tv-matching.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/llm.sh"
source "$SCRIPT_DIR/lib/imdb.sh"

DISC_DIR="$1"

if [ -z "$DISC_DIR" ] || [ ! -d "$DISC_DIR" ]; then
    log_error "Usage: $0 <disc_directory>"
    exit 1
fi

# Check for UNKNOWN.txt (stop if previous step failed)
if should_stop_pipeline "$DISC_DIR"; then
    log_error "Pipeline stopped: UNKNOWN.txt exists"
    exit 1
fi

# Only run if TV.txt exists
if [ ! -f "$DISC_DIR/TV.txt" ]; then
    log "Step 7: Skipping (not a TV disc)"
    exit 0
fi

log "Step 7: TV Episode Matching"
log "Directory: $DISC_DIR"

FRANCHISE_FILE="$DISC_DIR/FRANCHISE_SHORT_LIST.txt"
METADATA_FILE="$DISC_DIR/DISK_METADATA.txt"
BEST_GUESS_FILE="$DISC_DIR/BEST_GUESS.txt"

if [ ! -f "$FRANCHISE_FILE" ]; then
    log_error "FRANCHISE_SHORT_LIST.txt not found"
    exit 1
fi

# Get season and disc hints from metadata
PARSED_SEASON=""
PARSED_DISC=""
if [ -f "$METADATA_FILE" ]; then
    PARSED_SEASON=$(grep "Season:" "$METADATA_FILE" | sed 's/.*Season:[[:space:]]*//' | grep -v "not found" || true)
    PARSED_DISC=$(grep "Disk Number:" "$METADATA_FILE" | sed 's/.*Disk Number:[[:space:]]*//' | grep -v "not found" || true)
fi

log "Season hint: ${PARSED_SEASON:-none}"
log "Disc hint: ${PARSED_DISC:-none}"

# Get top series from franchise list
SERIES_INFO=$(head -1 "$FRANCHISE_FILE")
SERIES_TCONST=$(echo "$SERIES_INFO" | cut -d'|' -f1)
SERIES_TITLE=$(echo "$SERIES_INFO" | cut -d'|' -f2)
SERIES_YEAR=$(echo "$SERIES_INFO" | cut -d'|' -f3)

log "Top series match: $SERIES_TITLE ($SERIES_YEAR) - $SERIES_TCONST"

# Get episode list from IMDB
log "Fetching episode list from IMDB..."
EPISODE_LIST=$(get_imdb_episodes "$SERIES_TCONST" "$PARSED_SEASON")

if [ -z "$EPISODE_LIST" ]; then
    log "Warning: No episodes found in IMDB, will use LLM matching only"
fi

EPISODE_COUNT=$(echo "$EPISODE_LIST" | wc -l)
log "  Found $EPISODE_COUNT episodes"

# Initialize BEST_GUESS.txt
cat > "$BEST_GUESS_FILE" << EOF
BEST_GUESS - TV Episodes
========================
Generated: $(date -Iseconds)

Series: $SERIES_TITLE ($SERIES_YEAR)
IMDB ID: $SERIES_TCONST
Season Hint: ${PARSED_SEASON:-none}

Episode Matches:
EOF

# Count total episode files first (for context hints)
TOTAL_EPISODE_FILES=0
for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue
    duration=$(get_duration_minutes "$mkv")
    if [ "$duration" -lt 45 ]; then
        TOTAL_EPISODE_FILES=$((TOTAL_EPISODE_FILES + 1))
    fi
done
log "Episode files to process: $TOTAL_EPISODE_FILES"

# Process each video file <45 minutes
MATCHED=0
TOTAL=0
FILE_POSITION=0
PREVIOUS_MATCHES=""

for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue

    duration=$(get_duration_minutes "$mkv")

    # Skip videos >= 45 minutes
    if [ "$duration" -ge 45 ]; then
        log "Skipping $(basename "$mkv") ($duration min >= 45 min)"
        continue
    fi

    TOTAL=$((TOTAL + 1))
    FILE_POSITION=$((FILE_POSITION + 1))
    base=$(basename "$mkv" .mkv)

    log "Processing: $base ($duration min)"

    # Find English dialogue file(s) for this video
    # Match both .en. and .eng. patterns (different subtitle naming conventions)
    dialogue_text=""
    for dialogue in "$DISC_DIR/${base}".en.dialogue*.txt "$DISC_DIR/${base}".eng.dialogue*.txt; do
        [ -f "$dialogue" ] || continue
        dialogue_text="${dialogue_text}$(cat "$dialogue")
"
    done

    if [ -z "$dialogue_text" ]; then
        log "  Warning: No dialogue found, skipping"
        echo "  $base.mkv: No dialogue available" >> "$BEST_GUESS_FILE"
        continue
    fi

    # Generate story summary
    log "  Generating story summary..."
    story_summary=$(generate_story_summary "$dialogue_text" "episode")

    if [ -z "$story_summary" ]; then
        log "  Warning: Failed to generate summary"
        echo "  $base.mkv: Failed to generate summary" >> "$BEST_GUESS_FILE"
        continue
    fi

    # Match to episode (with context hints)
    log "  Matching to episode list (file $FILE_POSITION of $TOTAL_EPISODE_FILES)..."
    match_result=$(match_episode_to_list "$story_summary" "$EPISODE_LIST" "$PARSED_SEASON" "$PARSED_DISC" "$FILE_POSITION" "$TOTAL_EPISODE_FILES" "$PREVIOUS_MATCHES")

    # Parse result
    season=$(echo "$match_result" | jq -r '.season // ""')
    episode=$(echo "$match_result" | jq -r '.episode // ""')
    title=$(echo "$match_result" | jq -r '.episode_title // "Unknown"')
    confidence=$(echo "$match_result" | jq -r '.confidence // "low"')

    # Format episode code
    ep_code=""
    if [ -n "$season" ] && [ -n "$episode" ]; then
        ep_code=$(printf "S%02dE%02d" "$season" "$episode")
        # Add to previous matches for next iteration
        PREVIOUS_MATCHES="${PREVIOUS_MATCHES}File $FILE_POSITION: $ep_code - $title
"
    fi

    log "  Match: $ep_code - $title ($confidence)"

    # Append to BEST_GUESS.txt
    cat >> "$BEST_GUESS_FILE" << EOF

  File: $base.mkv
  Duration: $duration min
  Episode: $ep_code
  Title: $title
  Confidence: $confidence
EOF

    MATCHED=$((MATCHED + 1))
done

# Add summary to file
cat >> "$BEST_GUESS_FILE" << EOF

Summary:
  Total files processed: $TOTAL
  Episodes matched: $MATCHED
EOF

log "Results: Matched $MATCHED of $TOTAL episodes"
log "Step 7 completed successfully"
exit 0
