#!/bin/bash

set -euo pipefail

### ===== CONFIG =====
DATE=$(date +%F_%H-%M)
LOG_FILE="/var/log/homelab_backup.log"
BACKUP_ROOT="/root/homelab_svc_backups"
ADD_BACKUP="/twins/homelab_svc_backups"
RAW_DIR="$BACKUP_ROOT/raw/$DATE"
ENC_DIR="$BACKUP_ROOT/encrypted"
SNAPSHOT_DIR="/.snapshots"
SNAPSHOT_RETENTION_DAYS=7
PASSWORD="${BACKUP_PASS:-}"

### ===== LOCK =====
# LOCK_FILE="/var/run/homelab_backup.lock"
# exec 200>"$LOCK_FILE"
# flock -n 200 || { echo "Another backup is running"; exit 1; }

### ===== SERVICES =====
declare -A SERVICES=(
  ["radarr"]="/opt/radarr/rdrconfig/Backups/manual/"
  ["prowlarr"]="/opt/radarr/prwlrconfig/Backups/manual/"
  ["bazarr"]="/opt/radarr/bazarr/backup/"
  ["jellyfin"]="/opt/jellyfin/config/data/backups/"
  ["immich"]="/twins/photos/backups/"
  ["navidrome"]="/opt/navidrome/data/backup/"
)

### ===== LOG FUNCTION =====
log() {
  echo "$(date '+%F %T') [$1] $2" | tee -a "$LOG_FILE"
}

### ===== ERROR TRAP =====
cleanup_on_failure() {
  log "ERROR" "Backup FAILED — cleaning up partial data"
  rm -rf "$RAW_DIR" "$BACKUP_ROOT/backup_$DATE.tar.zst" 2>/dev/null || true
  # Uncomment if you have a notification webhook:
  # curl -s -o /dev/null "https://your-webhook/backup-failed"
}
trap cleanup_on_failure ERR

### ===== VALIDATION =====
# if [ -z "$PASSWORD" ]; then
#   log "ERROR" "BACKUP_PASS not set"
#   exit 1
# fi

### ===== RETENTION (7 DAYS) =====
find /opt/radarr/bazarr/backup/ -name "bazarr*" -type f -mtime +7 -delete
find /opt/radarr/rdrconfig/Backups/scheduled/ -name "radarr_*" -type f -mtime +7 -delete
find /opt/radarr/prwlrconfig/Backups/scheduled/ -name "prowlarr*" -type f -mtime +7  -delete
cd /opt/jellyfin/config/data/backups && ls -1t | tail -n +2 | xargs -r rm -- && cd -

### ===== RETENTION (60 DAYS RAW | 90 DAYS FINAL) =====
find /root/homelab_svc_backups/ -name "backup*" -type f -mtime +90 -delete
find /root/homelab_svc_backups/raw/ -maxdepth 1 -type d -mtime +60 -delete

### ===== DISK SPACE CHECK =====
REQUIRED_MB=30000
AVAILABLE_MB=$(df --output=avail -BM "$BACKUP_ROOT" | tail -1 | tr -d ' M')
if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
  log "ERROR" "Not enough disk space: ${AVAILABLE_MB}MB available, ${REQUIRED_MB}MB required"
  exit 1
fi
mkdir -p "$RAW_DIR" "$ENC_DIR" "$SNAPSHOT_DIR"
log "INFO" "Backup started"

### ===== FIND PREVIOUS BACKUP FOR HARDLINK DEDUP =====
LATEST_RAW=$(ls -1d "$BACKUP_ROOT/raw"/????-??-??_* 2>/dev/null | sort | tail -1 || true)

### ===== COPY SERVICE BACKUPS (with hardlink dedup) =====
for SERVICE in "${!SERVICES[@]}"; do
  SRC="${SERVICES[$SERVICE]}"
  DEST="$RAW_DIR/$SERVICE"
  if [ -d "$SRC" ]; then
    mkdir -p "$DEST"
    log "INFO" "Copying $SERVICE backups"
    rsync -a --delete "$SRC/" "$DEST/" >> "$LOG_FILE" 2>&1
    # DO NOT delete source backups — let each service manage its own retention
  else
    log "WARN" "$SERVICE path not found: $SRC"
  fi
done

### ===== COPY LOOSE FILES =====
## Copy compose files and prometheus.yml
mkdir -p "$RAW_DIR/compose-files"
(cd /opt && find . -type f \( -name "*compose.yml" -o -name "prometheus.yml" \) -exec cp --parents {} "$RAW_DIR/compose-files/" \; 2>/dev/null) || true

## Copy grafana dashboards
cp /opt/promfana/grafana/dashboard* "$RAW_DIR" 2>/dev/null || true

### ===== COMPRESS =====
ARCHIVE="$BACKUP_ROOT/backup_$DATE.tar.zst"
log "INFO" "Creating archive"
tar --zstd -cf "$ARCHIVE" -C "$BACKUP_ROOT/raw" "$DATE" >> "$LOG_FILE" 2>&1
cp "$ARCHIVE" "$ADD_BACKUP/" >> "$LOG_FILE" 2>&1
### ===== ENCRYPT (password via fd, not CLI arg) =====
# ENC_FILE="$ENC_DIR/backup_$DATE.tar.zst.enc"
# log "INFO" "Encrypting archive"
# openssl enc -aes-256-cbc -pbkdf2 -salt \
#   -in "$ARCHIVE" \
#   -out "$ENC_FILE" \
#   -pass fd:3 3<<< "$PASSWORD" >> "$LOG_FILE" 2>&1
# ### ===== VERIFY ARCHIVE =====
# log "INFO" "Verifying encrypted archive"
# openssl enc -d -aes-256-cbc -pbkdf2 \
#   -in "$ENC_FILE" \
#   -pass fd:3 3<<< "$PASSWORD" 2>/dev/null | tar --zstd -tf - > /dev/null 2>&1
# log "INFO" "Archive verification passed"

### ===== CLEAN TEMP ARCHIVE =====
# rm -f "$ARCHIVE"

### ===== RETENTION (30 DAYS) =====
log "INFO" "Applying retention policy (>30 days)"
find "$BACKUP_ROOT/raw" -mindepth 1 -maxdepth 1 -mtime +30 -exec rm -rf {} \; >> "$LOG_FILE" 2>&1
find "$ENC_DIR" -type f -mtime +30 -delete >> "$LOG_FILE" 2>&1
### ===== DONE =====
log "INFO" "Backup completed successfully: $ARCHIVE"

### Ping healthcheks.io after successfull backup
curl -m 10 --retry 5 https://hc-ping.com/

