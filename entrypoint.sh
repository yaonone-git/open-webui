#!/usr/bin/env bash
set -u

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}
require_env() {
  local name="$1"
  local value="${!name:-}"
  if [ -z "$value" ]; then
    log "Missing required env: $name"
    exit 1
  fi
}
require_env HF_TOKEN
require_env HF_REPO_ID

DB_PATH="${DB_PATH:-/app/backend/data/webui.db}"
HF_REPO_TYPE="${HF_REPO_TYPE:-dataset}"
HF_PREFIX="${HF_PREFIX:-halowebui}"
HF_PRIVATE="${HF_PRIVATE:-true}"
BACKUP_INTERVAL_SECONDS="${BACKUP_INTERVAL_SECONDS:-21600}"
INITIAL_BACKUP_DELAY_SECONDS="${INITIAL_BACKUP_DELAY_SECONDS:-30}"
BACKUP_KEEP_LAST="${BACKUP_KEEP_LAST:-3}"

HF_PREFIX="$(echo "$HF_PREFIX" | sed 's#^/##; s#/$##')"

export DB_PATH
export HF_REPO_TYPE
export HF_PREFIX
export HF_PRIVATE
export BACKUP_INTERVAL_SECONDS
export INITIAL_BACKUP_DELAY_SECONDS
export BACKUP_KEEP_LAST

if [ -n "$HF_PREFIX" ]; then
  HF_PREFIX_SLASH="${HF_PREFIX}/"
else
  HF_PREFIX_SLASH=""
fi

TMP_DIR="/tmp/halowebui-backup"
mkdir -p "$TMP_DIR"

APP_PID=""
BACKUP_PID=""

log "Entrypoint started"
log "DB_PATH=$DB_PATH"
log "HF_REPO_ID=$HF_REPO_ID"
log "HF_REPO_TYPE=$HF_REPO_TYPE"
log "HF_PREFIX=$HF_PREFIX"
log "HF_PRIVATE=$HF_PRIVATE"
log "BACKUP_INTERVAL_SECONDS=$BACKUP_INTERVAL_SECONDS"
log "INITIAL_BACKUP_DELAY_SECONDS=$INITIAL_BACKUP_DELAY_SECONDS"
log "BACKUP_KEEP_LAST=$BACKUP_KEEP_LAST"
log "APP_CMD=$*"

db_is_valid() {
  if [ ! -f "$DB_PATH" ]; then
    return 1
  fi

  sqlite3 "$DB_PATH" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"
}

get_latest_backup_key() {
  python3 - <<'PY'
import os
import sys
from huggingface_hub import HfApi
from huggingface_hub.errors import RepositoryNotFoundError

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO_ID"]
repo_type = os.environ.get("HF_REPO_TYPE", "dataset")
prefix = os.environ.get("HF_PREFIX", "").strip("/")

prefix_slash = f"{prefix}/" if prefix else ""

api = HfApi(token=token)

try:
    files = api.list_repo_files(
        repo_id=repo_id,
        repo_type=repo_type,
        token=token,
    )
except RepositoryNotFoundError:
    print("")
    sys.exit(0)
except Exception as e:
    print("__ERROR__" + str(e))
    sys.exit(0)

candidates = [
    f for f in files
    if f.startswith(prefix_slash)
    and f.endswith(".db.gz")
]

candidates.sort()

if candidates:
    print(candidates[-1])
else:
    print("")
PY
}

download_backup() {
  local key="$1"
  local target="$2"

  FILENAME="$key" TARGET_FILE="$target" python3 - <<'PY'
import os
import shutil
from huggingface_hub import hf_hub_download

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO_ID"]
repo_type = os.environ.get("HF_REPO_TYPE", "dataset")
filename = os.environ["FILENAME"]
target = os.environ["TARGET_FILE"]

path = hf_hub_download(
    repo_id=repo_id,
    filename=filename,
    repo_type=repo_type,
    token=token,
)

shutil.copyfile(path, target)
PY
}

upload_backup_file() {
  local local_file="$1"
  local path_in_repo="$2"

  LOCAL_FILE="$local_file" PATH_IN_REPO="$path_in_repo" python3 - <<'PY'
import os
from huggingface_hub import HfApi

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO_ID"]
repo_type = os.environ.get("HF_REPO_TYPE", "dataset")
private = os.environ.get("HF_PRIVATE", "true").lower() in ("1", "true", "yes", "y")
local_file = os.environ["LOCAL_FILE"]
path_in_repo = os.environ["PATH_IN_REPO"]

api = HfApi(token=token)

api.create_repo(
    repo_id=repo_id,
    repo_type=repo_type,
    private=private,
    exist_ok=True,
    token=token,
)

api.upload_file(
    path_or_fileobj=local_file,
    path_in_repo=path_in_repo,
    repo_id=repo_id,
    repo_type=repo_type,
    token=token,
    commit_message=f"backup {path_in_repo}",
)
PY
}

cleanup_old_backups() {
  log "Cleaning old backups on Hugging Face, keep latest ${BACKUP_KEEP_LAST}..."

  python3 - <<'PY'
import os
import sys
from huggingface_hub import HfApi, CommitOperationDelete
from huggingface_hub.errors import RepositoryNotFoundError

token = os.environ["HF_TOKEN"]
repo_id = os.environ["HF_REPO_ID"]
repo_type = os.environ.get("HF_REPO_TYPE", "dataset")
prefix = os.environ.get("HF_PREFIX", "").strip("/")

try:
    keep_last = int(os.environ.get("BACKUP_KEEP_LAST", "3"))
except Exception:
    keep_last = 3

if keep_last < 1:
    keep_last = 3

prefix_slash = f"{prefix}/" if prefix else ""

api = HfApi(token=token)

try:
    files = api.list_repo_files(
        repo_id=repo_id,
        repo_type=repo_type,
        token=token,
    )
except RepositoryNotFoundError:
    print("Repository not found, skip cleanup")
    sys.exit(0)
except Exception as e:
    print(f"List repo files failed, skip cleanup: {e}")
    sys.exit(0)

backups = [
    f for f in files
    if f.startswith(prefix_slash)
    and f.endswith(".db.gz")
]

backups.sort()

if len(backups) <= keep_last:
    print(f"Backup count {len(backups)}, no cleanup needed")
    sys.exit(0)

delete_files = backups[:-keep_last]

operations = [
    CommitOperationDelete(path_in_repo=f)
    for f in delete_files
]

try:
    api.create_commit(
        repo_id=repo_id,
        repo_type=repo_type,
        operations=operations,
        commit_message=f"cleanup old backups, keep latest {keep_last}",
        token=token,
    )
except Exception as e:
    print(f"Delete old backups failed: {e}")
    sys.exit(0)

print("Deleted old backups:")
for f in delete_files:
    print(f"- {f}")
PY
}

restore_latest_backup() {
  log "Checking latest backup from Hugging Face..."

  local latest_key
  latest_key="$(get_latest_backup_key || true)"

  if [[ "$latest_key" == __ERROR__* ]]; then
    log "Failed to check Hugging Face backup: ${latest_key#__ERROR__}"
    return 2
  fi

  if [ -z "$latest_key" ]; then
    log "No remote backup found on Hugging Face"
    return 1
  fi

  log "Latest remote backup: $latest_key"

  local restore_gz="$TMP_DIR/restore.db.gz"
  local restore_db="$TMP_DIR/restore.db"

  rm -f "$restore_gz" "$restore_db"

  if ! download_backup "$latest_key" "$restore_gz"; then
    log "Download backup failed"
    return 2
  fi

  if ! gzip -dc "$restore_gz" > "$restore_db"; then
    log "Unzip backup failed"
    return 2
  fi

  if ! sqlite3 "$restore_db" "PRAGMA integrity_check;" 2>/dev/null | grep -qx "ok"; then
    log "SQLite integrity check failed, refuse to restore"
    return 2
  fi

  local db_dir
  db_dir="$(dirname "$DB_PATH")"
  mkdir -p "$db_dir"

  if [ -f "$DB_PATH" ]; then
    local local_bak="${DB_PATH}.before-restore-$(date +%Y%m%d-%H%M%S)"
    log "Local database exists, saving copy to $local_bak"
    cp "$DB_PATH" "$local_bak" || return 2
  fi

  cp "$restore_db" "$DB_PATH" || {
    log "Restore database failed"
    return 2
  }

  log "Restore finished: $DB_PATH"
  return 0
}

backup_once() {
  local backup_type="${1:-scheduled}"

  log "Starting $backup_type backup..."

  if [ ! -f "$DB_PATH" ]; then
    log "Database file not found: $DB_PATH"
    return 1
  fi

  if ! db_is_valid; then
    log "Database exists but integrity check failed or database is not ready"
    return 1
  fi

  local time
  time="$(date +%Y%m%d-%H%M%S)"

  local tmp_db="$TMP_DIR/webui-$time.db"
  local tmp_gz="$tmp_db.gz"
  local path_in_repo="${HF_PREFIX_SLASH}webui-$time.db.gz"

  rm -f "$tmp_db" "$tmp_gz"

  if ! sqlite3 "$DB_PATH" ".backup '$tmp_db'"; then
    log "SQLite backup failed"
    return 1
  fi

  if ! gzip -f "$tmp_db"; then
    log "gzip failed"
    return 1
  fi

  if ! upload_backup_file "$tmp_gz" "$path_in_repo"; then
    log "Upload to Hugging Face failed"
    rm -f "$tmp_gz"
    return 1
  fi

  rm -f "$tmp_gz"

  log "Backup uploaded to hf.co/$HF_REPO_ID/blob/main/$path_in_repo"
  log "$backup_type backup finished"

  cleanup_old_backups || true

  return 0
}

wait_for_valid_db() {
  log "Waiting for valid database: $DB_PATH"

  while true; do
    if [ -n "${APP_PID:-}" ]; then
      if ! kill -0 "$APP_PID" 2>/dev/null; then
        log "Application process exited while waiting for database"
        return 1
      fi
    fi

    if db_is_valid; then
      log "Database is ready and valid"
      return 0
    fi

    log "Database not ready yet"
    sleep 5
  done
}

backup_loop() {
  while true; do
    log "Sleeping ${BACKUP_INTERVAL_SECONDS}s before next scheduled backup..."
    sleep "$BACKUP_INTERVAL_SECONDS"

    if backup_once "scheduled"; then
      log "Scheduled backup success"
    else
      log "Scheduled backup failed"
    fi
  done
}

stop_all() {
  log "Stopping..."

  if [ -n "${BACKUP_PID:-}" ]; then
    kill "$BACKUP_PID" 2>/dev/null || true
  fi

  if [ -n "${APP_PID:-}" ]; then
    kill "$APP_PID" 2>/dev/null || true
  fi

  exit 0
}

trap stop_all INT TERM

REMOTE_BACKUP_EXISTS="false"
INITIAL_BACKUP_DONE="false"

restore_latest_backup
RESTORE_STATUS=$?

if [ "$RESTORE_STATUS" -eq 0 ]; then
  REMOTE_BACKUP_EXISTS="true"
  log "Remote backup restored successfully"

  cleanup_old_backups || true
elif [ "$RESTORE_STATUS" -eq 1 ]; then
  REMOTE_BACKUP_EXISTS="false"
  log "No remote backup restored"
else
  log "Restore check failed. For data safety, container will exit."
  exit 1
fi

if [ "$REMOTE_BACKUP_EXISTS" = "false" ]; then
  if db_is_valid; then
    log "No remote backup, but local database exists. Creating initial backup before app start..."

    if backup_once "initial"; then
      INITIAL_BACKUP_DONE="true"
      log "Initial backup submitted successfully"
    else
      log "Initial backup failed before app start"
    fi
  else
    log "No remote backup and no valid local database yet"
  fi
fi

log "Starting application..."
"$@" &

APP_PID="$!"

if [ "$REMOTE_BACKUP_EXISTS" = "false" ] && [ "$INITIAL_BACKUP_DONE" = "false" ]; then
  log "Will create initial backup after application creates database"

  if wait_for_valid_db; then
    if [ "$INITIAL_BACKUP_DELAY_SECONDS" -gt 0 ] 2>/dev/null; then
      log "Waiting ${INITIAL_BACKUP_DELAY_SECONDS}s before initial backup..."
      sleep "$INITIAL_BACKUP_DELAY_SECONDS"
    fi

    if backup_once "initial"; then
      log "Initial backup submitted successfully"
    else
      log "Initial backup failed"
    fi
  else
    log "Skip initial backup because database is not ready"
  fi
else
  log "Remote backup exists or initial backup already done, skip initial backup"
fi

backup_loop &

BACKUP_PID="$!"

wait "$APP_PID"
APP_EXIT_CODE=$?

log "Application exited with code $APP_EXIT_CODE"

if [ -n "${BACKUP_PID:-}" ]; then
  kill "$BACKUP_PID" 2>/dev/null || true
fi

exit "$APP_EXIT_CODE"
