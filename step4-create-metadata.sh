#!/bin/bash
#
# Step 4: Create DISK_METADATA.txt
#
# Contains:
# - Disk name
# - Number of SRT files
# - Length in minutes of each video file
# - Disk Name Parsed: Season (if found), Disk Number (if found)
# - Number of video files with SRT
# - Video file with SRT, Length in Minutes, Number of >1 minute gaps
# - Number of files that are same length (±60 seconds)
# - Approximate length of same-length video files
# - Longest file in minutes with number of >1 minute gaps
# - Character names from CHARACTERS.txt (step 3)
#
# Usage: step4-create-metadata.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

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

log "Step 4: Create DISK_METADATA.txt"
log "Directory: $DISC_DIR"

METADATA_FILE="$DISC_DIR/DISK_METADATA.txt"

# Get disc name: prefer DISC_NAME env var, then try MKV filename, then directory basename
if [ -n "$DISC_NAME" ]; then
    # Use environment variable if provided
    :
else
    # Try to extract from MKV filename (e.g., "Superman_t00.mkv" -> "Superman")
    first_mkv=$(ls "$DISC_DIR"/*.mkv 2>/dev/null | head -1)
    if [ -n "$first_mkv" ]; then
        mkv_base=$(basename "$first_mkv" .mkv)
        # Remove _tNN suffix to get disc name
        DISC_NAME=$(echo "$mkv_base" | sed 's/_t[0-9]*$//')
        # If result looks like a code (e.g., B1, C1), fall back to directory name
        if [[ "$DISC_NAME" =~ ^[A-Z][0-9]$ ]]; then
            DISC_NAME=$(basename "$DISC_DIR")
        fi
    else
        DISC_NAME=$(basename "$DISC_DIR")
    fi
fi

# Count SRT files
SRT_COUNT=$(find "$DISC_DIR" -maxdepth 1 -name "*.srt" -type f | wc -l)

# Parse disc name for season/disc info
PARSED_SEASON=$(parse_season_from_name "$DISC_NAME")
PARSED_DISC=$(parse_disc_from_name "$DISC_NAME")

# Get video file information
declare -A VIDEO_LENGTHS
declare -a LENGTH_LIST
LONGEST_FILE=""
LONGEST_MINUTES=0
MKV_WITH_SRT=0

for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue

    base=$(basename "$mkv" .mkv)
    minutes=$(get_duration_minutes "$mkv")

    VIDEO_LENGTHS["$base"]=$minutes
    LENGTH_LIST+=("$minutes")

    # Check if this MKV has an associated SRT
    if ls "$DISC_DIR/${base}"*.srt 1>/dev/null 2>&1; then
        MKV_WITH_SRT=$((MKV_WITH_SRT + 1))
    fi

    if [ "$minutes" -gt "$LONGEST_MINUTES" ]; then
        LONGEST_MINUTES=$minutes
        LONGEST_FILE="$base"
    fi
done

TOTAL_MKV=${#VIDEO_LENGTHS[@]}

# Detect same-length files (within 60 seconds = 1 minute)
SAME_LENGTH_COUNT=0
SAME_LENGTH_APPROX=0

for len in "${LENGTH_LIST[@]}"; do
    count=0
    for other in "${LENGTH_LIST[@]}"; do
        diff=$((len > other ? len - other : other - len))
        if [ "$diff" -le 1 ]; then
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt "$SAME_LENGTH_COUNT" ]; then
        SAME_LENGTH_COUNT=$count
        SAME_LENGTH_APPROX=$len
    fi
done

# Build video file details with gap counts
VIDEO_DETAILS=""
for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue

    base=$(basename "$mkv" .mkv)
    minutes=${VIDEO_LENGTHS["$base"]}
    has_srt="no"
    gap_count=0

    # Check for SRT
    if ls "$DISC_DIR/${base}"*.srt 1>/dev/null 2>&1; then
        has_srt="yes"
    fi

    # Count gaps/splits from English dialogue files only
    # Check for split files first (e.g., .en.dialogue.1.txt or .eng.dialogue.1.txt)
    en_split_count=$(ls "$DISC_DIR/${base}".en.dialogue.[0-9]*.txt "$DISC_DIR/${base}".eng.dialogue.[0-9]*.txt 2>/dev/null | wc -l)
    if [ "$en_split_count" -gt 0 ]; then
        # Split files exist - gaps = number of splits - 1
        gap_count=$((en_split_count - 1))
    else
        # No splits - count [GAP:] markers in English dialogue file only
        for dialogue in "$DISC_DIR/${base}".en.dialogue.txt "$DISC_DIR/${base}".eng.dialogue.txt; do
            [ -f "$dialogue" ] || continue
            gaps=$(grep -c '^\[GAP:' "$dialogue" 2>/dev/null | head -1 || echo 0)
            gaps=${gaps:-0}
            gap_count=$((gap_count + gaps))
            break  # Only count one English file
        done
    fi

    VIDEO_DETAILS="${VIDEO_DETAILS}  ${base}.mkv: ${minutes} min, SRT: ${has_srt}, Gaps: ${gap_count}
"
done

# Count gaps in longest file's English dialogue only
LONGEST_GAPS=0
en_split_count=$(ls "$DISC_DIR/${LONGEST_FILE}".en.dialogue.[0-9]*.txt "$DISC_DIR/${LONGEST_FILE}".eng.dialogue.[0-9]*.txt 2>/dev/null | wc -l)
if [ "$en_split_count" -gt 0 ]; then
    # Split files exist
    LONGEST_GAPS=$((en_split_count - 1))
else
    # Count [GAP:] markers in English dialogue file only
    for dialogue in "$DISC_DIR/${LONGEST_FILE}".en.dialogue.txt "$DISC_DIR/${LONGEST_FILE}".eng.dialogue.txt; do
        [ -f "$dialogue" ] || continue
        gaps=$(grep -c '^\[GAP:' "$dialogue" 2>/dev/null | head -1 || echo 0)
        LONGEST_GAPS=${gaps:-0}
        break
    done
fi

# Use characters from step 3 (CHARACTERS.txt) instead of separate LLM call
# This avoids redundant LLM processing since character names are the key proper nouns
CHARACTERS_FILE="$DISC_DIR/CHARACTERS.txt"
if [ -f "$CHARACTERS_FILE" ] && [ -s "$CHARACTERS_FILE" ]; then
    log "Using character list from step 3..."
    # Indent each line for display
    PROPER_NOUNS=$(grep -v '^#' "$CHARACTERS_FILE" | sed 's/^/  /')
else
    log "Warning: No CHARACTERS.txt found from step 3"
    PROPER_NOUNS="  (none - run step 3 first)"
fi

# Write metadata file
cat > "$METADATA_FILE" << EOF
DISK_METADATA
=============
Generated: $(date -Iseconds)

Disk Name: $DISC_NAME

Disk Name Parsed:
  Season: ${PARSED_SEASON:-not found}
  Disk Number: ${PARSED_DISC:-not found}

Video Files:
  Total MKV files: $TOTAL_MKV
  MKV files with SRT: $MKV_WITH_SRT

SRT Files:
  Total SRT files: $SRT_COUNT

Video File Details:
$VIDEO_DETAILS
Same-Length Analysis:
  Files within 60 seconds of each other: $SAME_LENGTH_COUNT
  Approximate length: $SAME_LENGTH_APPROX minutes

Longest File:
  File: ${LONGEST_FILE}.mkv
  Length: $LONGEST_MINUTES minutes
  Gaps >1 minute: $LONGEST_GAPS

Characters (from step 3):
$PROPER_NOUNS
EOF

log "Created: DISK_METADATA.txt"
log "  Disc: $DISC_NAME"
log "  Season: ${PARSED_SEASON:-none}, Disc: ${PARSED_DISC:-none}"
log "  MKV files: $TOTAL_MKV ($MKV_WITH_SRT with SRT)"
log "  Same-length files: $SAME_LENGTH_COUNT (~$SAME_LENGTH_APPROX min)"
log "  Longest: ${LONGEST_FILE}.mkv ($LONGEST_MINUTES min, $LONGEST_GAPS gaps)"

log "Step 4 completed successfully"
exit 0
