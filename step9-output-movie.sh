#!/bin/bash
#
# Step 9: Output Movie Files (if MOVIE.txt or TV_MOVIE.txt exists)
#
# Moves identified movie files to /output with Jellyfin-compatible naming:
#   /output/Movies/Movie Name (Year) [imdbid-ttXXXXXXX]/Movie Name (Year) [imdbid-ttXXXXXXX].mkv
#   /output/Movies/Movie Name (Year) [imdbid-ttXXXXXXX]/Movie Name (Year) [imdbid-ttXXXXXXX].en.srt
#   /output/Movies/Movie Name (Year) [imdbid-ttXXXXXXX]/extras/...
#
# Reference: https://jellyfin.org/docs/general/server/media/movies/
#
# Usage: step9-output-movie.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

DISC_DIR="$1"
OUTPUT_BASE="${OUTPUT_DIR:-/output}/Movies"

if [ -z "$DISC_DIR" ] || [ ! -d "$DISC_DIR" ]; then
    log_error "Usage: $0 <disc_directory>"
    exit 1
fi

# Check for UNKNOWN.txt (stop if previous step failed)
if should_stop_pipeline "$DISC_DIR"; then
    log_error "Pipeline stopped: UNKNOWN.txt exists"
    exit 1
fi

# Only run if MOVIE.txt or TV_MOVIE.txt exists
if [ ! -f "$DISC_DIR/MOVIE.txt" ] && [ ! -f "$DISC_DIR/TV_MOVIE.txt" ]; then
    log "Step 9: Skipping (not a movie or hybrid disc)"
    exit 0
fi

# Must have BEST_GUESS.txt
BEST_GUESS_FILE="$DISC_DIR/BEST_GUESS.txt"
if [ ! -f "$BEST_GUESS_FILE" ]; then
    log_error "BEST_GUESS.txt not found - run matching step first"
    exit 1
fi

log "Step 9: Output Movie Files"
log "Directory: $DISC_DIR"

# Parse BEST_GUESS.txt
IMDB_ID=$(grep "IMDB ID:" "$BEST_GUESS_FILE" | sed 's/.*IMDB ID:[[:space:]]*//' | head -1)
TITLE=$(grep "Title:" "$BEST_GUESS_FILE" | sed 's/.*Title:[[:space:]]*//' | head -1)
YEAR=$(grep "Year:" "$BEST_GUESS_FILE" | sed 's/.*Year:[[:space:]]*//' | head -1)

if [ -z "$TITLE" ] || [ "$TITLE" = "Unknown" ]; then
    log_error "No valid title found in BEST_GUESS.txt"
    exit 1
fi

if [ -z "$IMDB_ID" ] || [ "$IMDB_ID" = "unknown" ] || [ "$IMDB_ID" = "null" ]; then
    log_error "No valid IMDB ID found in BEST_GUESS.txt"
    exit 1
fi

log "  Title: $TITLE"
log "  Year: $YEAR"
log "  IMDB: $IMDB_ID"

# sanitize_filename is defined in lib/common.sh
SAFE_TITLE=$(sanitize_filename "$TITLE")

# Build Jellyfin-compatible folder and file names
# Format: Movie Name (Year) [imdbid-ttXXXXXXX]
if [ -n "$YEAR" ] && [ "$YEAR" != "null" ]; then
    FOLDER_NAME="${SAFE_TITLE} (${YEAR}) [imdbid-${IMDB_ID}]"
else
    FOLDER_NAME="${SAFE_TITLE} [imdbid-${IMDB_ID}]"
fi

OUTPUT_FOLDER="$OUTPUT_BASE/$FOLDER_NAME"
EXTRAS_FOLDER="$OUTPUT_FOLDER/extras"

log "  Output folder: $OUTPUT_FOLDER"

# Create output directories
mkdir -p "$OUTPUT_FOLDER"
mkdir -p "$EXTRAS_FOLDER"

# Find the longest MKV file (main feature)
LONGEST_MKV=$(find_longest_mkv "$DISC_DIR")

if [ -z "$LONGEST_MKV" ]; then
    log_error "No MKV files found"
    exit 1
fi

LONGEST_BASE=$(basename "$LONGEST_MKV" .mkv)

# Function to move subtitles for a video file
# Usage: move_subtitles <source_base> <dest_base> <dest_folder>
move_subtitles() {
    local src_base="$1"
    local dest_base="$2"
    local dest_folder="$3"

    # Find all SRT files matching the source base
    for srt in "$DISC_DIR/${src_base}"*.srt; do
        [ -f "$srt" ] || continue

        local srt_name=$(basename "$srt")
        # Extract language/track info after the base name
        # e.g., C1_t00.eng.srt -> .eng.srt
        local suffix="${srt_name#$src_base}"

        # Convert common language codes to Jellyfin format
        # eng -> en, spa -> es, fra -> fr, etc.
        suffix=$(echo "$suffix" | sed 's/\.eng\./\.en\./g')
        suffix=$(echo "$suffix" | sed 's/\.spa\./\.es\./g')
        suffix=$(echo "$suffix" | sed 's/\.fra\./\.fr\./g')
        suffix=$(echo "$suffix" | sed 's/\.deu\./\.de\./g')
        suffix=$(echo "$suffix" | sed 's/\.ita\./\.it\./g')
        suffix=$(echo "$suffix" | sed 's/\.por\./\.pt\./g')
        suffix=$(echo "$suffix" | sed 's/\.jpn\./\.ja\./g')
        suffix=$(echo "$suffix" | sed 's/\.zho\./\.zh\./g')
        suffix=$(echo "$suffix" | sed 's/\.kor\./\.ko\./g')

        local dest_srt="${dest_folder}/${dest_base}${suffix}"

        # Only move non-empty subtitles
        if [ -s "$srt" ]; then
            log "    Subtitle: $(basename "$srt") -> $(basename "$dest_srt")"
            mv "$srt" "$dest_srt"
        else
            # Remove empty subtitle files
            rm -f "$srt"
        fi
    done
}

# Count how many "long" videos we have (for detecting director's cut / theatrical)
LONG_VIDEO_COUNT=$(count_files_over_duration "$DISC_DIR" 60)

if [ "$LONG_VIDEO_COUNT" -eq 1 ]; then
    # Single main feature - simple case
    OUTPUT_FILE="$OUTPUT_FOLDER/${FOLDER_NAME}.mkv"
    log "  Main feature: $(basename "$LONGEST_MKV") -> $(basename "$OUTPUT_FILE")"
    mv "$LONGEST_MKV" "$OUTPUT_FILE"

    # Move subtitles for main feature
    move_subtitles "$LONGEST_BASE" "$FOLDER_NAME" "$OUTPUT_FOLDER"
else
    # Multiple long videos - could be different versions (theatrical, director's cut)
    log "  Found $LONG_VIDEO_COUNT long videos - moving as versions"

    for mkv in "$DISC_DIR"/*.mkv; do
        [ -f "$mkv" ] || continue

        DURATION=$(get_duration_minutes "$mkv")
        BASENAME=$(basename "$mkv" .mkv)

        # Only process files over 60 minutes as main features
        if [ "$DURATION" -gt 60 ]; then
            # Try to detect version type from filename
            VERSION_SUFFIX=""
            if echo "$BASENAME" | grep -qiE 'director|extended|uncut'; then
                VERSION_SUFFIX=" - Directors Cut"
            elif echo "$BASENAME" | grep -qiE 'theatrical|original'; then
                VERSION_SUFFIX=" - Theatrical"
            else
                VERSION_SUFFIX=" - ${DURATION}min"
            fi

            OUTPUT_FILE="$OUTPUT_FOLDER/${FOLDER_NAME}${VERSION_SUFFIX}.mkv"
            log "  Version: $BASENAME.mkv ($DURATION min) -> $(basename "$OUTPUT_FILE")"
            mv "$mkv" "$OUTPUT_FILE"

            # Move subtitles for this version
            move_subtitles "$BASENAME" "${FOLDER_NAME}${VERSION_SUFFIX}" "$OUTPUT_FOLDER"
        fi
    done
fi

# Move remaining MKV files (extras/bonus content) to extras folder
EXTRAS_COUNT=0
for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue

    BASENAME=$(basename "$mkv" .mkv)
    DURATION=$(get_duration_minutes "$mkv")

    # Move to extras folder, keeping original name
    OUTPUT_FILE="$EXTRAS_FOLDER/${BASENAME}.mkv"
    log "  Extra: $BASENAME.mkv ($DURATION min)"
    mv "$mkv" "$OUTPUT_FILE"

    # Move subtitles for this extra
    move_subtitles "$BASENAME" "$BASENAME" "$EXTRAS_FOLDER"

    EXTRAS_COUNT=$((EXTRAS_COUNT + 1))
done

if [ "$EXTRAS_COUNT" -gt 0 ]; then
    log "  Moved $EXTRAS_COUNT extras to: $EXTRAS_FOLDER"
else
    # Remove empty extras folder
    rmdir "$EXTRAS_FOLDER" 2>/dev/null || true
fi

# Clean up any remaining empty SRT files
find "$DISC_DIR" -name "*.srt" -empty -delete 2>/dev/null || true

# Create a marker file indicating successful output
cat > "$DISC_DIR/OUTPUT_COMPLETE.txt" << EOF
OUTPUT_COMPLETE
Output: $OUTPUT_FOLDER
Date: $(date -Iseconds)
Main Feature: $FOLDER_NAME.mkv
Extras: $EXTRAS_COUNT
EOF

log "Step 9 completed successfully"
log "  Output: $OUTPUT_FOLDER"
exit 0
