#!/bin/bash
#
# Common utility functions for video-identifier pipeline
#

# Logging functions
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_debug() {
    if [ "${DEBUG:-}" = "true" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2
    fi
}

# Get video duration in minutes using mkvmerge
# Returns 0 if duration cannot be determined
get_duration_minutes() {
    local mkv_file="$1"

    if [ ! -f "$mkv_file" ]; then
        echo 0
        return
    fi

    # Try mkvmerge first (most reliable)
    local duration_ns
    duration_ns=$(mkvmerge -J "$mkv_file" 2>/dev/null | jq -r '.container.properties.duration // 0' 2>/dev/null)

    if [ -n "$duration_ns" ] && [ "$duration_ns" != "0" ] && [ "$duration_ns" != "null" ]; then
        # Duration is in nanoseconds, convert to minutes
        echo $((duration_ns / 1000000000 / 60))
        return
    fi

    # Fallback: try mkvinfo
    local duration_str
    duration_str=$(mkvinfo "$mkv_file" 2>/dev/null | grep -i "duration" | head -1 | grep -oE '[0-9]+:[0-9]+:[0-9]+' | head -1)

    if [ -n "$duration_str" ]; then
        local hours mins secs
        hours=$(echo "$duration_str" | cut -d: -f1)
        mins=$(echo "$duration_str" | cut -d: -f2)
        secs=$(echo "$duration_str" | cut -d: -f3)
        # Remove leading zeros to avoid octal interpretation
        hours=$((10#$hours))
        mins=$((10#$mins))
        echo $((hours * 60 + mins))
        return
    fi

    echo 0
}

# Get video duration in seconds (more precise)
get_duration_seconds() {
    local mkv_file="$1"

    if [ ! -f "$mkv_file" ]; then
        echo 0
        return
    fi

    local duration_ns
    duration_ns=$(mkvmerge -J "$mkv_file" 2>/dev/null | jq -r '.container.properties.duration // 0' 2>/dev/null)

    if [ -n "$duration_ns" ] && [ "$duration_ns" != "0" ] && [ "$duration_ns" != "null" ]; then
        echo $((duration_ns / 1000000000))
        return
    fi

    echo 0
}

# Parse season number from disc name
# Matches patterns: S1, S01, Season_1, Season 1, Season01, etc.
parse_season_from_name() {
    local name="$1"
    local season

    # Try different patterns
    season=$(echo "$name" | grep -oiE '(season[_[:space:]]?|s)([0-9]+)' | grep -oE '[0-9]+' | head -1)

    if [ -n "$season" ]; then
        # Remove leading zeros
        echo $((10#$season))
    fi
}

# Parse disc number from disc name
# Matches patterns: D1, D01, Disc_1, Disc 1, Disc01, etc.
parse_disc_from_name() {
    local name="$1"
    local disc

    # Try different patterns
    disc=$(echo "$name" | grep -oiE '(disc[_[:space:]]?|d)([0-9]+)' | grep -oE '[0-9]+' | head -1)

    if [ -n "$disc" ]; then
        # Remove leading zeros
        echo $((10#$disc))
    fi
}

# Count MKV files with duration over specified minutes
count_files_over_duration() {
    local dir="$1"
    local min_minutes="$2"
    local count=0

    for mkv in "$dir"/*.mkv; do
        [ -f "$mkv" ] || continue
        local duration
        duration=$(get_duration_minutes "$mkv")
        if [ "$duration" -gt "$min_minutes" ]; then
            count=$((count + 1))
        fi
    done

    echo "$count"
}

# Find the longest MKV file in a directory
# Returns the full path
find_longest_mkv() {
    local dir="$1"
    local longest_file=""
    local longest_duration=0

    for mkv in "$dir"/*.mkv; do
        [ -f "$mkv" ] || continue
        local duration
        duration=$(get_duration_minutes "$mkv")
        if [ "$duration" -gt "$longest_duration" ]; then
            longest_duration=$duration
            longest_file="$mkv"
        fi
    done

    echo "$longest_file"
}

# Count gaps in a dialogue file
# Returns count of [GAP:N] markers
count_dialogue_gaps() {
    local dialogue_file="$1"

    if [ ! -f "$dialogue_file" ]; then
        echo 0
        return
    fi

    grep -c '^\[GAP:' "$dialogue_file" 2>/dev/null || echo 0
}

# Extract title from disc name
# Removes UUID prefixes, season/disc suffixes, and cleans up formatting
extract_title_from_disc_name() {
    local disc_name="$1"
    local title

    # Remove common UUID-like prefixes (8 hex chars followed by dash)
    title=$(echo "$disc_name" | sed 's/^[0-9a-fA-F]\{8\}-//')

    # Replace underscores with spaces
    title=$(echo "$title" | tr '_' ' ')

    # Remove common suffixes: S1, D1, S01, D01, Season 1, Disc 1, ok, etc.
    title=$(echo "$title" | sed -E 's/[[:space:]]+(S|D|Season|Disc)[[:space:]]*[0-9]+//gi')
    title=$(echo "$title" | sed -E 's/[[:space:]]+(ok|done|ripped|complete)$//gi')

    # Remove trailing numbers and spaces
    title=$(echo "$title" | sed 's/[[:space:]]*[0-9]*[[:space:]]*$//')

    # Trim leading/trailing whitespace
    title=$(echo "$title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    echo "$title"
}

# Check if a file exists and has non-zero size
file_exists_and_nonempty() {
    local file="$1"
    [ -f "$file" ] && [ -s "$file" ]
}

# Create a marker file (just writes the marker name to the file)
create_marker_file() {
    local dir="$1"
    local marker="$2"
    echo "$marker" > "$dir/${marker}.txt"
}

# Check if pipeline should stop (UNKNOWN.txt exists)
should_stop_pipeline() {
    local dir="$1"
    [ -f "$dir/UNKNOWN.txt" ]
}

# Sanitize title for filesystem
# - Remove reserved characters: < > : " / \ | ? *
# - Remove invalid/replacement characters (�)
# - Convert common accented characters to ASCII equivalents
# - Collapse multiple spaces
sanitize_filename() {
    local name="$1"
    echo "$name" | \
        # Replace common accented characters with ASCII equivalents
        sed 's/[àáâãäå]/a/g; s/[ÀÁÂÃÄÅ]/A/g' | \
        sed 's/[èéêë]/e/g; s/[ÈÉÊË]/E/g' | \
        sed 's/[ìíîï]/i/g; s/[ÌÍÎÏ]/I/g' | \
        sed 's/[òóôõö]/o/g; s/[ÒÓÔÕÖ]/O/g' | \
        sed 's/[ùúûü]/u/g; s/[ÙÚÛÜ]/U/g' | \
        sed 's/[ñ]/n/g; s/[Ñ]/N/g' | \
        sed 's/[ç]/c/g; s/[Ç]/C/g' | \
        # Remove reserved filesystem characters
        sed 's/[<>:"\/\\|?*]//g' | \
        # Remove replacement character and other invalid Unicode
        sed 's/\xef\xbf\xbd//g' | \
        sed 's/�//g' | \
        # Remove any remaining non-printable or control characters
        tr -cd '[:print:]' | \
        # Collapse multiple spaces and trim
        sed 's/[[:space:]]\+/ /g' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
