#!/bin/bash
#
# Step 1: Extract SRT from video files
#
# At least one file MUST successfully extract a non-zero byte SRT file.
# If no SRT can be extracted, writes "No srt found" to UNKNOWN.txt and exits with error.
#
# Usage: step1-extract-srt.sh <disc_directory>
#

set -e

SCRIPT_DIR="$(dirname "$0")"
source "$SCRIPT_DIR/lib/common.sh"

DISC_DIR="$1"

if [ -z "$DISC_DIR" ] || [ ! -d "$DISC_DIR" ]; then
    log_error "Usage: $0 <disc_directory>"
    exit 1
fi

log "Step 1: Extract SRT from video files"
log "Directory: $DISC_DIR"

# Create temp directory for extraction work
TEMP_DIR="${DISC_DIR}/temp_extract_$$"
mkdir -p "$TEMP_DIR"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Language mapping function (for Tesseract)
map_language() {
    local lang="$1"
    case "$lang" in
        eng|en) echo "eng" ;;
        spa|es) echo "spa" ;;
        fra|fr) echo "fra" ;;
        deu|de) echo "deu" ;;
        ita|it) echo "ita" ;;
        por|pt) echo "por" ;;
        *) echo "eng" ;;
    esac
}

# Language detection functions - count common words in each language
detect_lang_score() {
    local file="$1"
    local lang="$2"
    local words=""

    case "$lang" in
        eng)
            words='the|you|and|to|is|it|that|of|in|for|have|this|what|with|are|not|but|was|they|we|he|she|my|your|can|just|get|know|like|want|think|will|would|there|about|been|were|from|more|him|his|our|than|only|back|well|because'
            ;;
        spa)
            words='que|de|no|es|la|el|en|lo|un|por|se|con|para|una|los|del|las|al|como|pero|le|ya|o|si|su|todo|esta|cuando|muy|sin|sobre|ser|tiene|hay|puede|esto|solo|yo|tu|me|te|nos'
            ;;
        fra)
            words='que|de|ne|pas|le|la|les|un|une|est|et|en|ce|il|je|vous|tu|nous|qui|dans|pour|sur|avec|plus|tout|sont|mais|elle|ont|fait|bien|peut|comme|sans|cette|aux|lui|mes|votre|notre'
            ;;
        deu)
            words='der|die|das|und|ist|in|du|ich|nicht|ein|es|mit|sie|auf|den|zu|haben|werden|wir|von|er|wird|bei|sind|aus|auch|als|nach|wie|nur|wenn|aber|noch|oder|diese|kann|vor|schon|mehr'
            ;;
        por)
            words='que|de|nao|para|um|uma|com|em|os|as|por|se|como|eu|ele|ela|nos|voce|sua|seu|tem|mas|isso|foi|esta|muito|bem|pode|mais|quando|tudo|fazer|aqui|esse|essa|meu|minha|ter|ser'
            ;;
        ita)
            words='che|di|non|la|il|un|una|per|con|sono|come|ma|cosa|questo|quello|lei|lui|noi|loro|qui|essere|fare|bene|tutto|molto|anche|ora|quando|solo|perche|dove|chi|quale|ogni|sempre|ancora|proprio|tanto|mai'
            ;;
    esac

    head -200 "$file" 2>/dev/null | tr '[:upper:]' '[:lower:]' | \
        grep -oE "\b($words)\b" | wc -l
}

# Detect the most likely language of an SRT file
detect_language() {
    local file="$1"
    local best_lang="und"
    local best_score=0

    for lang in eng spa fra deu por ita; do
        local score
        score=$(detect_lang_score "$file" "$lang")
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            best_lang=$lang
        fi
    done

    # Require minimum score of 15 to make a guess
    if [ "$best_score" -ge 15 ]; then
        echo "$best_lang"
    else
        echo "und"
    fi
}

# Process VOBSUB track
process_vobsub() {
    local mkv_file="$1"
    local track_id="$2"
    local lang="$3"
    local basename="$4"

    local tess_lang
    tess_lang=$(map_language "$lang")

    log "  [VOBSUB] Extracting track $track_id..."

    local sub_base="$TEMP_DIR/track_${track_id}"
    mkvextract tracks "$mkv_file" "${track_id}:${sub_base}" >/dev/null 2>&1 || true

    if [ ! -f "${sub_base}.idx" ] || [ ! -f "${sub_base}.sub" ]; then
        log "  Could not extract VOBSUB track $track_id"
        return 1
    fi

    log "  Running OCR with vobsub2srt (lang: $tess_lang)..."
    if vobsub2srt --tesseract-lang "$tess_lang" "$sub_base" 2>/dev/null; then
        if [ -f "${sub_base}.srt" ] && [ -s "${sub_base}.srt" ]; then
            local output_file="${DISC_DIR}/${basename}.${lang}.srt"
            mv "${sub_base}.srt" "$output_file"
            local lines
            lines=$(wc -l < "$output_file")
            log "  Created: $output_file ($lines lines)"
            return 0
        fi
    fi

    log "  vobsub2srt failed for track $track_id"
    rm -f "${sub_base}.idx" "${sub_base}.sub" 2>/dev/null
    return 1
}

# Process PGS tracks using pgsrip
process_pgs_tracks() {
    local mkv_file="$1"

    log "  [PGS] Processing with pgsrip..."

    if pgsrip "$mkv_file" --force 2>/dev/null; then
        return 0
    else
        log "  pgsrip failed or no PGS tracks"
        return 1
    fi
}

# Process text subtitle track (SRT, ASS, SSA - no OCR needed)
process_text_subtitle() {
    local mkv_file="$1"
    local track_id="$2"
    local lang="$3"
    local codec="$4"
    local basename="$5"

    log "  [TEXT] Extracting track $track_id ($codec)..."

    # Determine output extension based on codec
    local ext="srt"
    if echo "$codec" | grep -qi "ass\|ssa"; then
        ext="ass"
    fi

    local output_file="${DISC_DIR}/${basename}.${lang}.${ext}"

    # Extract directly with mkvextract
    if mkvextract tracks "$mkv_file" "${track_id}:${output_file}" >/dev/null 2>&1; then
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            local lines
            lines=$(wc -l < "$output_file")
            log "  Created: $output_file ($lines lines)"

            # Convert ASS/SSA to SRT if needed for consistency
            if [ "$ext" = "ass" ]; then
                local srt_output="${DISC_DIR}/${basename}.${lang}.srt"
                if command -v ffmpeg >/dev/null 2>&1; then
                    if ffmpeg -i "$output_file" -c:s srt "$srt_output" -y >/dev/null 2>&1; then
                        log "  Also created: $srt_output"
                    fi
                fi
            fi
            return 0
        fi
    fi

    log "  Failed to extract track $track_id"
    return 1
}

# Process a single MKV file
process_mkv() {
    local mkv_file="$1"
    local basename
    basename=$(basename "$mkv_file" .mkv)

    log "Processing: $basename"

    # Get subtitle track info
    local subtitle_info
    subtitle_info=$(mkvmerge -i "$mkv_file" 2>/dev/null | grep -i "subtitles" || true)

    if [ -z "$subtitle_info" ]; then
        log "  No subtitle tracks found"
        return 1
    fi

    local success_count=0

    # Check what types of subtitles we have
    local has_vobsub="no"
    local has_pgs="no"
    local has_text="no"

    echo "$subtitle_info" | grep -qi "vobsub" && has_vobsub="yes"
    echo "$subtitle_info" | grep -qi "pgs\|hdmv" && has_pgs="yes"
    echo "$subtitle_info" | grep -qiE "subrip|srt|ass|ssa|text" && has_text="yes"

    # Process VOBSUB tracks
    if [ "$has_vobsub" = "yes" ]; then
        while IFS= read -r line; do
            echo "$line" | grep -qi "vobsub" || continue

            local track_id
            track_id=$(echo "$line" | sed -n 's/.*Track ID \([0-9]*\).*/\1/p')
            [ -z "$track_id" ] && continue

            local lang
            lang=$(echo "$line" | sed -n 's/.*language:\([a-z]*\).*/\1/p')
            [ -z "$lang" ] || [ "$lang" = "und" ] && lang="track${track_id}"

            if process_vobsub "$mkv_file" "$track_id" "$lang" "$basename"; then
                success_count=$((success_count + 1))
            fi
        done <<< "$subtitle_info"
    fi

    # Process PGS tracks
    if [ "$has_pgs" = "yes" ]; then
        if process_pgs_tracks "$mkv_file"; then
            # Count any new SRT files created by pgsrip
            for srt in "${DISC_DIR}/${basename}"*.srt; do
                [ -f "$srt" ] && [ -s "$srt" ] && success_count=$((success_count + 1))
            done
        fi
    fi

    # Process text subtitle tracks
    if [ "$has_text" = "yes" ]; then
        while IFS= read -r line; do
            echo "$line" | grep -qiE "subrip|srt|ass|ssa|text" || continue

            local track_id
            track_id=$(echo "$line" | sed -n 's/.*Track ID \([0-9]*\).*/\1/p')
            [ -z "$track_id" ] && continue

            local lang
            lang=$(echo "$line" | sed -n 's/.*language:\([a-z]*\).*/\1/p')
            [ -z "$lang" ] || [ "$lang" = "und" ] && lang="track${track_id}"

            local codec
            codec=$(echo "$line" | grep -oiE 'subrip|srt|ass|ssa|text' | head -1)

            if process_text_subtitle "$mkv_file" "$track_id" "$lang" "$codec" "$basename"; then
                success_count=$((success_count + 1))
            fi
        done <<< "$subtitle_info"
    fi

    # Auto-detect language for track-numbered files
    for srt in "${DISC_DIR}/${basename}".track*.srt; do
        [ -f "$srt" ] || continue

        local detected_lang
        detected_lang=$(detect_language "$srt")
        if [ "$detected_lang" != "und" ]; then
            local new_name="${DISC_DIR}/${basename}.${detected_lang}.srt"
            if [ ! -f "$new_name" ]; then
                mv "$srt" "$new_name"
                log "  Renamed: $(basename "$srt") -> $(basename "$new_name")"
            fi
        fi
    done

    [ "$success_count" -gt 0 ]
}

# Main processing loop
TOTAL_MKV=0
SUCCESS_MKV=0
TOTAL_SRT=0

for mkv in "$DISC_DIR"/*.mkv; do
    [ -f "$mkv" ] || continue
    TOTAL_MKV=$((TOTAL_MKV + 1))

    if process_mkv "$mkv"; then
        SUCCESS_MKV=$((SUCCESS_MKV + 1))
    fi
done

# Count total SRT files with non-zero size
for srt in "$DISC_DIR"/*.srt; do
    [ -f "$srt" ] && [ -s "$srt" ] && TOTAL_SRT=$((TOTAL_SRT + 1))
done

log "Results: $SUCCESS_MKV/$TOTAL_MKV MKV files processed, $TOTAL_SRT SRT files created"

# MUST have at least one successful SRT extraction
if [ "$TOTAL_SRT" -eq 0 ]; then
    log_error "No SRT files extracted from any video file"
    echo "No srt found" > "$DISC_DIR/UNKNOWN.txt"
    exit 1
fi

log "Step 1 completed successfully"
exit 0
