#!/bin/bash
#
# Step 6: Movie Matching (if MOVIE.txt exists)
#
# - Extract 6K story summary of longest video file from dialogues using LLM
# - Match summary against FRANCHISE_SHORT_LIST.txt using LLM
# - Write match to BEST_GUESS.txt
#
# Usage: step6-movie-matching.sh <disc_directory>
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

# Only run if MOVIE.txt exists
if [ ! -f "$DISC_DIR/MOVIE.txt" ]; then
    log "Step 6: Skipping (not a movie disc)"
    exit 0
fi

log "Step 6: Movie Matching"
log "Directory: $DISC_DIR"

FRANCHISE_FILE="$DISC_DIR/FRANCHISE_SHORT_LIST.txt"
BEST_GUESS_FILE="$DISC_DIR/BEST_GUESS.txt"

if [ ! -f "$FRANCHISE_FILE" ]; then
    log_error "FRANCHISE_SHORT_LIST.txt not found"
    exit 1
fi

# Find the longest video's dialogue
LONGEST_MKV=$(find_longest_mkv "$DISC_DIR")

if [ -z "$LONGEST_MKV" ]; then
    log_error "No MKV files found"
    exit 1
fi

LONGEST_BASE=$(basename "$LONGEST_MKV" .mkv)
log "Longest video: $LONGEST_BASE"

# Find English dialogue file(s) for this video
# Match both .en. and .eng. patterns (different subtitle naming conventions)
DIALOGUE_TEXT=""
for dialogue in "$DISC_DIR/${LONGEST_BASE}".en.dialogue*.txt "$DISC_DIR/${LONGEST_BASE}".eng.dialogue*.txt; do
    [ -f "$dialogue" ] || continue
    DIALOGUE_TEXT="${DIALOGUE_TEXT}$(cat "$dialogue")
"
done

if [ -z "$DIALOGUE_TEXT" ]; then
    # Fallback: try any English dialogue file
    for dialogue in "$DISC_DIR"/*.en.dialogue*.txt "$DISC_DIR"/*.eng.dialogue*.txt; do
        [ -f "$dialogue" ] || continue
        DIALOGUE_TEXT="${DIALOGUE_TEXT}$(cat "$dialogue")
"
        break  # Just use first one found
    done
fi

if [ -z "$DIALOGUE_TEXT" ]; then
    log_error "No dialogue files found for longest video"
    exit 1
fi

# Generate 6K story summary
log "Generating story summary via LLM..."
STORY_SUMMARY=$(generate_story_summary "$DIALOGUE_TEXT" "movie")

if [ -z "$STORY_SUMMARY" ]; then
    log_error "Failed to generate story summary"
    exit 1
fi

SUMMARY_LENGTH=${#STORY_SUMMARY}
log "  Summary generated ($SUMMARY_LENGTH characters)"

# Read franchise list
FRANCHISE_LIST=$(cat "$FRANCHISE_FILE")

# Match against franchise list using LLM
log "Matching summary against franchise list..."
MATCH_RESULT=$(match_story_to_franchise "$STORY_SUMMARY" "$FRANCHISE_LIST")

if [ -z "$MATCH_RESULT" ]; then
    log_error "Failed to match story to franchise"
    exit 1
fi

# Parse result
BEST_MATCH=$(echo "$MATCH_RESULT" | jq -r '.best_match // "unknown"')
TITLE=$(echo "$MATCH_RESULT" | jq -r '.title // "Unknown"')
YEAR=$(echo "$MATCH_RESULT" | jq -r '.year // ""')
CONFIDENCE=$(echo "$MATCH_RESULT" | jq -r '.confidence // "low"')
REASONING=$(echo "$MATCH_RESULT" | jq -r '.reasoning // ""')

# Write BEST_GUESS.txt
cat > "$BEST_GUESS_FILE" << EOF
BEST_GUESS - Movie
==================
Generated: $(date -Iseconds)

Match Type: Movie
Confidence: $CONFIDENCE

Best Match:
  IMDB ID: $BEST_MATCH
  Title: $TITLE
  Year: $YEAR

Reasoning:
  $REASONING

Source File: ${LONGEST_BASE}.mkv

Story Summary:
$STORY_SUMMARY
EOF

log "Match result:"
log "  Title: $TITLE ($YEAR)"
log "  IMDB: $BEST_MATCH"
log "  Confidence: $CONFIDENCE"

log "Step 6 completed successfully"
exit 0
