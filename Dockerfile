FROM ghcr.io/ztx888/halowebui:main
USER root

RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl tzdata \
    && SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64" \
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic \
    && pip install --no-cache-dir "Authlib>=1.6.9" "huggingface_hub>=0.20.0" \
    && mkdir -p /app/backend/data /tmp/backups /tmp/huggingface /tmp/.cache \
    && chown -R 10014:0 /app/backend/data /tmp \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# 备份脚本
RUN cat > /app/backup.sh <<'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/tmp/backups"
DATA_DIR="/app/backend/data"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_$DATE.tar.gz"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting backup..."
echo "[$(date)] DATA_DIR=$DATA_DIR"
echo "[$(date)] BACKUP_DIR=$BACKUP_DIR"

if [ ! -d "$DATA_DIR" ]; then
    echo "[$(date)] $DATA_DIR not found, skip"
    exit 0
fi

if [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
    echo "[$(date)] $DATA_DIR is empty, skip"
    exit 0
fi

tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$DATA_DIR" .
echo "[$(date)] Created: $BACKUP_FILE"

if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_REPO:-}" ]; then
    echo "[$(date)] Uploading to HF repo: $HF_REPO"
    huggingface-cli upload "$HF_REPO" "$BACKUP_DIR/$BACKUP_FILE" "$BACKUP_FILE" --repo-type dataset --token "$HF_TOKEN"
    echo "[$(date)] Uploaded to HF"
else
    echo "[$(date)] HF_TOKEN or HF_REPO not set, skip upload"
fi

ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
echo "[$(date)] Backup completed"
EOF

# 恢复脚本
RUN cat > /app/restore.sh <<'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR="/tmp/backups"
DATA_DIR="/app/backend/data"

mkdir -p "$BACKUP_DIR"

echo "[$(date)] Starting restore..."

if [ ! -d "$DATA_DIR" ]; then
    echo "[$(date)] $DATA_DIR not found, skip restore"
    exit 0
fi

if [ -n "${HF_TOKEN:-}" ] && [ -n "${HF_REPO:-}" ]; then
    echo "[$(date)] Downloading from HF..."
    huggingface-cli download "$HF_REPO" --repo-type dataset --local-dir "$BACKUP_DIR" --token "$HF_TOKEN" 2>/dev/null || true
fi

LATEST=$(ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -n 1 || true)

if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    echo "[$(date)] Restoring: $LATEST"
    rm -rf "$DATA_DIR"/*
    tar -xzf "$LATEST" -C "$DATA_DIR"
    echo "[$(date)] Restore completed"
else
    echo "[$(date)] No backup found"
fi
EOF

# 入口脚本
RUN cat > /app/entrypoint.sh <<'EOF'
#!/bin/bash
set -euo pipefail

mkdir -p /tmp/backups /tmp/huggingface /tmp/.cache

BACKUP_HOUR="${BACKUP_HOUR:-3}"
BACKUP_MINUTE="${BACKUP_MINUTE:-0}"
BACKUP_CRON="${BACKUP_CRON:-}"

if [ -n "$BACKUP_CRON" ]; then
    CRON_EXPR="$BACKUP_CRON"
else
    CRON_EXPR="$BACKUP_MINUTE $BACKUP_HOUR * * *"
fi

echo "$CRON_EXPR /app/backup.sh >> /tmp/backup.log 2>&1" > /tmp/crontab

echo "=========================================="
echo "Container starting: $(date)"
echo "Timezone: $TZ"
echo "Backup:   $CRON_EXPR"
echo "=========================================="

/app/restore.sh || true
supercronic /tmp/crontab &
exec "$@"
EOF

RUN chmod +x /app/backup.sh /app/restore.sh /app/entrypoint.sh

ENV TZ=Asia/Shanghai
ENV BACKUP_HOUR=3
ENV BACKUP_MINUTE=0
ENV HOME=/tmp
ENV HF_HOME=/tmp/huggingface
ENV XDG_CACHE_HOME=/tmp/.cache
ENV TMPDIR=/tmp

USER 10014

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bash", "start.sh"]
