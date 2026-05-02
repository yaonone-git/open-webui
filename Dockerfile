FROM ghcr.io/ztx888/halowebui:main

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        sqlite3 \
        gzip \
        ca-certificates \
        python3 \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir --break-system-packages huggingface_hub

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV DB_PATH=/app/backend/data/webui.db

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["bash", "start.sh"]
