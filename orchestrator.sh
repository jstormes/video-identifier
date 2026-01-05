#!/bin/bash
#
# Video Identifier Pipeline Orchestrator
#
# Runs the 9-step pipeline for identifying DVD/video content:
#   1. Extract SRT from video files
#   2. Extract dialogue from SRT
#   3. Extract characters using LLM
#   4. Create DISK_METADATA.txt
#   5. Initial IMDB lookup
#   6. Movie matching (if MOVIE.txt)
#   7. TV matching (if TV.txt)
#   8. TV/Movie hybrid matching (if TV_MOVIE.txt)
#   9. Output to Jellyfin-compatible structure
#
# Usage: orchestrator.sh <disc_directory>
#
# Environment variables:
#   LLM_BASE_URL    - LLM server URL (default: http://nas2:8191/v1)
#   LLM_MODEL       - Model name (default: qwen3-30b)
#   IMDB_HOST       - MariaDB host (default: nas2)
#   IMDB_USER       - Database user (default: imdb)
#   IMDB_PASSWORD   - Database password (required for IMDB lookup)
#   IMDB_DATABASE   - Database name (default: imdb)
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

DISC_DIR="$1"

if [ -z "$DISC_DIR" ]; then
    echo "Usage: $0 <disc_directory>"
    echo ""
    echo "Runs the video identification pipeline on a directory containing MKV files."
    echo ""
    echo "Environment variables:"
    echo "  LLM_BASE_URL    - LLM server URL (default: http://nas2:8191/v1)"
    echo "  LLM_MODEL       - Model name (default: qwen3-30b)"
    echo "  IMDB_HOST       - MariaDB host (default: nas2)"
    echo "  IMDB_USER       - Database user (default: imdb)"
    echo "  IMDB_PASSWORD   - Database password (required)"
    echo "  IMDB_DATABASE   - Database name (default: imdb)"
    exit 1
fi

if [ ! -d "$DISC_DIR" ]; then
    log_error "Directory not found: $DISC_DIR"
    exit 1
fi

# Make sure path is absolute
DISC_DIR=$(cd "$DISC_DIR" && pwd)

DISC_NAME=$(basename "$DISC_DIR")
STATUS_FILE="$DISC_DIR/pipeline_status.json"

log "========================================"
log "Video Identifier Pipeline"
log "========================================"
log "Directory: $DISC_DIR"
log "Disc name: $DISC_NAME"
log ""

# Initialize status file
init_status() {
    cat > "$STATUS_FILE" << EOF
{
  "disc_name": "$DISC_NAME",
  "disc_dir": "$DISC_DIR",
  "start_time": "$(date -Iseconds)",
  "status": "running",
  "current_step": 0,
  "steps": {
    "1": {"name": "extract_srt", "status": "pending"},
    "2": {"name": "extract_dialogue", "status": "pending"},
    "3": {"name": "extract_characters", "status": "pending"},
    "4": {"name": "create_metadata", "status": "pending"},
    "5": {"name": "imdb_lookup", "status": "pending"},
    "6": {"name": "movie_matching", "status": "pending"},
    "7": {"name": "tv_matching", "status": "pending"},
    "8": {"name": "hybrid_matching", "status": "pending"},
    "9": {"name": "output", "status": "pending"}
  }
}
EOF
}

# Update step status in JSON file
update_step_status() {
    local step="$1"
    local status="$2"
    local message="${3:-}"

    if command -v jq &> /dev/null; then
        local tmp_file="${STATUS_FILE}.tmp"
        jq ".current_step = $step | .steps.\"$step\".status = \"$status\" | .steps.\"$step\".message = \"$message\"" \
            "$STATUS_FILE" > "$tmp_file" && mv "$tmp_file" "$STATUS_FILE"
    fi
}

# Update final status
update_final_status() {
    local status="$1"
    local message="${2:-}"

    if command -v jq &> /dev/null; then
        local tmp_file="${STATUS_FILE}.tmp"
        jq ".status = \"$status\" | .end_time = \"$(date -Iseconds)\" | .message = \"$message\"" \
            "$STATUS_FILE" > "$tmp_file" && mv "$tmp_file" "$STATUS_FILE"
    fi
}

# Run a pipeline step
run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_script="$3"

    log "----------------------------------------"
    log "Step $step_num: $step_name"
    log "----------------------------------------"

    update_step_status "$step_num" "running"

    if "$SCRIPT_DIR/$step_script" "$DISC_DIR"; then
        update_step_status "$step_num" "completed"
        log ""
        return 0
    else
        local exit_code=$?
        update_step_status "$step_num" "failed" "Exit code: $exit_code"

        # Check if UNKNOWN.txt was created (expected failure)
        if [ -f "$DISC_DIR/UNKNOWN.txt" ]; then
            local reason
            reason=$(cat "$DISC_DIR/UNKNOWN.txt")
            log "Pipeline stopped: $reason"
            update_final_status "stopped" "$reason"
            return 1
        fi

        log_error "Step $step_num failed with exit code $exit_code"
        update_final_status "failed" "Step $step_num failed"
        return 1
    fi
}

# Initialize
init_status

# Clear any previous UNKNOWN.txt
rm -f "$DISC_DIR/UNKNOWN.txt"

# Run pipeline steps
PIPELINE_SUCCESS=true

# Step 1: Extract SRT
if ! run_step 1 "Extract SRT" "step1-extract-srt.sh"; then
    PIPELINE_SUCCESS=false
fi

# Step 2: Extract Dialogue (only if step 1 succeeded)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 2 "Extract Dialogue" "step2-extract-dialogue.sh"; then
        PIPELINE_SUCCESS=false
    fi
fi

# Step 3: Extract Characters (only if previous steps succeeded)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 3 "Extract Characters" "step3-extract-characters.sh"; then
        PIPELINE_SUCCESS=false
    fi
fi

# Step 4: Create Metadata (only if previous steps succeeded)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 4 "Create Metadata" "step4-create-metadata.sh"; then
        PIPELINE_SUCCESS=false
    fi
fi

# Step 5: IMDB Lookup (only if previous steps succeeded)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 5 "IMDB Lookup" "step5-imdb-lookup.sh"; then
        PIPELINE_SUCCESS=false
    fi
fi

# Step 6: Movie Matching (runs if MOVIE.txt exists)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 6 "Movie Matching" "step6-movie-matching.sh"; then
        # Non-fatal - continue with other steps
        log "Warning: Movie matching failed, continuing..."
    fi
fi

# Step 7: TV Matching (runs if TV.txt exists)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 7 "TV Matching" "step7-tv-matching.sh"; then
        # Non-fatal - continue with other steps
        log "Warning: TV matching failed, continuing..."
    fi
fi

# Step 8: Hybrid Matching (runs if TV_MOVIE.txt exists)
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    if ! run_step 8 "Hybrid Matching" "step8-hybrid-matching.sh"; then
        # Non-fatal
        log "Warning: Hybrid matching failed"
    fi
fi

# Step 9: Output to Jellyfin-compatible structure
# Run the appropriate output script based on content type
if [ "$PIPELINE_SUCCESS" = true ] && [ ! -f "$DISC_DIR/UNKNOWN.txt" ]; then
    log "----------------------------------------"
    log "Step 9: Output Files"
    log "----------------------------------------"

    update_step_status 9 "running"

    OUTPUT_SUCCESS=false

    # Try movie output (handles MOVIE.txt and TV_MOVIE.txt)
    if [ -f "$DISC_DIR/MOVIE.txt" ] || [ -f "$DISC_DIR/TV_MOVIE.txt" ]; then
        if "$SCRIPT_DIR/step9-output-movie.sh" "$DISC_DIR"; then
            OUTPUT_SUCCESS=true
        else
            log "Warning: Movie output failed"
        fi
    fi

    # Try TV output (handles TV.txt)
    if [ -f "$DISC_DIR/TV.txt" ]; then
        if "$SCRIPT_DIR/step9-output-tv.sh" "$DISC_DIR"; then
            OUTPUT_SUCCESS=true
        else
            log "Warning: TV output failed"
        fi
    fi

    if [ "$OUTPUT_SUCCESS" = true ]; then
        update_step_status 9 "completed"
    else
        update_step_status 9 "failed" "No output generated"
        log "Warning: No output was generated"
    fi

    log ""
fi

# Final summary
log ""
log "========================================"
log "Pipeline Complete"
log "========================================"

if [ -f "$DISC_DIR/UNKNOWN.txt" ]; then
    log "Status: STOPPED"
    log "Reason: $(cat "$DISC_DIR/UNKNOWN.txt")"
    update_final_status "stopped" "$(cat "$DISC_DIR/UNKNOWN.txt")"
    exit 1
elif [ "$PIPELINE_SUCCESS" = true ]; then
    log "Status: SUCCESS"

    # Show results
    if [ -f "$DISC_DIR/BEST_GUESS.txt" ]; then
        log ""
        log "Best Guess:"
        head -20 "$DISC_DIR/BEST_GUESS.txt" | while read -r line; do
            log "  $line"
        done
    fi

    update_final_status "completed" "Pipeline completed successfully"
    exit 0
else
    log "Status: FAILED"
    update_final_status "failed" "Pipeline failed"
    exit 1
fi
