#!/bin/bash
#
# Step 5: Initial IMDB Lookup
#
# Search Criteria A (for >2 files of same length - TV shows):
# - Proper nouns matching character names
# - Parsed disc name searching titles
# - Same video length matching ±2 minutes for TV shows
#
# Search Criteria B (if >1 file over 60 min - Movies):
# - Proper nouns matching character names and actor names
# - Parsed disc name searching titles
# - Three longest video lengths matching ±3 minutes movie length
#
# Output:
# - FRANCHISE_SHORT_LIST.txt with best matches first
# - MOVIE.txt if only movies found
# - TV.txt if only TV series found
# - TV_MOVIE.txt if both found
# - UNKNOWN.txt with "No franchise found" if nothing found
#
# Usage: step5-imdb-lookup.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"
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

log "Step 5: Initial IMDB Lookup"
log "Directory: $DISC_DIR"

# Test database connection
if ! test_imdb_connection; then
    log_error "Cannot connect to IMDB database"
    echo "No franchise found - database connection failed" > "$DISC_DIR/UNKNOWN.txt"
    exit 1
fi

METADATA_FILE="$DISC_DIR/DISK_METADATA.txt"
CHARACTERS_FILE="$DISC_DIR/CHARACTERS.txt"
FRANCHISE_FILE="$DISC_DIR/FRANCHISE_SHORT_LIST.txt"

if [ ! -f "$METADATA_FILE" ]; then
    log_error "DISK_METADATA.txt not found"
    exit 1
fi

# Parse metadata
DISC_NAME=$(grep "^Disk Name:" "$METADATA_FILE" | sed 's/Disk Name:[[:space:]]*//')
PARSED_SEASON=$(grep "Season:" "$METADATA_FILE" | sed 's/.*Season:[[:space:]]*//' | grep -v "not found" || true)
SAME_LENGTH_COUNT=$(grep "Files within 60 seconds" "$METADATA_FILE" | grep -oE '[0-9]+' | head -1)
SAME_LENGTH_APPROX=$(grep "Approximate length:" "$METADATA_FILE" | grep -oE '[0-9]+' | head -1)
LONGEST_MINUTES=$(grep -A3 "Longest File:" "$METADATA_FILE" | grep "Length:" | grep -oE '[0-9]+' | head -1)

# Extract title hint from disc name
TITLE_HINT=$(extract_title_from_disc_name "$DISC_NAME")
log "  Title hint: $TITLE_HINT"

# Read characters (comma-separated)
CHARACTERS=""
if [ -f "$CHARACTERS_FILE" ]; then
    CHARACTERS=$(cat "$CHARACTERS_FILE" | grep -v '^#' | tr '\n' ',' | sed 's/,$//')
fi

# Extract proper nouns from metadata
PROPER_NOUNS=$(sed -n '/^Proper Nouns/,/^$/p' "$METADATA_FILE" | tail -n +2 | sed 's/^[[:space:]]*//' | tr '\n' ',' | sed 's/,$//')

log "  Characters: $(echo "$CHARACTERS" | wc -w) found"
log "  Proper nouns: $(echo "$PROPER_NOUNS" | tr ',' '\n' | wc -l) found"
log "  Same-length files: $SAME_LENGTH_COUNT (~$SAME_LENGTH_APPROX min)"
log "  Longest file: $LONGEST_MINUTES min"

# Initialize results
TV_RESULTS=""
MOVIE_RESULTS=""
FOUND_TV=false
FOUND_MOVIE=false

# Temporary file for collecting results
TEMP_RESULTS="$DISC_DIR/.temp_imdb_results_$$"
> "$TEMP_RESULTS"

cleanup() {
    rm -f "$TEMP_RESULTS"
}
trap cleanup EXIT

# Count files over 60 minutes
MOVIE_COUNT=$(count_files_over_duration "$DISC_DIR" 60)
log "  Files over 60 min: $MOVIE_COUNT"

# Search Criteria A: TV shows (>2 files of same length)
if [ "$SAME_LENGTH_COUNT" -gt 2 ]; then
    log "Applying TV search criteria (>2 same-length files)..."

    # Search by proper nouns matching characters
    if [ -n "$PROPER_NOUNS" ]; then
        log "  Searching by proper nouns as characters..."
        TV_RESULTS=$(search_imdb_by_proper_nouns "$PROPER_NOUNS" "tv")
        if [ -n "$TV_RESULTS" ]; then
            echo "$TV_RESULTS" >> "$TEMP_RESULTS"
            FOUND_TV=true
        fi
    fi

    # Search by title hint
    if [ -n "$TITLE_HINT" ]; then
        log "  Searching by title hint..."
        results=$(search_imdb_tv "$CHARACTERS" "$TITLE_HINT" "$SAME_LENGTH_APPROX")
        if [ -n "$results" ]; then
            echo "$results" >> "$TEMP_RESULTS"
            FOUND_TV=true
        fi
    fi
fi

# Search Criteria B: Movies (>1 file over 60 min)
if [ "$MOVIE_COUNT" -ge 1 ]; then
    log "Applying movie search criteria (>=$MOVIE_COUNT files over 60 min)..."

    # Get the three longest durations
    LONGEST_DURATIONS=""
    for mkv in "$DISC_DIR"/*.mkv; do
        [ -f "$mkv" ] || continue
        dur=$(get_duration_minutes "$mkv")
        LONGEST_DURATIONS="${LONGEST_DURATIONS}${dur}
"
    done
    LONGEST_DURATIONS=$(echo "$LONGEST_DURATIONS" | sort -rn | head -3)

    # Search by proper nouns matching characters and actors
    if [ -n "$PROPER_NOUNS" ]; then
        log "  Searching by proper nouns as characters/actors..."
        MOVIE_RESULTS=$(search_imdb_movie "$CHARACTERS" "$PROPER_NOUNS" "$TITLE_HINT" "$LONGEST_MINUTES")
        if [ -n "$MOVIE_RESULTS" ]; then
            echo "$MOVIE_RESULTS" >> "$TEMP_RESULTS"
            FOUND_MOVIE=true
        fi
    fi

    # Search by title hint and runtime
    if [ -n "$TITLE_HINT" ]; then
        log "  Searching by title and runtime..."
        for runtime in $LONGEST_DURATIONS; do
            [ -n "$runtime" ] || continue
            results=$(search_by_title_and_runtime "$TITLE_HINT" "$runtime" 3 "movie")
            if [ -n "$results" ]; then
                echo "$results" >> "$TEMP_RESULTS"
                FOUND_MOVIE=true
            fi
        done
    fi
fi

# Check if anything was found - if not, try fallback searches
if [ ! -s "$TEMP_RESULTS" ]; then
    log "No matches with disc name, trying character-based search..."

    # Try using prominent character names as title hints
    # Priority: hyphenated names (like "Scooby-Doo"), then names with titles, then regular names
    if [ -n "$CHARACTERS" ]; then
        # Build prioritized list of character names
        char_list=""
        # First: hyphenated names (often franchise names like Scooby-Doo, Spider-Man)
        char_list="$char_list $(echo "$CHARACTERS" | tr ',' '\n' | grep -E '^[A-Z][a-z]+-[A-Z][a-z]+' | head -3)"
        # Second: two-word names (first + last name characters)
        char_list="$char_list $(echo "$CHARACTERS" | tr ',' '\n' | grep -E '^[A-Z][a-z]+ [A-Z][a-z]+' | head -3)"
        # Third: single proper names (not generic like "Man", "Woman", etc.)
        char_list="$char_list $(echo "$CHARACTERS" | tr ',' '\n' | grep -vE '^(Man|Woman|Boy|Girl|Uncle|Aunt|Cousin|Professor|Doctor|Sheriff|Santa)' | grep -E '^[A-Z][a-z]{3,}$' | head -3)"

        for char_name in $char_list; do
            [ -z "$char_name" ] && continue
            log "  Trying character name: $char_name"

            # Search TV by character name
            results=$(search_imdb_tv "$CHARACTERS" "$char_name" "$SAME_LENGTH_APPROX")
            if [ -n "$results" ]; then
                echo "$results" >> "$TEMP_RESULTS"
                FOUND_TV=true
            fi

            # Search movies by character name
            if [ "$MOVIE_COUNT" -ge 1 ]; then
                results=$(search_by_title_and_runtime "$char_name" "$LONGEST_MINUTES" 5 "movie")
                if [ -n "$results" ]; then
                    echo "$results" >> "$TEMP_RESULTS"
                    FOUND_MOVIE=true
                fi
            fi

            # Stop if we found something good (more than 1 result or high score)
            if [ -s "$TEMP_RESULTS" ]; then
                result_count=$(wc -l < "$TEMP_RESULTS")
                if [ "$result_count" -gt 1 ]; then
                    break
                fi
            fi
        done
    fi
fi

# Final check if anything was found
if [ ! -s "$TEMP_RESULTS" ]; then
    log_error "No matches found in IMDB database"
    echo "No franchise found" > "$DISC_DIR/UNKNOWN.txt"
    exit 1
fi

# Deduplicate and sort results by score (column 5)
sort -t'|' -k5 -rn "$TEMP_RESULTS" | uniq > "$FRANCHISE_FILE"

# Count results
RESULT_COUNT=$(wc -l < "$FRANCHISE_FILE")
log "Found $RESULT_COUNT potential matches"

# Determine content type based on TOP MATCH, not just presence of results
# This prevents noise (low-scoring irrelevant matches) from affecting classification
TOP_MATCH_TYPE=$(head -1 "$FRANCHISE_FILE" | cut -d'|' -f4)
TOP_MATCH_SCORE=$(head -1 "$FRANCHISE_FILE" | cut -d'|' -f5)

log "  Top match type: $TOP_MATCH_TYPE (score: $TOP_MATCH_SCORE)"

# Classify based on the top match's type
case "$TOP_MATCH_TYPE" in
    tvSeries|tvMiniSeries)
        echo "TV" > "$DISC_DIR/TV.txt"
        log "  Content type: TV series (based on top match)"
        ;;
    movie)
        echo "MOVIE" > "$DISC_DIR/MOVIE.txt"
        log "  Content type: Movie (based on top match)"
        ;;
    tvMovie)
        # TV movies could go either way - check if there are strong TV results
        if [ "$FOUND_TV" = true ] && [ "$SAME_LENGTH_COUNT" -gt 2 ]; then
            echo "TV_MOVIE" > "$DISC_DIR/TV_MOVIE.txt"
            log "  Content type: TV Movie (hybrid - has TV episodes)"
        else
            echo "MOVIE" > "$DISC_DIR/MOVIE.txt"
            log "  Content type: TV Movie (treating as movie)"
        fi
        ;;
    video)
        # Video releases - check if it has TV-like structure
        # If longest file has gaps (was split) or multiple same-length files, treat as hybrid
        LONGEST_GAPS=$(grep -A2 "Longest File:" "$METADATA_FILE" | grep "Gaps" | grep -oE '[0-9]+' | head -1)
        if [ "${LONGEST_GAPS:-0}" -gt 0 ] || [ "$SAME_LENGTH_COUNT" -gt 2 ]; then
            echo "TV_MOVIE" > "$DISC_DIR/TV_MOVIE.txt"
            log "  Content type: Video release (hybrid - has gaps or multiple episodes)"
        else
            echo "MOVIE" > "$DISC_DIR/MOVIE.txt"
            log "  Content type: Video release (treating as movie)"
        fi
        ;;
    *)
        # Unknown type - fall back to checking both flags
        if [ "$FOUND_TV" = true ] && [ "$FOUND_MOVIE" = true ]; then
            echo "TV_MOVIE" > "$DISC_DIR/TV_MOVIE.txt"
            log "  Content type: TV + Movie (hybrid - unknown top type)"
        elif [ "$FOUND_TV" = true ]; then
            echo "TV" > "$DISC_DIR/TV.txt"
            log "  Content type: TV series"
        elif [ "$FOUND_MOVIE" = true ]; then
            echo "MOVIE" > "$DISC_DIR/MOVIE.txt"
            log "  Content type: Movie"
        else
            echo "MOVIE" > "$DISC_DIR/MOVIE.txt"
            log "  Content type: Unknown (defaulting to Movie)"
        fi
        ;;
esac

# Show top results
log "Top matches:"
head -5 "$FRANCHISE_FILE" | while IFS='|' read -r tconst title year type score; do
    log "  $title ($year) - $type [score: $score]"
done

log "Step 5 completed successfully"
exit 0
