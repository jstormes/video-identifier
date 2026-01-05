#!/bin/bash
#
# IMDB database query functions for video-identifier pipeline
#
# Environment variables:
#   IMDB_HOST       - MariaDB host (default: nas2)
#   IMDB_USER       - Database user (default: imdb)
#   IMDB_PASSWORD   - Database password (required)
#   IMDB_DATABASE   - Database name (default: imdb)
#

# Default configuration
# Accept both IMDB_* and MYSQL_* env vars for flexibility
IMDB_HOST="${IMDB_HOST:-${MYSQL_HOST:-nas2}}"
IMDB_USER="${IMDB_USER:-${MYSQL_USER:-imdb}}"
IMDB_PASSWORD="${IMDB_PASSWORD:-${MYSQL_PASSWORD:-}}"
IMDB_DATABASE="${IMDB_DATABASE:-${MYSQL_DATABASE:-imdb}}"

# Execute MySQL query and return results
# Usage: mysql_query "SQL query"
mysql_query() {
    mysql -h "$IMDB_HOST" -u "$IMDB_USER" -p"$IMDB_PASSWORD" "$IMDB_DATABASE" -N -e "$1" 2>/dev/null
}

# Test database connection
# Returns 0 if successful, 1 otherwise
test_imdb_connection() {
    if [ -z "$IMDB_PASSWORD" ]; then
        log_error "IMDB_PASSWORD environment variable not set"
        return 1
    fi

    if ! mysql_query "SELECT 1" >/dev/null 2>&1; then
        log_error "Cannot connect to IMDB database at $IMDB_HOST"
        return 1
    fi

    return 0
}

# Escape string for MySQL LIKE queries
# Usage: escape_like "string"
escape_like() {
    echo "$1" | sed "s/'/\\\\'/g" | sed 's/%/\\%/g' | sed 's/_/\\_/g'
}

# Format comma-separated list for SQL IN clause
# Usage: format_sql_list "item1,item2,item3"
# Returns: 'item1','item2','item3'
format_sql_list() {
    local items="$1"
    echo "$items" | tr ',' '\n' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//" | \
        grep -v '^$' | sed "s/'/\\\\'/g" | sed "s/.*/'&'/" | tr '\n' ',' | sed 's/,$//'
}

# Build character match scoring SQL
# Usage: build_character_score_sql "char1,char2,char3"
# Returns: "SQL expression|count"
build_character_score_sql() {
    local characters="$1"
    local sql=""
    local count=0

    # Split characters by comma and build CASE statements
    IFS=',' read -ra CHAR_ARRAY <<< "$characters"
    for char in "${CHAR_ARRAY[@]}"; do
        # Trim whitespace
        char=$(echo "$char" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$char" ] && [ ${#char} -gt 2 ]; then
            local char_escaped
            char_escaped=$(escape_like "$char")
            if [ -n "$sql" ]; then
                sql="$sql +"
            fi
            sql="$sql CASE WHEN MAX(tp.characters LIKE '%${char_escaped}%') THEN 1 ELSE 0 END"
            count=$((count + 1))
        fi
    done

    echo "${sql:-0}|${count:-1}"
}

# Search IMDB for TV series by characters and title
# Usage: search_imdb_tv "characters" "title_hint" "episode_length_minutes"
# Returns: tconst|title|year|score (one per line)
search_imdb_tv() {
    local characters="$1"
    local title_hint="$2"
    local episode_length="$3"

    local title_escaped
    title_escaped=$(escape_like "$title_hint")

    # Build character scoring
    local char_sql_result
    char_sql_result=$(build_character_score_sql "$characters")
    local char_score_sql
    char_score_sql=$(echo "$char_sql_result" | cut -d'|' -f1)
    local char_count
    char_count=$(echo "$char_sql_result" | cut -d'|' -f2)

    if [ -z "$char_score_sql" ] || [ "$char_count" -eq 0 ]; then
        char_score_sql="0"
        char_count=1
    fi

    # Runtime matching: +/-2 minutes for TV
    local runtime_min=$((episode_length - 2))
    local runtime_max=$((episode_length + 2))

    # Search by title with character scoring
    local query="
        SELECT
            tb.tconst,
            tb.primaryTitle,
            tb.startYear,
            'tvSeries' as titleType,
            ($char_score_sql) as character_matches
        FROM title_basics tb
        LEFT JOIN title_principals tp ON tb.tconst = tp.tconst
        WHERE tb.titleType IN ('tvSeries', 'tvMiniSeries')
            AND (tb.primaryTitle LIKE '%${title_escaped}%'
                 OR MATCH(tb.primaryTitle) AGAINST('${title_escaped}' IN BOOLEAN MODE))
        GROUP BY tb.tconst, tb.primaryTitle, tb.startYear
        HAVING character_matches > 0
        ORDER BY character_matches DESC, tb.startYear DESC
        LIMIT 10
    "

    mysql_query "$query" | while IFS=$'\t' read -r tconst title year type char_matches; do
        local score=$((char_matches * 10))
        echo "${tconst}|${title}|${year}|${type}|${score}"
    done
}

# Search IMDB for movies by characters, actors, title, and runtime
# Usage: search_imdb_movie "characters" "actors" "title_hint" "runtime_minutes"
# Returns: tconst|title|year|score (one per line)
search_imdb_movie() {
    local characters="$1"
    local actors="$2"
    local title_hint="$3"
    local runtime="$4"

    local title_escaped
    title_escaped=$(escape_like "$title_hint")

    # Build character scoring
    local char_sql_result
    char_sql_result=$(build_character_score_sql "$characters")
    local char_score_sql
    char_score_sql=$(echo "$char_sql_result" | cut -d'|' -f1)

    if [ -z "$char_score_sql" ]; then
        char_score_sql="0"
    fi

    # Runtime matching: +/-3 minutes for movies
    local runtime_min=$((runtime - 3))
    local runtime_max=$((runtime + 3))

    # Format actor list for IN clause if provided
    local actor_condition=""
    if [ -n "$actors" ]; then
        local actor_list
        actor_list=$(format_sql_list "$actors")
        if [ -n "$actor_list" ]; then
            actor_condition="OR nb.primaryName IN ($actor_list)"
        fi
    fi

    local query="
        SELECT
            tb.tconst,
            tb.primaryTitle,
            tb.startYear,
            tb.runtimeMinutes,
            'movie' as titleType,
            ($char_score_sql) as character_matches,
            COUNT(DISTINCT CASE WHEN nb.primaryName IS NOT NULL THEN nb.nconst END) as actor_matches
        FROM title_basics tb
        LEFT JOIN title_principals tp ON tb.tconst = tp.tconst
        LEFT JOIN name_basics nb ON tp.nconst = nb.nconst
        WHERE tb.titleType IN ('movie', 'tvMovie', 'video')
            AND (tb.runtimeMinutes BETWEEN $runtime_min AND $runtime_max
                 OR tb.runtimeMinutes IS NULL)
            AND (tb.primaryTitle LIKE '%${title_escaped}%'
                 $actor_condition)
        GROUP BY tb.tconst, tb.primaryTitle, tb.startYear, tb.runtimeMinutes
        ORDER BY character_matches DESC, actor_matches DESC, tb.startYear DESC
        LIMIT 10
    "

    mysql_query "$query" | while IFS=$'\t' read -r tconst title year runtime type char_matches actor_matches; do
        local score=$((char_matches * 10 + actor_matches * 5))
        echo "${tconst}|${title}|${year}|${type}|${score}"
    done
}

# Search IMDB by proper nouns matching character names
# Usage: search_imdb_by_proper_nouns "proper_nouns" "title_type"
# Returns: tconst|title|year|type|score (one per line)
search_imdb_by_proper_nouns() {
    local proper_nouns="$1"
    local title_type="${2:-both}"  # movie, tv, or both

    # Build type filter
    local type_filter=""
    if [ "$title_type" = "movie" ]; then
        type_filter="AND tb.titleType IN ('movie', 'tvMovie', 'video')"
    elif [ "$title_type" = "tv" ]; then
        type_filter="AND tb.titleType IN ('tvSeries', 'tvMiniSeries')"
    else
        type_filter="AND tb.titleType IN ('movie', 'tvMovie', 'video', 'tvSeries', 'tvMiniSeries')"
    fi

    # Build character scoring from proper nouns
    local char_sql_result
    char_sql_result=$(build_character_score_sql "$proper_nouns")
    local char_score_sql
    char_score_sql=$(echo "$char_sql_result" | cut -d'|' -f1)

    if [ -z "$char_score_sql" ]; then
        return
    fi

    local query="
        SELECT
            tb.tconst,
            tb.primaryTitle,
            tb.startYear,
            tb.titleType,
            ($char_score_sql) as character_matches
        FROM title_basics tb
        LEFT JOIN title_principals tp ON tb.tconst = tp.tconst
        WHERE 1=1
            $type_filter
        GROUP BY tb.tconst, tb.primaryTitle, tb.startYear, tb.titleType
        HAVING character_matches >= 3
        ORDER BY character_matches DESC
        LIMIT 20
    "

    mysql_query "$query" | while IFS=$'\t' read -r tconst title year type char_matches; do
        local score=$((char_matches * 10))
        echo "${tconst}|${title}|${year}|${type}|${score}"
    done
}

# Get episode list for a TV series
# Usage: get_imdb_episodes "series_tconst" ["season_number"]
# Returns: season|episode|title (one per line)
get_imdb_episodes() {
    local series_tconst="$1"
    local season="${2:-}"

    local season_filter=""
    if [ -n "$season" ]; then
        season_filter="AND te.seasonNumber = $season"
    fi

    local query="
        SELECT
            te.seasonNumber,
            te.episodeNumber,
            tb.primaryTitle
        FROM title_episode te
        JOIN title_basics tb ON te.tconst = tb.tconst
        WHERE te.parentTconst = '$series_tconst'
            $season_filter
        ORDER BY te.seasonNumber, te.episodeNumber
    "

    mysql_query "$query" | while IFS=$'\t' read -r season ep title; do
        echo "${season}|${ep}|${title}"
    done
}

# Search for titles by name and runtime
# Usage: search_by_title_and_runtime "title" "runtime_minutes" "tolerance" "type"
# Returns: tconst|title|year|type|score (one per line) - consistent with other search functions
search_by_title_and_runtime() {
    local title="$1"
    local runtime="$2"
    local tolerance="${3:-3}"
    local title_type="${4:-both}"

    local title_escaped
    title_escaped=$(escape_like "$title")

    local runtime_min=$((runtime - tolerance))
    local runtime_max=$((runtime + tolerance))

    # Build type filter
    local type_filter=""
    if [ "$title_type" = "movie" ]; then
        type_filter="AND tb.titleType IN ('movie', 'tvMovie', 'video')"
    elif [ "$title_type" = "tv" ]; then
        type_filter="AND tb.titleType IN ('tvSeries', 'tvMiniSeries')"
    else
        type_filter="AND tb.titleType IN ('movie', 'tvMovie', 'video', 'tvSeries', 'tvMiniSeries')"
    fi

    local query="
        SELECT
            tb.tconst,
            tb.primaryTitle,
            tb.startYear,
            tb.runtimeMinutes,
            tb.titleType
        FROM title_basics tb
        WHERE (tb.primaryTitle LIKE '%${title_escaped}%'
               OR MATCH(tb.primaryTitle) AGAINST('${title_escaped}' IN BOOLEAN MODE))
            AND (tb.runtimeMinutes BETWEEN $runtime_min AND $runtime_max
                 OR tb.runtimeMinutes IS NULL)
            $type_filter
        ORDER BY
            CASE WHEN tb.runtimeMinutes = $runtime THEN 0
                 WHEN tb.runtimeMinutes IS NOT NULL THEN ABS(tb.runtimeMinutes - $runtime)
                 ELSE 999 END,
            CASE WHEN tb.primaryTitle = '${title_escaped}' THEN 0 ELSE 1 END,
            tb.startYear DESC
        LIMIT 20
    "

    mysql_query "$query" | while IFS=$'\t' read -r tconst res_title year res_runtime type; do
        # Calculate score: base 100 for title match, +50 for exact runtime match, +20 for close runtime
        local score=100
        if [ -n "$res_runtime" ] && [ "$res_runtime" != "NULL" ]; then
            local runtime_diff=$((res_runtime - runtime))
            runtime_diff=${runtime_diff#-}  # absolute value
            if [ "$runtime_diff" -eq 0 ]; then
                score=$((score + 50))  # Exact runtime match
            elif [ "$runtime_diff" -le 3 ]; then
                score=$((score + 20))  # Close runtime match
            fi
        fi
        # Bonus for exact title match
        if [ "$res_title" = "$title" ]; then
            score=$((score + 30))
        fi
        echo "${tconst}|${res_title}|${year}|${type}|${score}"
    done
}

# Get title details by tconst
# Usage: get_title_details "tconst"
# Returns: tconst|title|year|runtime|type|genres
get_title_details() {
    local tconst="$1"

    local query="
        SELECT
            tb.tconst,
            tb.primaryTitle,
            tb.startYear,
            tb.runtimeMinutes,
            tb.titleType,
            tb.genres
        FROM title_basics tb
        WHERE tb.tconst = '$tconst'
    "

    mysql_query "$query" | head -1
}

# Get characters for a title
# Usage: get_title_characters "tconst"
# Returns: comma-separated list of character names
get_title_characters() {
    local tconst="$1"

    local query="
        SELECT characters
        FROM title_principals
        WHERE tconst = '$tconst'
            AND characters IS NOT NULL
            AND characters != ''
    "

    # Extract character names from JSON arrays like ["Character Name"]
    mysql_query "$query" | sed 's/\["\|"\]//g' | tr '\n' ',' | sed 's/,$//'
}

# Count character matches between extracted characters and IMDB characters
# Usage: count_character_matches "extracted_chars" "tconst"
# Returns: number of matches
count_character_matches() {
    local extracted_chars="$1"
    local tconst="$2"

    local imdb_chars
    imdb_chars=$(get_title_characters "$tconst")

    [ -z "$imdb_chars" ] && echo "0" && return

    local matches=0
    local extracted_lower
    local imdb_lower

    # Convert to lowercase for comparison
    extracted_lower=$(echo "$extracted_chars" | tr '[:upper:]' '[:lower:]')
    imdb_lower=$(echo "$imdb_chars" | tr '[:upper:]' '[:lower:]')

    # Check each extracted character
    for char in $(echo "$extracted_chars" | tr ',' '\n'); do
        [ -z "$char" ] && continue
        char_lower=$(echo "$char" | tr '[:upper:]' '[:lower:]')

        # Check if this character appears in IMDB characters (partial match)
        if echo "$imdb_lower" | grep -qi "$char_lower"; then
            matches=$((matches + 1))
        fi
    done

    echo "$matches"
}

# Find best match from franchise list using character matching
# Usage: find_best_character_match "extracted_chars" "franchise_file"
# Returns: tconst|title|year|type|character_matches
find_best_character_match() {
    local extracted_chars="$1"
    local franchise_file="$2"

    local best_tconst=""
    local best_title=""
    local best_year=""
    local best_type=""
    local best_matches=0

    while IFS='|' read -r tconst title year type score; do
        [ -z "$tconst" ] && continue

        matches=$(count_character_matches "$extracted_chars" "$tconst")

        if [ "$matches" -gt "$best_matches" ]; then
            best_matches=$matches
            best_tconst=$tconst
            best_title=$title
            best_year=$year
            best_type=$type
        fi
    done < "$franchise_file"

    if [ "$best_matches" -gt 0 ]; then
        echo "${best_tconst}|${best_title}|${best_year}|${best_type}|${best_matches}"
    fi
}
