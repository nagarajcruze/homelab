#!/bin/bash

set -euo pipefail

### ===== LOCK FILE — PREVENT CONCURRENT RUNS =====
exec 200>/var/lock/homelab_backup.lock
flock -n 200 || { echo "$(date '+%F %T') [ERROR] Another backup is already running" | tee -a /var/log/homelab_backup.log; exit 1; }

### ===== CONFIG =====
LOG_FILE="/var/log/homelab_backup.log"

### ===== REDIRECT ALL OUTPUT TO BOTH TERMINAL AND LOG FILE =====
exec > >(tee -a "$LOG_FILE") 2>&1
LOCAL_HOMELAB_BORG_REPO="/twins/homelab_borg_backup"
STAGING_DIR="$(mktemp -d /tmp/homelab_borg_backup.XXXXXX)"

# ==== Immich Local Borg Backup ======
IMMICH_BACKUP_PATH="/mnt/speed/immich-borg"

### ===== Borg Remote Backup ======
REMOTE_HOMELAB_BORG_REPO="${REMOTE_HOMELAB_BORG_REPO:-}"

### ===== Healthcheck =====
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

### ===== SERVICES =====
declare -A SERVICES=(
  ["radarr"]="/opt/radarr/rdrconfig/Backups/scheduled/"
  ["prowlarr"]="/opt/radarr/prwlrconfig/Backups/scheduled/"
  ["bazarr"]="/opt/radarr/bazarr/backup/"
  ["sonarr"]="/opt/radarr/sonarr/config/Backups/scheduled/"
  ["jellyfin"]="/opt/jellyfin/config/data/backups/"
  ["navidrome"]="/opt/navidrome/data/backup/"
)

### Restore help commands:
# # 1. Create a temporary mount point
# mkdir -p /mnt/borg-restore
# # 2. Mount the local homelab services repo
# borg mount /twins/homelab_borg_backup /mnt/borg-restore
# # 3. List the available snapshot folders
# ls -la /mnt/borg-restore/
# # 4. Copy the files you want to restore (e.g. Radarr or a compose file)
# # Example: Copy Radarr backup to /tmp or directly to /opt/radarr/...
# cp -r /mnt/borg-restore/<ARCHIVE_NAME>/radarr /opt/radarr/rdrconfig/Backups/scheduled/
# # Example: Copy compose files
# cp -r /mnt/borg-restore/<ARCHIVE_NAME>/compose-files /tmp/restored-compose/
# # 5. When finished, unmount:
# borg umount /mnt/borg-restore

### extract directly specific files
# borg extract extracts files into your current working directory (pwd).
# Always cd into an empty directory first so you don't accidentally overwrite files.
# # 1. Find the archive name
# borg list /twins/homelab_borg_backup
# # 2. Create a clean restore target directory and enter it
# mkdir -p /root/restore-test && cd /root/restore-test
# # 3. Extract the entire archive:
# borg extract --list /twins/homelab_borg_backup::<ARCHIVE_NAME>
# # OR extract only a specific folder (e.g., jellyfin or compose-files):
# borg extract --list /twins/homelab_borg_backup::<ARCHIVE_NAME> jellyfin


### ===== LOG FUNCTION =====
log() {
  echo "$(date '+%F %T') [$1] ${2:-}"
}

### ===== TIMING HELPER =====
timer_start() { date +%s; }
timer_elapsed() {
  local start=$1
  local elapsed=$(( $(date +%s) - start ))
  echo "${elapsed}s"
}

### ===== CLEANUP / ERROR TRAP =====
cleanup() {
  local exit_code=$?
  if [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
  if [ $exit_code -ne 0 ]; then
    log "ERROR" "Backup FAILED with exit code $exit_code — temporary staging cleaned up"
  fi
}
trap cleanup EXIT

log "===================================================================================================="
log "Starting Homelab Services Backup Script..."
log "===================================================================================================="

### ===== VALIDATION =====
if [ -z "$REMOTE_HOMELAB_BORG_REPO" ]; then
  log "ERROR" "REMOTE_HOMELAB_BORG_REPO not set"
  exit 1
fi

if [ -z "$HEALTHCHECK_URL" ]; then
  log "ERROR" "HEALTHCHECK_URL not set"
  exit 1
fi

### ===== PRE-FLIGHT BORG REPO CHECK =====
for repo_name in "Local:$LOCAL_HOMELAB_BORG_REPO" "Remote:$REMOTE_HOMELAB_BORG_REPO" "Immich:$IMMICH_BACKUP_PATH"; do
  label="${repo_name%%:*}"
  repo="${repo_name#*:}"
  if ! borg info "$repo" > /dev/null 2>&1; then
    log "ERROR" "$label Borg repo not accessible: $repo (is it initialized?)"
    exit 1
  fi
done

### ===== RETENTION — DRIVEN BY SERVICES MAP =====
# Jellyfin uses "keep only the latest" logic; all others use 7-day retention.
log "INFO" "Running in-app backup retention cleanup"
for SERVICE in "${!SERVICES[@]}"; do
  SRC="${SERVICES[$SERVICE]}"
  if [ ! -d "$SRC" ]; then
    continue
  fi
  if [ "$SERVICE" = "jellyfin" ]; then
    # Keep only the latest backup file
    (cd "$SRC" && ls -1t | tail -n +2 | xargs -r rm -- 2>/dev/null) || true
  else
    find "$SRC" -type f -mtime +7 -delete 2>/dev/null || true
  fi
done

### ===== DISK SPACE CHECK (/twins) =====
REQUIRED_MB=30000
AVAILABLE_MB=$(df --output=avail -BM "/twins" | tail -1 | tr -d ' M')
if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
  log "ERROR" "Not enough disk space on /twins: ${AVAILABLE_MB}MB available, ${REQUIRED_MB}MB required"
  exit 1
fi

log "INFO" "Homelab backup started. Staging directory: $STAGING_DIR"

### ===== COPY SERVICE BACKUPS TO STAGING =====
for SERVICE in "${!SERVICES[@]}"; do
  SRC="${SERVICES[$SERVICE]}"
  DEST="$STAGING_DIR/$SERVICE"
  if [ -d "$SRC" ]; then
    mkdir -p "$DEST"
    log "INFO" "Copying $SERVICE backups"
    rsync -a --delete "$SRC/" "$DEST/"
  else
    log "WARN" "$SERVICE path not found: $SRC"
  fi
done

### ===== COPY COMPOSE & CONFIG FILES TO STAGING =====
mkdir -p "$STAGING_DIR/compose-files"
(cd /opt && find . -type f \( -name "*compose.yml" -o -name "prometheus.yml" \) -exec cp --parents {} "$STAGING_DIR/compose-files/" \; 2>/dev/null) || true

### ===== IMMICH DB DUMP =====
mkdir -p /twins/photos/immichdb-backup "$STAGING_DIR/immich-db"
if docker inspect --format='{{.State.Running}}' immich_postgres 2>/dev/null | grep -q true; then
  log "INFO" "Dumping Immich PostgreSQL database (gzip compressed)"
  t=$(timer_start)
  docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres | gzip > /twins/photos/immichdb-backup/immich-database.sql.gz
  cp /twins/photos/immichdb-backup/immich-database.sql.gz "$STAGING_DIR/immich-db/immich-database.sql.gz"
  log "INFO" "Immich DB dump completed in $(timer_elapsed "$t")"
else
  log "WARN" "immich_postgres container is not running. Using previous DB dump if available."
  # Copy the last known good dump to staging if it exists
  if [ -f /twins/photos/immichdb-backup/immich-database.sql.gz ]; then
    cp /twins/photos/immichdb-backup/immich-database.sql.gz "$STAGING_DIR/immich-db/immich-database.sql.gz"
  else
    log "WARN" "No previous Immich DB dump found either."
  fi
fi

### ===== 1. LOCAL BORG BACKUP (HOMELAB SERVICES ON /twins) =====
log "INFO" "Starting Local Borg backup for homelab services to $LOCAL_HOMELAB_BORG_REPO"
t=$(timer_start)
borg create --stats --compression zstd,6 "$LOCAL_HOMELAB_BORG_REPO"::'{now}' "$STAGING_DIR/"
log "INFO" "Local Borg backup completed in $(timer_elapsed "$t")"

log "INFO" "Pruning Local Borg backup for homelab services repository"
borg prune --list --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$LOCAL_HOMELAB_BORG_REPO"

log "INFO" "Compacting Local Borg backup for homelab services repository"
borg compact "$LOCAL_HOMELAB_BORG_REPO"

### ===== 2. REMOTE BORG BACKUP (HOMELAB SERVICES On BorgBase) =====
log "INFO" "Starting Remote Borg backup for Homelab Services"
t=$(timer_start)
if borg create --stats --compression zstd,6 "$REMOTE_HOMELAB_BORG_REPO"::'{now}' "$STAGING_DIR/"; then
  log "INFO" "Remote Borg backup for Homelab Services completed in $(timer_elapsed "$t")"

  log "INFO" "Pruning Remote Borg backup for Homelab Services"
  if ! borg prune --list --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$REMOTE_HOMELAB_BORG_REPO"; then
    log "WARN" "Remote Borg prune for Homelab Services failed. Old archives may linger on BorgBase."
  fi

  log "INFO" "Compacting Remote Borg backup for Homelab Services"
  if ! borg compact "$REMOTE_HOMELAB_BORG_REPO"; then
    log "WARN" "Remote Borg for Homelab Services compact failed."
  fi
else
  log "WARN" "Remote Borg backup for Homelab Services failed after $(timer_elapsed "$t"). Continuing with Immich backup."
fi

### ===== 3. IMMICH DB & BORG BACKUP =====
log "INFO" "Starting Local Borg backup for Immich to $IMMICH_BACKUP_PATH"
t=$(timer_start)
borg create --stats "$IMMICH_BACKUP_PATH::{now}" /twins/photos/library /twins/photos/profile /opt/immich/upload /twins/photos/immichdb-backup/immich-database.sql.gz
log "INFO" "Local Borg backup for Immich completed in $(timer_elapsed "$t")"

log "INFO" "Pruning Local Borg backup for Immich"
borg prune --list --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$IMMICH_BACKUP_PATH"

log "INFO" "Compacting Local Borg backup for Immich"
borg compact "$IMMICH_BACKUP_PATH"

### Ping after successful backup
if [ -n "$HEALTHCHECK_URL" ]; then
    curl -sS -m 10 --retry 5 "$HEALTHCHECK_URL" || true
else
    log "WARN" "HEALTHCHECK_URL not set. Skipping healthcheck ping."
fi

### ===== DONE =====
log "Backup completed successfully"