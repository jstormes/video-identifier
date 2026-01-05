#!/bin/bash
#
# Step 2: Extract dialogue from SRT files
#
# - Strips timestamps and subtitle numbers from SRT
# - Strips leading and trailing whitespace from each line
# - Detects episode boundaries using pattern-based gap detection
# - For videos >60 minutes with gaps creating 15-45 min segments, splits at episode boundaries
# - Falls back to >60 second gap threshold for non-episode content
#
# Usage: step2-extract-dialogue.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

# Episode detection configuration
EPISODE_GAP_THRESHOLD=30      # Minimum gap to consider (seconds)
MIN_EPISODE_DURATION=15       # Minimum episode length (minutes)
MAX_EPISODE_DURATION=45       # Maximum episode length (minutes)
MIN_VIDEO_FOR_SPLITTING=60    # Only split videos longer than this (minutes)
FALLBACK_GAP_THRESHOLD=60     # Original gap threshold for non-episode content

# Detect episode boundaries in an SRT file
# Uses target-based detection: estimates episode count, then finds gaps closest to ideal boundaries
# Usage: detect_episode_boundaries "srt_file" "video_duration_minutes"
# Returns: newline-separated list of gap timestamps (in seconds) to use as boundaries
#          or empty if no valid episode pattern found
detect_episode_boundaries() {
    local srt_file="$1"
    local duration="$2"

    # Only process videos longer than minimum
    if [ "$duration" -lt "$MIN_VIDEO_FOR_SPLITTING" ]; then
        return 0
    fi

    # Extract all gaps > EPISODE_GAP_THRESHOLD with their timestamps
    # Output format: gap_start_sec gap_duration
    local gaps
    gaps=$(sed 's/^\xef\xbb\xbf//' "$srt_file" | awk -v threshold="$EPISODE_GAP_THRESHOLD" '
        /-->/ {
            split($1, start, /[:,]/)
            start_sec = start[1]*3600 + start[2]*60 + start[3]

            split($3, end, /[:,]/)
            end_sec = end[1]*3600 + end[2]*60 + end[3]

            if (prev_end > 0) {
                gap = start_sec - prev_end
                if (gap > threshold) {
                    # Output: timestamp of gap start, gap duration
                    print prev_end, gap
                }
            }
            prev_end = end_sec
        }
    ')

    if [ -z "$gaps" ]; then
        return 0
    fi

    # Convert duration to seconds
    local total_seconds=$((duration * 60))
    local min_seg=$((MIN_EPISODE_DURATION * 60))
    local max_seg=$((MAX_EPISODE_DURATION * 60))

    # Target-based algorithm:
    # 1. Estimate number of episodes (assume ~25 min each)
    # 2. Calculate ideal boundary positions
    # 3. For each ideal position, find the closest gap within valid range

    local target_episode_length=1500  # 25 minutes in seconds
    local estimated_episodes=$((total_seconds / target_episode_length))

    # Need at least 2 episodes to have boundaries
    if [ "$estimated_episodes" -lt 2 ]; then
        return 0
    fi

    # Calculate ideal segment length for this video
    local ideal_segment=$((total_seconds / estimated_episodes))

    # Store gaps in arrays for easier access
    local -a gap_times=()
    local -a gap_durations=()
    while IFS=' ' read -r gt gd; do
        [ -z "$gt" ] && continue
        gap_times+=("$gt")
        gap_durations+=("$gd")
    done <<< "$gaps"

    local num_gaps=${#gap_times[@]}
    if [ "$num_gaps" -eq 0 ]; then
        return 0
    fi

    # Find boundaries: for each target position, find closest valid gap
    local selected_boundaries=""
    local last_boundary=0
    local num_boundaries=$((estimated_episodes - 1))

    for ((b=1; b<=num_boundaries; b++)); do
        local target=$((ideal_segment * b))
        local best_gap=""
        local best_distance=999999

        # Find the gap closest to target that creates a valid segment
        for ((i=0; i<num_gaps; i++)); do
            local gap_time="${gap_times[$i]}"
            local segment_from_last=$((gap_time - last_boundary))

            # Check if this creates a valid segment (15-45 min)
            if [ "$segment_from_last" -ge "$min_seg" ] && [ "$segment_from_last" -le "$max_seg" ]; then
                local distance=$((target - gap_time))
                [ "$distance" -lt 0 ] && distance=$((-distance))

                if [ "$distance" -lt "$best_distance" ]; then
                    best_distance="$distance"
                    best_gap="$gap_time"
                fi
            fi
        done

        # If we found a valid gap for this boundary
        if [ -n "$best_gap" ]; then
            if [ -n "$selected_boundaries" ]; then
                selected_boundaries="${selected_boundaries}"$'\n'"${best_gap}"
            else
                selected_boundaries="${best_gap}"
            fi
            last_boundary="$best_gap"
        fi
    done

    # Verify we found boundaries and final segment is valid
    if [ -n "$selected_boundaries" ]; then
        local final_segment=$((total_seconds - last_boundary))
        if [ "$final_segment" -lt "$min_seg" ] || [ "$final_segment" -gt "$max_seg" ]; then
            # Final segment invalid - pattern doesn't match, return empty
            return 0
        fi
    else
        return 0
    fi

    echo "$selected_boundaries"
}

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

log "Step 2: Extract dialogue from SRT files"
log "Directory: $DISC_DIR"

# Extract dialogue from SRT file with gap detection
# Usage: extract_dialogue "srt_file" "dialogue_file" ["episode_boundaries"]
# episode_boundaries: newline-separated list of timestamps (in seconds) to use as split points
#                     If empty, falls back to FALLBACK_GAP_THRESHOLD (60 sec)
extract_dialogue() {
    local srt_file="$1"
    local dialogue_file="$2"
    local episode_boundaries="${3:-}"

    # Convert episode boundaries to a comma-separated list for awk
    local boundary_list=""
    if [ -n "$episode_boundaries" ]; then
        boundary_list=$(echo "$episode_boundaries" | tr '\n' ',' | sed 's/,$//')
    fi

    # SRT format:
    # 1
    # 00:00:01,234 --> 00:00:03,456
    # Hello, world.
    #
    # 2
    # ...
    #
    # awk extracts dialogue and inserts gap markers
    # If boundary_list provided: insert markers at those specific timestamps (must also be a real gap)
    # Otherwise: insert markers for gaps > FALLBACK_GAP_THRESHOLD
    # First strip BOM and normalize line endings, then process with awk
    sed 's/^\xef\xbb\xbf//' "$srt_file" | awk -v boundaries="$boundary_list" -v fallback_threshold="$FALLBACK_GAP_THRESHOLD" -v episode_threshold="$EPISODE_GAP_THRESHOLD" '
        BEGIN {
            # Parse boundary list into array
            n_boundaries = 0
            if (boundaries != "") {
                n_boundaries = split(boundaries, boundary_arr, ",")
            }
        }
        /-->/ {
            # Parse start timestamp: HH:MM:SS,mmm --> HH:MM:SS,mmm
            split($1, start, /[:,]/)
            start_sec = start[1]*3600 + start[2]*60 + start[3]

            # Parse end timestamp
            split($3, end, /[:,]/)
            end_sec = end[1]*3600 + end[2]*60 + end[3]

            # Check for gap from previous subtitle end
            if (prev_end > 0) {
                gap = start_sec - prev_end

                if (n_boundaries > 0) {
                    # Episode boundary mode: check if this is a real gap AND matches a boundary
                    if (gap > episode_threshold) {
                        for (i = 1; i <= n_boundaries; i++) {
                            # Allow 5 second tolerance for boundary matching
                            if (prev_end >= boundary_arr[i] - 5 && prev_end <= boundary_arr[i] + 5) {
                                printf "\n[GAP:%d]\n\n", gap
                                break
                            }
                        }
                    }
                } else {
                    # Fallback mode: use fixed threshold
                    if (gap > fallback_threshold) {
                        printf "\n[GAP:%d]\n\n", gap
                    }
                }
            }
            prev_end = end_sec
            next
        }
        /^[0-9]+$/ { next }  # Skip subtitle numbers
        /^$/ { next }        # Skip blank lines
        {
            # Strip HTML/formatting tags
            gsub(/<[^>]*>/, "")
            # Strip leading/trailing whitespace
            gsub(/^[[:space:]]+/, "")
            gsub(/[[:space:]]+$/, "")
            if (length($0) > 0) {
                print
            }
        }
    ' > "$dialogue_file"
}

# Split dialogue file at GAP markers
# Creates .dialogue.1.txt, .dialogue.2.txt, etc.
# Usage: split_dialogue_at_gaps "dialogue_file"
split_dialogue_at_gaps() {
    local dialogue_file="$1"
    local base="${dialogue_file%.dialogue.txt}"

    # Count gaps
    local gap_count
    gap_count=$(grep -c '^\[GAP:' "$dialogue_file" 2>/dev/null || echo 0)

    if [ "$gap_count" -eq 0 ]; then
        log "  No gaps found, keeping single dialogue file"
        return
    fi

    log "  Found $gap_count gap(s), splitting dialogue..."

    # Split at gap markers, creating .dialogue.1.txt, .dialogue.2.txt, etc.
    awk -v base="$base" '
        BEGIN {
            file_num = 1
            output = base ".dialogue." file_num ".txt"
        }
        /^\[GAP:/ {
            close(output)
            file_num++
            output = base ".dialogue." file_num ".txt"
            next
        }
        {
            print > output
        }
        END {
            close(output)
        }
    ' "$dialogue_file"

    # Remove original unsplit file
    rm -f "$dialogue_file"

    log "  Created $((gap_count + 1)) dialogue sub-files"
}

# Find MKV file for a given SRT
# Returns the MKV path or empty string
find_mkv_for_srt() {
    local srt_file="$1"
    local srt_name
    srt_name=$(basename "$srt_file")

    # Try various patterns to match SRT to MKV
    # movie.eng.srt -> movie.mkv
    # movie.track2.srt -> movie.mkv
    local base="${srt_name%.srt}"      # Remove .srt
    base="${base%.eng}"                 # Remove .eng
    base="${base%.spa}"                 # Remove .spa
    base="${base%.fra}"                 # Remove .fra
    base="${base%.deu}"                 # Remove .deu
    base="${base%.por}"                 # Remove .por
    base="${base%.ita}"                 # Remove .ita
    base="${base%.und}"                 # Remove .und
    base=$(echo "$base" | sed 's/\.track[0-9]*$//')  # Remove .trackN

    local mkv_file="$DISC_DIR/${base}.mkv"
    if [ -f "$mkv_file" ]; then
        echo "$mkv_file"
    fi
}

# Process each SRT file
PROCESSED=0
SPLIT_COUNT=0

for srt in "$DISC_DIR"/*.srt; do
    [ -f "$srt" ] || continue
    [ -s "$srt" ] || continue  # Skip empty files

    srt_name=$(basename "$srt" .srt)

    # Create dialogue file (same name but .dialogue.txt)
    dialogue_file="$DISC_DIR/${srt_name}.dialogue.txt"

    log "Processing: $srt_name.srt"

    # Find corresponding MKV to check duration and detect episode boundaries
    mkv_file=$(find_mkv_for_srt "$srt")
    episode_boundaries=""
    duration=0

    if [ -n "$mkv_file" ] && [ -f "$mkv_file" ]; then
        duration=$(get_duration_minutes "$mkv_file")

        # Try to detect episode boundaries for long videos
        if [ "$duration" -ge "$MIN_VIDEO_FOR_SPLITTING" ]; then
            episode_boundaries=$(detect_episode_boundaries "$srt" "$duration")
            if [ -n "$episode_boundaries" ]; then
                boundary_count=$(echo "$episode_boundaries" | wc -l | tr -d ' ')
                log "  Detected $boundary_count episode boundary(ies) in ${duration}min video"
            fi
        fi
    fi

    # Extract dialogue with episode boundaries (or fallback to >60s gaps)
    extract_dialogue "$srt" "$dialogue_file" "$episode_boundaries"

    lines=$(wc -l < "$dialogue_file")
    log "  Created: $(basename "$dialogue_file") ($lines lines)"

    # For videos >45 minutes with gaps, split the dialogue
    if [ "$duration" -gt 45 ]; then
        # Use head -1 to avoid multiline issues from grep -c
        gap_count=$(grep -c '^\[GAP:' "$dialogue_file" 2>/dev/null | head -1 || echo 0)
        gap_count=${gap_count:-0}

        if [ "$gap_count" -gt 0 ]; then
            log "  Video is $duration min with $gap_count gap(s), splitting..."
            split_dialogue_at_gaps "$dialogue_file"
            SPLIT_COUNT=$((SPLIT_COUNT + 1))
        fi
    fi

    PROCESSED=$((PROCESSED + 1))
done

# Count total dialogue files created
TOTAL_DIALOGUE=$(find "$DISC_DIR" -maxdepth 1 -name "*.dialogue*.txt" -type f | wc -l)

log "Results: $PROCESSED SRT files processed, $TOTAL_DIALOGUE dialogue files created"
if [ "$SPLIT_COUNT" -gt 0 ]; then
    log "  $SPLIT_COUNT files were split at gap markers"
fi

if [ "$TOTAL_DIALOGUE" -eq 0 ]; then
    log_error "No dialogue files created"
    exit 1
fi

log "Step 2 completed successfully"
exit 0
