#!/bin/bash
#
# Step 9: Output TV Show Files (if TV.txt exists)
#
# Moves identified TV episode files to /output with Jellyfin-compatible naming:
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/Season 01/
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/Season 01/Series Name S01E01 Episode Title.mkv
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/Season 01/Series Name S01E01 Episode Title.en.srt
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/Season 00/  (specials)
#   /output/Shows/Series Name (Year) [imdbid-ttXXXXXXX]/extras/     (bonus content)
#
# Reference: https://jellyfin.org/docs/general/server/media/shows
#
# Usage: step9-output-tv.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

DISC_DIR="$1"
OUTPUT_BASE="${OUTPUT_DIR:-/output}/Shows"

if [ -z "$DISC_DIR" ] || [ ! -d "$DISC_DIR" ]; then
    log_error "Usage: $0 <disc_directory>"
    exit 1
fi

# Check for UNKNOWN.txt (stop if previous step failed)
if should_stop_pipeline "$DISC_DIR"; then
    log_error "Pipeline stopped: UNKNOWN.txt exists"
    exit 1
fi

# Only run if TV.txt exists (not TV_MOVIE.txt - that's handled by hybrid)
if [ ! -f "$DISC_DIR/TV.txt" ]; then
    log "Step 9: Skipping (not a TV disc)"
    exit 0
fi

# Must have BEST_GUESS.txt
BEST_GUESS_FILE="$DISC_DIR/BEST_GUESS.txt"
if [ ! -f "$BEST_GUESS_FILE" ]; then
    log_error "BEST_GUESS.txt not found - run matching step first"
    exit 1
fi

log "Step 9: Output TV Show Files"
log "Directory: $DISC_DIR"

# Parse series info from BEST_GUESS.txt
SERIES_LINE=$(grep "^Series:" "$BEST_GUESS_FILE" | head -1)
IMDB_ID=$(grep "^IMDB ID:" "$BEST_GUESS_FILE" | sed 's/IMDB ID:[[:space:]]*//' | head -1)

# Extract series name and year from "Series: Name (Year)" format
SERIES_TITLE=$(echo "$SERIES_LINE" | sed 's/Series:[[:space:]]*//' | sed 's/[[:space:]]*([0-9]\{4\})[[:space:]]*$//')
SERIES_YEAR=$(echo "$SERIES_LINE" | grep -oE '\([0-9]{4}\)' | tr -d '()')

if [ -z "$SERIES_TITLE" ]; then
    log_error "No valid series title found in BEST_GUESS.txt"
    exit 1
fi

if [ -z "$IMDB_ID" ]; then
    log_error "No valid IMDB ID found in BEST_GUESS.txt"
    exit 1
fi

log "  Series: $SERIES_TITLE"
log "  Year: $SERIES_YEAR"
log "  IMDB: $IMDB_ID"

# sanitize_filename is defined in lib/common.sh
SAFE_SERIES_TITLE=$(sanitize_filename "$SERIES_TITLE")

# Build Jellyfin-compatible series folder name
# Format: Series Name (Year) [imdbid-ttXXXXXXX]
if [ -n "$SERIES_YEAR" ]; then
    SERIES_FOLDER_NAME="${SAFE_SERIES_TITLE} (${SERIES_YEAR}) [imdbid-${IMDB_ID}]"
else
    SERIES_FOLDER_NAME="${SAFE_SERIES_TITLE} [imdbid-${IMDB_ID}]"
fi

SERIES_OUTPUT_FOLDER="$OUTPUT_BASE/$SERIES_FOLDER_NAME"
EXTRAS_FOLDER="$SERIES_OUTPUT_FOLDER/extras"

log "  Output folder: $SERIES_OUTPUT_FOLDER"

# Create series directory
mkdir -p "$SERIES_OUTPUT_FOLDER"

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
        local suffix="${srt_name#$src_base}"

        # Convert common language codes to Jellyfin format
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
            rm -f "$srt"
        fi
    done
}

# Parse episode matches from BEST_GUESS.txt
# Format in file:
#   File: filename.mkv
#   Duration: XX min
#   Episode: S##E##
#   Title: Episode Title
#   Confidence: high/medium/low

EPISODES_MOVED=0
EXTRAS_COUNT=0

# Read episode blocks from BEST_GUESS.txt
current_file=""
current_episode=""
current_title=""

while IFS= read -r line; do
    # Parse file line
    if [[ "$line" =~ ^[[:space:]]*File:[[:space:]]*(.+\.mkv) ]]; then
        current_file="${BASH_REMATCH[1]}"
    # Parse episode line
    elif [[ "$line" =~ ^[[:space:]]*Episode:[[:space:]]*(S[0-9]+E[0-9]+) ]]; then
        current_episode="${BASH_REMATCH[1]}"
    # Parse title line
    elif [[ "$line" =~ ^[[:space:]]*Title:[[:space:]]*(.+) ]]; then
        current_title="${BASH_REMATCH[1]}"
    # Parse confidence line (end of episode block)
    elif [[ "$line" =~ ^[[:space:]]*Confidence: ]]; then
        # Process this episode if we have all required info
        if [ -n "$current_file" ] && [ -n "$current_episode" ]; then
            src_mkv="$DISC_DIR/$current_file"

            if [ -f "$src_mkv" ]; then
                # Extract season number from episode code (S01E01 -> 01)
                season_num=$(echo "$current_episode" | sed 's/S\([0-9]\+\)E.*/\1/' | sed 's/^0*//')
                [ -z "$season_num" ] && season_num=1

                # Format season folder name (Season 01, Season 02, etc.)
                season_folder=$(printf "Season %02d" "$season_num")
                season_path="$SERIES_OUTPUT_FOLDER/$season_folder"

                # Create season directory
                mkdir -p "$season_path"

                # Build episode filename
                # Format: Series Name S01E01 Episode Title.mkv
                safe_title=$(sanitize_filename "$current_title")
                if [ -n "$safe_title" ] && [ "$safe_title" != "Unknown" ]; then
                    episode_filename="${SAFE_SERIES_TITLE} ${current_episode} ${safe_title}.mkv"
                else
                    episode_filename="${SAFE_SERIES_TITLE} ${current_episode}.mkv"
                fi

                dest_mkv="$season_path/$episode_filename"

                log "  Episode: $current_file -> $season_folder/$episode_filename"
                mv "$src_mkv" "$dest_mkv"

                # Move subtitles
                src_base=$(basename "$current_file" .mkv)
                dest_base=$(basename "$episode_filename" .mkv)
                move_subtitles "$src_base" "$dest_base" "$season_path"

                EPISODES_MOVED=$((EPISODES_MOVED + 1))
            fi
        fi

        # Reset for next episode block
        current_file=""
        current_episode=""
        current_title=""
    fi
done < "$BEST_GUESS_FILE"

# Move remaining MKV files (unmatched episodes, extras, bonus content) to extras folder
for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue

    BASENAME=$(basename "$mkv" .mkv)
    DURATION=$(get_duration_minutes "$mkv")

    # Create extras folder if needed
    mkdir -p "$EXTRAS_FOLDER"

    # Move to extras folder, keeping original name
    OUTPUT_FILE="$EXTRAS_FOLDER/${BASENAME}.mkv"
    log "  Extra: $BASENAME.mkv ($DURATION min)"
    mv "$mkv" "$OUTPUT_FILE"

    # Move subtitles for this extra
    move_subtitles "$BASENAME" "$BASENAME" "$EXTRAS_FOLDER"

    EXTRAS_COUNT=$((EXTRAS_COUNT + 1))
done

if [ "$EXTRAS_COUNT" -eq 0 ]; then
    # Remove empty extras folder
    rmdir "$EXTRAS_FOLDER" 2>/dev/null || true
fi

# Clean up any remaining empty SRT files
find "$DISC_DIR" -name "*.srt" -empty -delete 2>/dev/null || true

# Create a marker file indicating successful output
cat > "$DISC_DIR/OUTPUT_COMPLETE.txt" << EOF
OUTPUT_COMPLETE
Type: TV Show
Output: $SERIES_OUTPUT_FOLDER
Date: $(date -Iseconds)
Series: $SERIES_TITLE ($SERIES_YEAR)
IMDB: $IMDB_ID
Episodes Moved: $EPISODES_MOVED
Extras: $EXTRAS_COUNT
EOF

log "Step 9 completed successfully"
log "  Output: $SERIES_OUTPUT_FOLDER"
log "  Episodes: $EPISODES_MOVED"
log "  Extras: $EXTRAS_COUNT"
exit 0
