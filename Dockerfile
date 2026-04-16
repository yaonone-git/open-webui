FROM ghcr.io/ztx888/halowebui:main
USER root

RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl tzdata \
    && SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64" \
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic \
    && pip install --no-cache-dir "Authlib>=1.6.9" "huggingface_hub>=0.20.0" \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# 创建目录并设置权限
RUN mkdir -p /tmp/backups /app/backend/data && \
    chown -R 10014:10014 /tmp/backups /app/backend/data

# 备份脚本
RUN echo '#!/bin/bash' > /app/backup.sh && \
    echo 'set -e' >> /app/backup.sh && \
    echo 'BACKUP_DIR="/tmp/backups"' >> /app/backup.sh && \
    echo 'DATA_DIR="/app/backend/data"' >> /app/backup.sh && \
    echo 'DATE=$(date +%Y%m%d_%H%M%S)' >> /app/backup.sh && \
    echo 'BACKUP_FILE="backup_$DATE.tar.gz"' >> /app/backup.sh && \
    echo 'mkdir -p "$BACKUP_DIR"' >> /app/backup.sh && \
    echo 'echo "[$(date)] Starting backup..."' >> /app/backup.sh && \
    echo 'if [ ! -d "$DATA_DIR" ]; then' >> /app/backup.sh && \
    echo '    echo "[$(date)] $DATA_DIR not found, skip"' >> /app/backup.sh && \
    echo '    exit 0' >> /app/backup.sh && \
    echo 'fi' >> /app/backup.sh && \
    echo 'if [ -z "$(ls -A $DATA_DIR 2>/dev/null)" ]; then' >> /app/backup.sh && \
    echo '    echo "[$(date)] $DATA_DIR is empty, skip"' >> /app/backup.sh && \
    echo '    exit 0' >> /app/backup.sh && \
    echo 'fi' >> /app/backup.sh && \
    echo 'tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C "$DATA_DIR" .' >> /app/backup.sh && \
    echo 'echo "[$(date)] Created: $BACKUP_FILE"' >> /app/backup.sh && \
    echo 'if [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]; then' >> /app/backup.sh && \
    echo '    huggingface-cli upload "$HF_REPO" "$BACKUP_DIR/$BACKUP_FILE" "$BACKUP_FILE" --repo-type dataset --token "$HF_TOKEN"' >> /app/backup.sh && \
    echo '    echo "[$(date)] Uploaded to HF"' >> /app/backup.sh && \
    echo 'fi' >> /app/backup.sh && \
    echo 'ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f' >> /app/backup.sh && \
    echo 'echo "[$(date)] Backup completed"' >> /app/backup.sh

# 恢复脚本
RUN echo '#!/bin/bash' > /app/restore.sh && \
    echo 'set -e' >> /app/restore.sh && \
    echo 'BACKUP_DIR="/tmp/backups"' >> /app/restore.sh && \
    echo 'DATA_DIR="/app/backend/data"' >> /app/restore.sh && \
    echo 'mkdir -p "$BACKUP_DIR" "$DATA_DIR"' >> /app/restore.sh && \
    echo 'echo "[$(date)] Starting restore..."' >> /app/restore.sh && \
    echo 'if [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]; then' >> /app/restore.sh && \
    echo '    echo "[$(date)] Downloading from HF..."' >> /app/restore.sh && \
    echo '    huggingface-cli download "$HF_REPO" --repo-type dataset --local-dir "$BACKUP_DIR" --token "$HF_TOKEN" 2>/dev/null || true' >> /app/restore.sh && \
    echo 'fi' >> /app/restore.sh && \
    echo 'LATEST=$(ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -n 1)' >> /app/restore.sh && \
    echo 'if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then' >> /app/restore.sh && \
    echo '    echo "[$(date)] Restoring: $LATEST"' >> /app/restore.sh && \
    echo '    rm -rf "$DATA_DIR"/*' >> /app/restore.sh && \
    echo '    tar -xzf "$LATEST" -C "$DATA_DIR"' >> /app/restore.sh && \
    echo '    echo "[$(date)] Restore completed"' >> /app/restore.sh && \
    echo 'else' >> /app/restore.sh && \
    echo '    echo "[$(date)] No backup found"' >> /app/restore.sh && \
    echo 'fi' >> /app/restore.sh

# 入口脚本 - 添加 cd 到正确目录
RUN echo '#!/bin/bash' > /app/entrypoint.sh && \
    echo 'set -e' >> /app/entrypoint.sh && \
    echo 'mkdir -p /tmp/backups /app/backend/data' >> /app/entrypoint.sh && \
    echo 'BACKUP_HOUR="${BACKUP_HOUR:-3}"' >> /app/entrypoint.sh && \
    echo 'BACKUP_MINUTE="${BACKUP_MINUTE:-0}"' >> /app/entrypoint.sh && \
    echo 'BACKUP_CRON="${BACKUP_CRON:-}"' >> /app/entrypoint.sh && \
    echo 'if [ -n "$BACKUP_CRON" ]; then' >> /app/entrypoint.sh && \
    echo '    CRON_EXPR="$BACKUP_CRON"' >> /app/entrypoint.sh && \
    echo 'else' >> /app/entrypoint.sh && \
    echo '    CRON_EXPR="$BACKUP_MINUTE $BACKUP_HOUR * * *"' >> /app/entrypoint.sh && \
    echo 'fi' >> /app/entrypoint.sh && \
    echo 'echo "$CRON_EXPR /app/backup.sh >> /tmp/backup.log 2>&1" > /tmp/crontab' >> /app/entrypoint.sh && \
    echo 'echo "=========================================="' >> /app/entrypoint.sh && \
    echo 'echo "Container starting: $(date)"' >> /app/entrypoint.sh && \
    echo 'echo "Timezone: $TZ"' >> /app/entrypoint.sh && \
    echo 'echo "Backup:   $CRON_EXPR"' >> /app/entrypoint.sh && \
    echo 'echo "=========================================="' >> /app/entrypoint.sh && \
    echo '/app/restore.sh' >> /app/entrypoint.sh && \
    echo 'supercronic /tmp/crontab &' >> /app/entrypoint.sh && \
    echo 'cd /app/backend' >> /app/entrypoint.sh && \
    echo 'exec "$@"' >> /app/entrypoint.sh

RUN chmod +x /app/backup.sh /app/restore.sh /app/entrypoint.sh && \
    chown 10014:10014 /app/backup.sh /app/restore.sh /app/entrypoint.sh

ENV TZ=Asia/Shanghai
ENV BACKUP_HOUR=3
ENV BACKUP_MINUTE=0

# 关键：设置工作目录
WORKDIR /app/backend

USER 10014

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["bash", "start.sh"]
