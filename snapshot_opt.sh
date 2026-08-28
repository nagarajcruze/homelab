#!/bin/bash

set -euo pipefail

### ===== LOCK FILE — PREVENT CONCURRENT RUNS =====
exec 200>/var/lock/snapshot_opt.lock
flock -n 200 || { echo "$(date '+%F %T') [ERROR] Another snapshot-opt job is already running" | tee -a /var/log/snapshot_opt.log; exit 1; }

### ===== CONFIG =====
SNAPSHOT_DIR="/.snapshots"
RETENTION_DAYS=30
LOG_FILE="/var/log/snapshot_opt.log"
SKIP_BACKUP=false

### ===== REDIRECT ALL OUTPUT TO BOTH TERMINAL AND LOG FILE =====
exec > >(tee -a "$LOG_FILE") 2>&1

### ===== RESTIC & B2 CONFIG (Passed via env / crontab export) =====
RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-}"
B2_ACCOUNT_ID="${AWS_ACCESS_KEY_ID:-}"
B2_ACCOUNT_KEY="${AWS_SECRET_ACCESS_KEY:-}"
SNAP_NAME="$SNAPSHOT_DIR/opt_snapshot_$(date +%F_%H-%M)"

### ===== Healthcheck =====
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"

log() { echo "[$(date '+%F %T')] $*"; }

### Help Commands
# restic snapshots
# # List files in the absolute latest snapshot
# restic ls latest
# # List files inside a specific snapshot ID
# restic ls 3f66ceaf
# # Restore EVERYTHING from the latest snapshot to /tmp/restore
# restic restore latest --target /tmp/restore
# # Restore only a specific file or folder from a specific snapshot ID
# restic restore 3f66ceaf --target /tmp/restore --include /opt/docker/compose.yml
# # manually delete a specific backup:
# restic forget 3f66ceaf --prune
# # Check Repository Health
# restic check
# # Mount the Repository as a Filesystem and use cp/cd to restore
# mkdir -p /mnt/restic
# restic mount /mnt/restic
# # unmount
# restic umount /mnt/restic

### ===== BTRFS SNAPSHOT =====
log "Taking BTRFS snapshot: $SNAP_NAME"
btrfs subvolume snapshot /opt "$SNAP_NAME"
log "Snapshot created successfully"

### ===== RESTIC BACKUP TO BACKBLAZE B2 =====
# Wrapped so that restic failures are logged but don't prevent local cleanup.
B2_FREE_TIER_BYTES=10000000000   # 10 GB (Backblaze uses decimal)
B2_THRESHOLD_PERCENT=80
B2_THRESHOLD_BYTES=$(( B2_FREE_TIER_BYTES * B2_THRESHOLD_PERCENT / 100 ))  # 8 GB

# Returns repo size in bytes, or -1 on failure
get_repo_size() {
    local stats
    if stats=$(restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" stats --mode raw-data --json 2>/dev/null); then
        echo "$stats" | grep -o '"total_size":[0-9]*' | grep -o '[0-9]*'
    else
        echo "-1"
    fi
}

# Returns deduplicated bytes that would be added, or -1 on failure
get_dry_run_size() {
    local output
    if output=$(restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" backup --dry-run --json "$1" 2>/dev/null); then
        # The summary line contains "data_added" with the deduplicated size
        local added
        added=$(echo "$output" | grep '"message_type":"summary"' | grep -o '"data_added":[0-9]*' | grep -o '[0-9]*')
        echo "${added:-0}"
    else
        echo "-1"
    fi
}

log "===================================================================================================="
log "Starting /opt Snapshot Backup Script..."
log "===================================================================================================="

# Validate all required variables and log specific issues if missing
if [ -z "$RESTIC_REPOSITORY" ]; then
    log "ERROR: RESTIC_REPOSITORY is not set"
    exit 1
fi
if [ -z "$RESTIC_PASSWORD_FILE" ]; then
    log "ERROR: RESTIC_PASSWORD_FILE is not set"
    exit 1
elif [ ! -f "$RESTIC_PASSWORD_FILE" ]; then
    log "ERROR: RESTIC_PASSWORD_FILE='$RESTIC_PASSWORD_FILE' does not exist or is not a file"
    exit 1
fi
if [ -z "$B2_ACCOUNT_ID" ]; then
    log "ERROR: B2_ACCOUNT_ID is not set"
    exit 1
fi
if [ -z "$B2_ACCOUNT_KEY" ]; then
    log "ERROR: B2_ACCOUNT_KEY is not set"
    exit 1
fi
if [ -z "$HEALTHCHECK_URL" ]; then
    log "ERROR" "HEALTHCHECK_URL not set"
    exit 1
fi

# Pre-flight size check to avoid exceeding B2 free tier
repo_size=$(get_repo_size)
if [ "$repo_size" -ge 0 ]; then
    log "Current B2 repo size: $(( repo_size / 1024 / 1024 )) MB / $(( B2_THRESHOLD_BYTES / 1024 / 1024 )) MB (80% cap)"
fi

# Step 1: If already over threshold, prune first
if [ "$repo_size" -ge "$B2_THRESHOLD_BYTES" ]; then
    log "WARNING: Repo size exceeds ${B2_THRESHOLD_PERCENT}% of free tier. Pruning first..."
    restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" forget --keep-last 2 --group-by host,tags --tag "opt-snapshot" --prune || true
    repo_size=$(get_repo_size)
    log "Repo size after prune: $(( repo_size / 1024 / 1024 )) MB"
fi

# Step 2: Dry-run to estimate deduplicated upload size
if [ "$repo_size" -ge 0 ]; then
    available_bytes=$(( B2_THRESHOLD_BYTES - repo_size ))
    log "Running dry-run to estimate deduplicated upload size..."
    data_added=$(get_dry_run_size "$SNAP_NAME")

    if [ "$data_added" -lt 0 ]; then
        log "WARNING: Dry-run failed. Proceeding with backup anyway."
    elif [ "$data_added" -gt "$available_bytes" ]; then
        log "CRITICAL: Backup would add $(( data_added / 1024 / 1024 )) MB but only $(( available_bytes / 1024 / 1024 )) MB available (80% cap). SKIPPING backup."
        SKIP_BACKUP=true
    else
        log "Dry-run OK: backup will add ~$(( data_added / 1024 / 1024 )) MB, $(( available_bytes / 1024 / 1024 )) MB available."
    fi
fi

# Step 3: Actual backup
if [ "$SKIP_BACKUP" = false ]; then
    log "Starting Restic backup of $SNAP_NAME to $RESTIC_REPOSITORY"
    PARENT=$(restic snapshots --latest 1 --json | jq -r '.[0].id')
    if [ -n "$PARENT" ] && [ "$PARENT" != "null" ]; then
        if restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" backup "$SNAP_NAME" --parent $PARENT --tag "opt-snapshot"; then
            log "Restic backup completed successfully"
        else
            log "WARNING: Restic backup failed (exit code: $?). Continuing with local cleanup."
        fi
    else
        log "WARNING: No parent snapshot found. Continuing with local cleanup."
    fi

    # Remove old remote snapshots, keeping only the last 2
    if restic -r "$RESTIC_REPOSITORY" --password-file "$RESTIC_PASSWORD_FILE" forget --keep-last 2 --group-by host,tags --tag "opt-snapshot" --prune; then
        log "Restic prune completed successfully"
    else
        log "WARNING: Restic prune failed (exit code: $?). Old snapshots may linger on B2."
    fi
fi

### ===== LOCAL SNAPSHOT CLEANUP =====
log "Cleaning local snapshots older than $RETENTION_DAYS days"

cutoff=$(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d_%H-%M)

find "$SNAPSHOT_DIR" -maxdepth 1 -type d -name 'opt_snapshot_*' -printf '%f\n' |
while read -r snap; do
    ts=${snap#opt_snapshot_}
    if [[ "$ts" < "$cutoff" ]]; then
        log "DELETE: $SNAPSHOT_DIR/$snap"
        btrfs subvolume delete "$SNAPSHOT_DIR/$snap"
    fi
done

### Ping after successful backup
if [ -n "$HEALTHCHECK_URL" ]; then
    curl -sS -m 10 --retry 5 "$HEALTHCHECK_URL" || true
else
    log "WARN" "HEALTHCHECK_URL not set. Skipping healthcheck ping."
fi

### ===== DONE =====
log "Backup completed successfully"