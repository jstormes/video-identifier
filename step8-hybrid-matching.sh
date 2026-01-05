#!/bin/bash
#
# Step 8: TV/Movie Hybrid Matching (if TV_MOVIE.txt exists)
#
# For the longest video:
# - Use the LLM to write a 6K story summary
# - Using the LLM and the FRANCHISE_SHORT_LIST try to match the title
#   to a title in the IMDB Database
# - Write that match into BEST_GUESS.txt
#
# Usage: step8-hybrid-matching.sh <disc_directory>
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

# Only run if TV_MOVIE.txt exists
if [ ! -f "$DISC_DIR/TV_MOVIE.txt" ]; then
    log "Step 8: Skipping (not a hybrid disc)"
    exit 0
fi

log "Step 8: TV/Movie Hybrid Matching"
log "Directory: $DISC_DIR"

FRANCHISE_FILE="$DISC_DIR/FRANCHISE_SHORT_LIST.txt"
METADATA_FILE="$DISC_DIR/DISK_METADATA.txt"
BEST_GUESS_FILE="$DISC_DIR/BEST_GUESS.txt"

if [ ! -f "$FRANCHISE_FILE" ]; then
    log_error "FRANCHISE_SHORT_LIST.txt not found"
    exit 1
fi

# Get season hint from metadata (might be relevant if it's a TV special)
PARSED_SEASON=""
if [ -f "$METADATA_FILE" ]; then
    PARSED_SEASON=$(grep "Season:" "$METADATA_FILE" | sed 's/.*Season:[[:space:]]*//' | grep -v "not found" || true)
fi

# Find the longest video
LONGEST_MKV=$(find_longest_mkv "$DISC_DIR")

if [ -z "$LONGEST_MKV" ]; then
    log_error "No MKV files found"
    exit 1
fi

LONGEST_BASE=$(basename "$LONGEST_MKV" .mkv)
LONGEST_DURATION=$(get_duration_minutes "$LONGEST_MKV")

log "Longest video: $LONGEST_BASE ($LONGEST_DURATION min)"

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
        break
    done
fi

if [ -z "$DIALOGUE_TEXT" ]; then
    log_error "No dialogue files found for longest video"
    exit 1
fi

# Generate story summary
log "Generating story summary via LLM..."

# Determine likely content type based on duration
CONTENT_TYPE="movie"
if [ "$LONGEST_DURATION" -lt 60 ]; then
    CONTENT_TYPE="episode"
fi

STORY_SUMMARY=$(generate_story_summary "$DIALOGUE_TEXT" "$CONTENT_TYPE")

if [ -z "$STORY_SUMMARY" ]; then
    log_error "Failed to generate story summary"
    exit 1
fi

SUMMARY_LENGTH=${#STORY_SUMMARY}
log "  Summary generated ($SUMMARY_LENGTH characters)"

# Read franchise list
FRANCHISE_LIST=$(cat "$FRANCHISE_FILE")

# First try character-based matching (more reliable than LLM title guessing)
CHARACTERS_FILE="$DISC_DIR/CHARACTERS.txt"
CHARACTER_MATCH=""
if [ -f "$CHARACTERS_FILE" ]; then
    EXTRACTED_CHARS=$(cat "$CHARACTERS_FILE" | grep -v '^#' | tr '\n' ',' | sed 's/,$//')
    log "Trying character-based matching..."
    CHARACTER_MATCH=$(find_best_character_match "$EXTRACTED_CHARS" "$FRANCHISE_FILE")

    if [ -n "$CHARACTER_MATCH" ]; then
        CHAR_MATCHES=$(echo "$CHARACTER_MATCH" | cut -d'|' -f5)
        log "  Character match found: $CHAR_MATCHES characters matched"

        # If we have a strong character match (>= 3 unique characters), use it
        if [ "$CHAR_MATCHES" -ge 3 ]; then
            BEST_MATCH=$(echo "$CHARACTER_MATCH" | cut -d'|' -f1)
            TITLE=$(echo "$CHARACTER_MATCH" | cut -d'|' -f2)
            YEAR=$(echo "$CHARACTER_MATCH" | cut -d'|' -f3)
            DETECTED_TYPE=$(echo "$CHARACTER_MATCH" | cut -d'|' -f4)
            CONFIDENCE="high"
            REASONING="Matched $CHAR_MATCHES character names from dialogue against IMDB cast data"

            log "  Using character match: $TITLE ($YEAR)"

            # Skip LLM matching, go straight to output
            USE_CHARACTER_MATCH=true
        else
            log "  Character match too weak ($CHAR_MATCHES < 3), trying LLM..."
            USE_CHARACTER_MATCH=false
        fi
    else
        log "  No character matches found, trying LLM..."
        USE_CHARACTER_MATCH=false
    fi
else
    USE_CHARACTER_MATCH=false
fi

# Fall back to LLM matching if character match wasn't strong enough
if [ "$USE_CHARACTER_MATCH" != "true" ]; then
    log "Matching summary against franchise list using LLM..."

# Use a hybrid matching prompt
MATCH_PROMPT="Given this story summary and list of potential matches (which includes both movies and TV series), identify the best match.
Determine if this content is more likely a movie or a TV episode based on the narrative structure and length ($LONGEST_DURATION minutes).
${PARSED_SEASON:+Season hint from disc name: Season $PARSED_SEASON}

STORY SUMMARY:
$STORY_SUMMARY

POTENTIAL MATCHES (format: imdb_id|title|year|type|score):
$FRANCHISE_LIST

Return a JSON object:
{
  \"content_type\": \"movie\" or \"tv_episode\" or \"tv_special\",
  \"best_match\": \"imdb_id of best match\",
  \"title\": \"title of best match\",
  \"year\": year,
  \"season\": null or season_number (for TV),
  \"episode\": null or episode_number (for TV),
  \"confidence\": \"high\" or \"medium\" or \"low\",
  \"reasoning\": \"brief explanation\"
}

Return ONLY the JSON object."

MATCH_RESULT=$(call_llm "$MATCH_PROMPT" "You are a content identification expert matching summaries to movies and TV shows." 512 180)

if [ -z "$MATCH_RESULT" ]; then
    log_error "Failed to match content"
    exit 1
fi

# Try to extract JSON from response
# First try single-line extraction, then try multi-line by collapsing newlines
JSON_RESULT=$(echo "$MATCH_RESULT" | grep -oE '\{.*\}' | head -1)
if [ -z "$JSON_RESULT" ] || ! echo "$JSON_RESULT" | jq -e '.' >/dev/null 2>&1; then
    # Try multi-line: collapse newlines and extract JSON
    JSON_RESULT=$(echo "$MATCH_RESULT" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP '\{[^{}]*"best_match"[^{}]*\}' | head -1)
fi

if [ -z "$JSON_RESULT" ] || ! echo "$JSON_RESULT" | jq -e '.' >/dev/null 2>&1; then
    log "Warning: Could not parse LLM response as JSON"
    JSON_RESULT='{"content_type": "unknown", "best_match": null, "title": "Unknown", "confidence": "low", "reasoning": "Failed to parse response"}'
fi

# Parse result
DETECTED_TYPE=$(echo "$JSON_RESULT" | jq -r '.content_type // "unknown"')
BEST_MATCH=$(echo "$JSON_RESULT" | jq -r '.best_match // "unknown"')
TITLE=$(echo "$JSON_RESULT" | jq -r '.title // "Unknown"')
YEAR=$(echo "$JSON_RESULT" | jq -r '.year // ""')
SEASON=$(echo "$JSON_RESULT" | jq -r '.season // ""')
EPISODE=$(echo "$JSON_RESULT" | jq -r '.episode // ""')
CONFIDENCE=$(echo "$JSON_RESULT" | jq -r '.confidence // "low"')
REASONING=$(echo "$JSON_RESULT" | jq -r '.reasoning // ""')

fi  # End of LLM fallback block

# Write BEST_GUESS.txt (common to both character match and LLM match paths)
cat > "$BEST_GUESS_FILE" << EOF
BEST_GUESS - Hybrid (TV/Movie)
==============================
Generated: $(date -Iseconds)

Detected Content Type: $DETECTED_TYPE
Confidence: $CONFIDENCE

Best Match:
  IMDB ID: $BEST_MATCH
  Title: $TITLE
  Year: $YEAR
EOF

# Add episode info if available (from LLM path)
EP_CODE=""
if [ -n "${SEASON:-}" ] && [ "${SEASON:-}" != "null" ] && [ -n "${EPISODE:-}" ] && [ "${EPISODE:-}" != "null" ]; then
    EP_CODE=$(printf "S%02dE%02d" "$SEASON" "$EPISODE")
    cat >> "$BEST_GUESS_FILE" << EOF
  Episode: $EP_CODE
EOF
fi

cat >> "$BEST_GUESS_FILE" << EOF

Reasoning:
  $REASONING

Source File: ${LONGEST_BASE}.mkv
Duration: $LONGEST_DURATION minutes

Story Summary:
$STORY_SUMMARY
EOF

log "Match result:"
log "  Type: $DETECTED_TYPE"
log "  Title: $TITLE ($YEAR)${EP_CODE:+ $EP_CODE}"
log "  IMDB: $BEST_MATCH"
log "  Confidence: $CONFIDENCE"

log "Step 8 completed successfully"
exit 0
