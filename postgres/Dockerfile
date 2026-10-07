# PostgreSQL 16 with pgvector (for RAG) and legacy time zone names.
# Some clients (e.g. DBeaver on Windows) send old zone names such as America/Buenos_Aires.
# Debian 12 ships them; Debian 13+ moved them to tzdata-legacy, so install it only when missing.
FROM pgvector/pgvector:pg16

RUN if [ ! -e /usr/share/zoneinfo/America/Buenos_Aires ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends tzdata-legacy \
      && rm -rf /var/lib/apt/lists/*; \
    fi
