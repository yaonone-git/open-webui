FROM ghcr.io/ztx888/halowebui:main

USER root

# 安装依赖和修复漏洞
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends curl \
    && SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v0.2.33/supercronic-linux-amd64" \
    && curl -fsSL "$SUPERCRONIC_URL" -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic \
    && pip install --no-cache-dir "Authlib>=1.6.9" "huggingface_hub>=0.20.0" \
    && apt-get purge -y curl \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# 创建备份目录
RUN mkdir -p /app/backups && chown -R 10014:10014 /app/backups

# 创建备份脚本
RUN cat > /app/backup.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_DIR="/app/backups"
DATA_DIR="/app/backend/data"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_$DATE.tar.gz"

echo "[$(date)] Starting backup..."

# 创建压缩备份
if [ -d "$DATA_DIR" ]; then
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" -C /app/backend data
    echo "[$(date)] Created: $BACKUP_FILE"
else
    echo "[$(date)] Warning: $DATA_DIR not found"
    exit 0
fi

# 上传到 Hugging Face
if [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]; then
    huggingface-cli upload "$HF_REPO" "$BACKUP_DIR/$BACKUP_FILE" "$BACKUP_FILE" \
        --repo-type dataset --token "$HF_TOKEN"
    echo "[$(date)] Uploaded to HF: $HF_REPO"
fi

# 保留最新5份备份（本地和远程）
cd "$BACKUP_DIR"
ls -t backup_*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
echo "[$(date)] Cleanup completed, kept latest 5 backups"

# 清理 HF 远程旧备份（保留5份）
if [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]; then
    python3 << 'PYTHON'
import os
from huggingface_hub import HfApi, list_repo_files

api = HfApi(token=os.environ.get("HF_TOKEN"))
repo_id = os.environ.get("HF_REPO")

try:
    files = [f for f in list_repo_files(repo_id, repo_type="dataset") if f.startswith("backup_")]
    files.sort(reverse=True)
    for old_file in files[5:]:
        api.delete_file(old_file, repo_id, repo_type="dataset")
        print(f"Deleted remote: {old_file}")
except Exception as e:
    print(f"Remote cleanup warning: {e}")
PYTHON
fi

echo "[$(date)] Backup completed successfully"
EOF

# 创建恢复脚本
RUN cat > /app/restore.sh << 'EOF'
#!/bin/bash
set -e

BACKUP_DIR="/app/backups"
DATA_DIR="/app/backend/data"

echo "[$(date)] Checking for backups to restore..."

# 从 HF 下载最新备份
if [ -n "$HF_TOKEN" ] && [ -n "$HF_REPO" ]; then
    echo "[$(date)] Fetching latest backup from HF..."
    python3 << 'PYTHON'
import os
from huggingface_hub import hf_hub_download, list_repo_files

repo_id = os.environ.get("HF_REPO")
token = os.environ.get("HF_TOKEN")
backup_dir = "/app/backups"

try:
    files = [f for f in list_repo_files(repo_id, repo_type="dataset", token=token) if f.startswith("backup_")]
    if files:
        files.sort(reverse=True)
        latest = files[0]
        local_path = os.path.join(backup_dir, latest)
        if not os.path.exists(local_path):
            hf_hub_download(repo_id, latest, repo_type="dataset", token=token, local_dir=backup_dir)
            print(f"Downloaded: {latest}")
        else:
            print(f"Already exists: {latest}")
    else:
        print("No backups found on HF")
except Exception as e:
    print(f"Download warning: {e}")
PYTHON
fi

# 查找最新本地备份并恢复
LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/backup_*.tar.gz 2>/dev/null | head -n 1)

if [ -n "$LATEST_BACKUP" ] && [ -f "$LATEST_BACKUP" ]; then
    echo "[$(date)] Restoring from: $LATEST_BACKUP"
    
    # 备份现有数据（如果存在）
    if [ -d "$DATA_DIR" ]; then
        mv "$DATA_DIR" "${DATA_DIR}.old.$$"
    fi
    
    # 解压恢复
    mkdir -p /app/backend
    tar -xzf "$LATEST_BACKUP" -C /app/backend
    
    # 清理旧数据
    rm -rf "${DATA_DIR}.old.$$"
    
    echo "[$(date)] Restore completed successfully"
else
    echo "[$(date)] No backup found, starting fresh"
fi
EOF

# 创建 crontab（每天凌晨2点备份）
RUN echo "0 2 * * * /app/backup.sh >> /app/backups/backup.log 2>&1" > /app/crontab

# 创建入口脚本
RUN cat > /app/entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "========================================"
echo "Container starting at $(date)"
echo "========================================"

# 执行恢复
/app/restore.sh

# 启动定时备份（后台）
echo "[$(date)] Starting supercronic..."
supercronic /app/crontab &

# 启动主应用（根据原镜像调整）
echo "[$(date)] Starting main application..."
exec "$@"
EOF

# 设置权限
RUN chmod +x /app/backup.sh /app/restore.sh /app/entrypoint.sh \
    && chown -R 10014:10014 /app/backup.sh /app/restore.sh /app/entrypoint.sh /app/crontab /app/backups

USER 10014

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["python", "main.py"]
