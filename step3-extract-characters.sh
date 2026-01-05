#!/bin/bash
#
# Step 3: Extract character list from dialogue files using LLM
#
# For multi-SRT file dialogues, loops over extracting to file adding characters as found.
# Accumulates unique characters across all files into CHARACTERS.txt
#
# Usage: step3-extract-characters.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/llm.sh"

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

log "Step 3: Extract character list from dialogue files"
log "Directory: $DISC_DIR"

CHARACTERS_FILE="$DISC_DIR/CHARACTERS.txt"
TEMP_CHARS="$DISC_DIR/.temp_characters_$$"

# Initialize temp file
> "$TEMP_CHARS"

cleanup() {
    rm -f "$TEMP_CHARS"
}
trap cleanup EXIT

# Process each dialogue file
PROCESSED=0
TOTAL_CHARS=0

# Only process English dialogue files to reduce LLM calls
# Match both .en. and .eng. patterns (different subtitle naming conventions)
for dialogue in "$DISC_DIR"/*.en.dialogue*.txt "$DISC_DIR"/*.eng.dialogue*.txt; do
    [ -f "$dialogue" ] || continue
    [ -s "$dialogue" ] || continue  # Skip empty files

    dialogue_name=$(basename "$dialogue")

    log "Processing: $dialogue_name"

    # Read dialogue content
    dialogue_text=$(cat "$dialogue")

    if [ -z "$dialogue_text" ]; then
        log "  Skipping empty dialogue file"
        continue
    fi

    # Call LLM to extract characters
    log "  Calling LLM to extract characters..."
    characters_json=$(extract_characters_llm "$dialogue_text")

    if [ -n "$characters_json" ] && [ "$characters_json" != "[]" ]; then
        # Parse JSON array and add to temp file
        echo "$characters_json" | jq -r '.[]' 2>/dev/null >> "$TEMP_CHARS"

        count=$(echo "$characters_json" | jq -r '.[]' 2>/dev/null | wc -l)
        log "  Found $count character(s)"
        TOTAL_CHARS=$((TOTAL_CHARS + count))
    else
        log "  No characters extracted"
    fi

    PROCESSED=$((PROCESSED + 1))
done

# Deduplicate and sort characters
if [ -s "$TEMP_CHARS" ]; then
    # Remove duplicates (case-insensitive) and sort
    sort -u -f "$TEMP_CHARS" | grep -v '^$' > "$CHARACTERS_FILE"

    unique_count=$(wc -l < "$CHARACTERS_FILE")
    log "Results: Processed $PROCESSED dialogue files"
    log "  Total characters found: $TOTAL_CHARS"
    log "  Unique characters: $unique_count"
    log "  Output: CHARACTERS.txt"
else
    log "Warning: No characters extracted from any dialogue file"
    echo "# No characters extracted" > "$CHARACTERS_FILE"
fi

log "Step 3 completed successfully"
exit 0
