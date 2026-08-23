#!/bin/bash

set -euo pipefail

### ===== CONFIG =====
LOG_FILE="/var/log/homelab_backup.log"
LOCAL_HOMELAB_BORG_REPO="/twins/homelab_borg_backup"
STAGING_DIR="$(mktemp -d /tmp/homelab_borg_backup.XXXXXX)"

# ==== Immich Local Borg Backup ======
IMMICH_BACKUP_PATH="/mnt/speed/immich-borg"

### ===== Borg Remote Backup ======
REMOTE_HOMELAB_BORG_REPO="${REMOTE_HOMELAB_BORG_REPO:-}"

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
  echo "$(date '+%F %T') [$1] $2" | tee -a "$LOG_FILE"
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

### ===== VALIDATION =====
if [ -z "$REMOTE_HOMELAB_BORG_REPO" ]; then
  log "ERROR" "REMOTE_HOMELAB_BORG_REPO (or BORG_REMOTE env var) not set"
  exit 1
fi

### ===== RETENTION (7 DAYS FOR SERVICE IN-APP BACKUPS) =====
find /opt/radarr/bazarr/backup/ -name "bazarr*" -type f -mtime +7 -delete 2>/dev/null || true
find /opt/radarr/rdrconfig/Backups/scheduled/ -name "radarr_*" -type f -mtime +7 -delete 2>/dev/null || true
find /opt/radarr/prwlrconfig/Backups/scheduled/ -name "prowlarr*" -type f -mtime +7 -delete 2>/dev/null || true
if [ -d "/opt/jellyfin/config/data/backups" ]; then
  (cd /opt/jellyfin/config/data/backups && ls -1t | tail -n +2 | xargs -r rm -- 2>/dev/null) || true
fi

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
    rsync -a --delete "$SRC/" "$DEST/" >> "$LOG_FILE" 2>&1
  else
    log "WARN" "$SERVICE path not found: $SRC"
  fi
done

### ===== COPY COMPOSE & CONFIG FILES TO STAGING =====
mkdir -p "$STAGING_DIR/compose-files"
(cd /opt && find . -type f \( -name "*compose.yml" -o -name "prometheus.yml" \) -exec cp --parents {} "$STAGING_DIR/compose-files/" \; 2>/dev/null) || true

### ===== IMMICH DB DUMP (FOR IMMICH & HOMELAB REPOS) =====
log "INFO" "Dumping Immich PostgreSQL database"
mkdir -p /twins/photos/immichdb-backup "$STAGING_DIR/immich-db"
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres > /twins/photos/immichdb-backup/immich-database.sql
cp /twins/photos/immichdb-backup/immich-database.sql "$STAGING_DIR/immich-db/immich-database.sql"

### ===== 1. LOCAL BORG BACKUP (HOMELAB SERVICES ON /twins) =====
log "INFO" "Starting Local Borg backup for homelab services to $LOCAL_HOMELAB_BORG_REPO"
borg create --stats --compression zstd,6 "$LOCAL_HOMELAB_BORG_REPO"::'homelab-{now}' "$STAGING_DIR/" >> "$LOG_FILE" 2>&1

log "INFO" "Pruning Local Services Borg repository"
borg prune --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$LOCAL_HOMELAB_BORG_REPO" >> "$LOG_FILE" 2>&1

log "INFO" "Compacting Local Services Borg repository"
borg compact "$LOCAL_HOMELAB_BORG_REPO" >> "$LOG_FILE" 2>&1

### ===== 2. REMOTE BORG BACKUP (HOMELAB SERVICES On BorgBase) =====
log "INFO" "Starting Remote Borg backup for Homelab Services"
borg create --stats --compression zstd,6 "$REMOTE_HOMELAB_BORG_REPO"::'homelab-{now}' "$STAGING_DIR/" >> "$LOG_FILE" 2>&1

log "INFO" "Pruning Remote Borg repository"
borg prune --glob-archives 'homelab-*' --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$REMOTE_HOMELAB_BORG_REPO" >> "$LOG_FILE" 2>&1

log "INFO" "Compacting Remote Borg repository"
borg compact "$REMOTE_HOMELAB_BORG_REPO" >> "$LOG_FILE" 2>&1

### ===== 3. IMMICH DB & BORG BACKUP =====
log "INFO" "Starting Borg backup for Immich"
borg create --stats "$IMMICH_BACKUP_PATH::{now}" /twins/photos/library /twins/photos/profile /opt/immich/upload /twins/photos/immichdb-backup/immich-database.sql >> "$LOG_FILE" 2>&1

log "INFO" "Pruning Immich Borg repository"
borg prune --keep-weekly=4 --keep-monthly=11 --keep-yearly=1 "$IMMICH_BACKUP_PATH" >> "$LOG_FILE" 2>&1

log "INFO" "Compacting Immich Borg repository"
borg compact "$IMMICH_BACKUP_PATH" >> "$LOG_FILE" 2>&1

### ===== DONE =====
log "INFO" "Backup completed successfully"

### Ping healthchecks.io after successful backup
curl -m 10 --retry 5 https://hc-ping.com/
