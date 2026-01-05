# Video Identifier Pipeline
# 8-step pipeline for identifying DVD/video content via subtitle extraction,
# LLM analysis, and IMDB lookup
#
# Tools:
#   - vobsub2srt: OCR for DVD VOBSUB subtitles (built from source)
#   - pgsrip: OCR for Blu-ray PGS subtitles
#   - mariadb-client: IMDB database queries

FROM ubuntu:22.04 AS builder

# Build vobsub2srt from source
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    pkg-config \
    git \
    ca-certificates \
    libtiff5-dev \
    libtesseract-dev \
    && rm -rf /var/lib/apt/lists/*

# Clone and build vobsub2srt (using fork with better Tesseract 5 support)
RUN git clone https://github.com/leonard-slass/VobSub2SRT.git /src/vobsub2srt \
    && cd /src/vobsub2srt \
    && ./configure \
    && make

# Runtime image
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # MKV tools
    mkvtoolnix \
    # OCR engine and language packs
    tesseract-ocr \
    tesseract-ocr-eng \
    tesseract-ocr-spa \
    tesseract-ocr-fra \
    tesseract-ocr-deu \
    libtesseract4 \
    libtiff5 \
    # Python for pgsrip
    python3-pip \
    # Graphics libraries for pgsrip
    libgl1 \
    libglib2.0-0 \
    # JSON and HTTP tools
    jq \
    curl \
    # MySQL client for IMDB queries
    mariadb-client \
    # Utilities
    gawk \
    bc \
    bash \
    && pip3 install --no-cache-dir pgsrip \
    && rm -rf /var/lib/apt/lists/*

# Copy vobsub2srt from builder
COPY --from=builder /src/vobsub2srt/build/bin/vobsub2srt /usr/local/bin/

# Create app directories
RUN mkdir -p /app/lib

# Copy library scripts
COPY lib/common.sh /app/lib/
COPY lib/llm.sh /app/lib/
COPY lib/imdb.sh /app/lib/

# Copy step scripts
COPY step1-extract-srt.sh /app/
COPY step2-extract-dialogue.sh /app/
COPY step3-extract-characters.sh /app/
COPY step4-create-metadata.sh /app/
COPY step5-imdb-lookup.sh /app/
COPY step6-movie-matching.sh /app/
COPY step7-tv-matching.sh /app/
COPY step8-hybrid-matching.sh /app/
COPY step9-output-movie.sh /app/
COPY step9-output-tv.sh /app/
COPY orchestrator.sh /app/

# Make all scripts executable
RUN chmod +x /app/*.sh /app/lib/*.sh

WORKDIR /work

ENTRYPOINT ["/app/orchestrator.sh"]
