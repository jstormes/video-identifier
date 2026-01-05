#!/bin/bash
#
# LLM API wrapper functions for video-identifier pipeline
#
# Environment variables:
#   LLM_BASE_URL - LLM server URL (default: http://nas2:8191/v1)
#   LLM_MODEL    - Model name (default: qwen3-30b)
#

# Default configuration
LLM_BASE_URL="${LLM_BASE_URL:-http://nas2:8191/v1}"
LLM_MODEL="${LLM_MODEL:-qwen3-30b}"
LLM_URL="${LLM_BASE_URL}/chat/completions"

# Retry configuration
LLM_MAX_RETRIES=3
LLM_RETRY_DELAY=5
LLM_CONNECT_TIMEOUT=10
LLM_DEFAULT_TIMEOUT=1200  # 20 minutes default

# Call LLM with prompt and optional system prompt
# Usage: call_llm "prompt" ["system_prompt"] [max_tokens] [timeout]
# Returns: LLM response content or empty on error
call_llm() {
    local prompt="$1"
    local system_prompt="${2:-You are a helpful assistant.}"
    local max_tokens="${3:-4096}"
    local timeout="${4:-$LLM_DEFAULT_TIMEOUT}"

    # Check prerequisites
    if ! command -v jq &> /dev/null; then
        log_error "jq not available, cannot call LLM"
        return 1
    fi

    if ! command -v curl &> /dev/null; then
        log_error "curl not available, cannot call LLM"
        return 1
    fi

    # Escape prompt for JSON using jq
    local escaped_prompt
    local escaped_system
    escaped_prompt=$(echo "$prompt" | jq -Rs .)
    escaped_system=$(echo "$system_prompt" | jq -Rs .)

    # Build JSON payload
    local payload
    payload=$(cat <<EOF
{
    "model": "$LLM_MODEL",
    "messages": [
        {
            "role": "system",
            "content": $escaped_system
        },
        {
            "role": "user",
            "content": $escaped_prompt
        }
    ],
    "max_tokens": $max_tokens,
    "temperature": 0.3
}
EOF
)

    # Call LLM with retry logic
    local response=""
    local curl_exit_code=0
    local content=""

    for attempt in $(seq 1 $LLM_MAX_RETRIES); do
        log_debug "Calling LLM (attempt $attempt/$LLM_MAX_RETRIES, timeout: ${timeout}s)..."

        response=$(curl -s -X POST "$LLM_URL" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            --connect-timeout "$LLM_CONNECT_TIMEOUT" \
            --max-time "$timeout" 2>&1)
        curl_exit_code=$?

        if [ $curl_exit_code -ne 0 ]; then
            log_debug "curl failed with exit code $curl_exit_code"
            case $curl_exit_code in
                6)  log_debug "Could not resolve host" ;;
                7)  log_debug "Failed to connect to host" ;;
                28) log_debug "Operation timed out" ;;
                *)  log_debug "Error details: $response" ;;
            esac
        elif [ -n "$response" ]; then
            # Check if response contains valid content
            content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
            if [ -n "$content" ] && [ "$content" != "null" ]; then
                # Remove thinking tags if present (some models wrap responses)
                content=$(echo "$content" | sed 's/<think>.*<\/think>//g' | sed 's/<thinking>.*<\/thinking>//g')
                echo "$content"
                return 0
            else
                # Check for error in response
                local error_msg
                error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
                if [ -n "$error_msg" ]; then
                    log_debug "LLM error: $error_msg"
                else
                    log_debug "Empty or invalid response from LLM"
                fi
            fi
        else
            log_debug "Empty response from curl"
        fi

        if [ "$attempt" -lt "$LLM_MAX_RETRIES" ]; then
            log_debug "Retrying in ${LLM_RETRY_DELAY}s..."
            sleep $LLM_RETRY_DELAY
        fi
    done

    log_error "LLM call failed after $LLM_MAX_RETRIES attempts"
    return 1
}

# Extract character names from dialogue using LLM
# Usage: extract_characters_llm "dialogue_text"
# Returns: JSON array of character names
extract_characters_llm() {
    local dialogue_text="$1"

    # Truncate to first 1000 lines for reasonable processing
    # (3000 lines causes timeouts - 500 lines takes ~95s, so 1000 is ~3 min)
    local truncated
    truncated=$(echo "$dialogue_text" | head -n 1000)

    local prompt="Extract all character names from this dialogue transcript.
Return ONLY a valid JSON array of character names, nothing else.
Only include actual character names (people, not places or objects).
Example format: [\"John\", \"Mary\", \"Detective Smith\"]

DIALOGUE:
$truncated"

    local response
    response=$(call_llm "$prompt" "You are a character extraction assistant. Extract character names from dialogue and return them as a JSON array." 1024 600)

    if [ -n "$response" ]; then
        # Try to extract JSON array from response
        local json_array
        json_array=$(echo "$response" | grep -oE '\[.*\]' | head -1)
        if [ -n "$json_array" ] && echo "$json_array" | jq -e '.' >/dev/null 2>&1; then
            echo "$json_array"
            return 0
        fi
    fi

    echo "[]"
    return 1
}

# Extract all proper nouns from dialogue using LLM
# Usage: extract_proper_nouns_llm "dialogue_text"
# Returns: One proper noun per line
extract_proper_nouns_llm() {
    local dialogue_text="$1"

    # Truncate to first 1000 lines (3000 causes timeouts)
    local truncated
    truncated=$(echo "$dialogue_text" | head -n 1000)

    local prompt="Extract ALL proper nouns from this dialogue transcript.
Include: character names, place names, organization names, brand names, titles, etc.
Return one proper noun per line, nothing else.
Do not include common words or pronouns.

DIALOGUE:
$truncated"

    local response
    response=$(call_llm "$prompt" "You extract proper nouns from text. Return one per line." 2048 600)

    if [ -n "$response" ]; then
        # Clean up response - remove empty lines and duplicates
        echo "$response" | grep -v '^$' | sort -u
        return 0
    fi

    return 1
}

# Generate a story summary from dialogue
# Usage: generate_story_summary "dialogue_text" ["movie"|"episode"]
# Returns: Story summary text
generate_story_summary() {
    local dialogue_text="$1"
    local content_type="${2:-movie}"

    # Truncate to 6000 lines as specified
    local truncated
    truncated=$(echo "$dialogue_text" | head -n 6000)

    local prompt
    local system_prompt

    if [ "$content_type" = "movie" ]; then
        system_prompt="You are a film analyst. Write comprehensive movie summaries."
        prompt="Write a detailed story summary of this movie based on the dialogue.
Include:
- Main plot points and story arc
- Character arcs and relationships
- Key scenes and turning points
- Resolution and ending
- Themes explored

Keep the summary under 6000 characters.

DIALOGUE:
$truncated"
    else
        system_prompt="You are a TV episode analyst. Write comprehensive episode summaries."
        prompt="Write a detailed story summary of this TV episode based on the dialogue.
Include:
- Episode plot and story arc
- Character actions and decisions
- Key scenes and conflicts
- Resolution (if any)

Keep the summary under 6000 characters.

DIALOGUE:
$truncated"
    fi

    call_llm "$prompt" "$system_prompt" 4096 600
}

# Match a story summary against a franchise list
# Usage: match_story_to_franchise "summary" "franchise_list"
# Returns: JSON with best_match, title, confidence, reasoning
match_story_to_franchise() {
    local summary="$1"
    local franchise_list="$2"

    local prompt="Given this story summary and list of potential matches, identify the best match.

STORY SUMMARY:
$summary

POTENTIAL MATCHES (format: imdb_id|title|year|type):
$franchise_list

Return a JSON object with these fields:
{
  \"best_match\": \"imdb_id of best match\",
  \"title\": \"title of best match\",
  \"year\": year,
  \"confidence\": \"high\" or \"medium\" or \"low\",
  \"reasoning\": \"brief explanation of why this is the best match\"
}

Return ONLY the JSON object, no other text."

    local response
    response=$(call_llm "$prompt" "You are an IMDB matching expert. Match story summaries to movie/TV entries." 512 180)

    if [ -n "$response" ]; then
        # Extract JSON from response (try single-line first, then multi-line)
        local json
        json=$(echo "$response" | grep -oE '\{.*\}' | head -1)
        if [ -z "$json" ] || ! echo "$json" | jq -e '.' >/dev/null 2>&1; then
            # Try multi-line: collapse newlines and extract JSON
            json=$(echo "$response" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP '\{[^{}]*"best_match"[^{}]*\}' | head -1)
        fi
        if [ -n "$json" ] && echo "$json" | jq -e '.' >/dev/null 2>&1; then
            echo "$json"
            return 0
        fi
    fi

    echo '{"best_match": null, "title": null, "confidence": "low", "reasoning": "No match found"}'
    return 1
}

# Match an episode summary to an episode list
# Usage: match_episode_to_list "summary" "episode_list" ["season_hint"] ["disc_num"] ["file_pos"] ["total_files"] ["previous_matches"]
# Returns: JSON with season, episode, episode_title, confidence
match_episode_to_list() {
    local summary="$1"
    local episode_list="$2"
    local season_hint="${3:-}"
    local disc_num="${4:-}"
    local file_pos="${5:-}"
    local total_files="${6:-}"
    local previous_matches="${7:-}"

    local context_hints=""

    if [ -n "$season_hint" ]; then
        context_hints="${context_hints}Season hint from disc name: Season $season_hint
"
    fi

    if [ -n "$disc_num" ]; then
        context_hints="${context_hints}Disc number: $disc_num (earlier discs have earlier episodes)
"
    fi

    if [ -n "$file_pos" ] && [ -n "$total_files" ]; then
        context_hints="${context_hints}File position: This is file $file_pos of $total_files on this disc (episodes are typically in sequential order on a disc)
"
    fi

    if [ -n "$previous_matches" ]; then
        context_hints="${context_hints}Previously matched episodes on this disc (in file order):
$previous_matches
The next episode should logically follow the sequence.
"
    fi

    local prompt="Match this TV episode summary to an episode from the list.

CONTEXT HINTS:
$context_hints
IMPORTANT: Use the context hints above to help narrow down which episode this is. Episodes on a disc are typically sequential (e.g., if previous file was E01, this file is likely E02). Multi-part episodes (Part 1, Part 2) appear on consecutive files.

EPISODE SUMMARY:
$summary

EPISODE LIST (format: season|episode|title):
$episode_list

Return a JSON object:
{
  \"season\": season_number,
  \"episode\": episode_number,
  \"episode_title\": \"episode title\",
  \"confidence\": \"high\" or \"medium\" or \"low\"
}

Return ONLY the JSON object."

    local response
    response=$(call_llm "$prompt" "You are an episode matching expert. Match summaries to specific episodes. Pay attention to context hints about disc number and file order." 256 180)

    if [ -n "$response" ]; then
        local json
        json=$(echo "$response" | grep -oE '\{.*\}' | head -1)
        if [ -z "$json" ] || ! echo "$json" | jq -e '.' >/dev/null 2>&1; then
            # Try multi-line: collapse newlines and extract JSON
            json=$(echo "$response" | tr '\n' ' ' | sed 's/  */ /g' | grep -oP '\{[^{}]*"season"[^{}]*\}' | head -1)
        fi
        if [ -n "$json" ] && echo "$json" | jq -e '.' >/dev/null 2>&1; then
            echo "$json"
            return 0
        fi
    fi

    echo '{"season": null, "episode": null, "episode_title": null, "confidence": "low"}'
    return 1
}
