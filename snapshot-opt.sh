#!/bin/bash

set -euo pipefail

SNAPSHOT_DIR="/.snapshots"
RETENTION_DAYS=5
SNAP_NAME="$SNAPSHOT_DIR/opt_snapshot_$(date +%F_%H-%M)"


echo "[$(date '+%F %T')] Taking BTRFS snapshot: $SNAP_NAME"

btrfs subvolume snapshot /opt "$SNAP_NAME"

echo "[$(date '+%F %T')] Cleaning snapshots older than $RETENTION_DAYS days"

find "$SNAPSHOT_DIR" \
    -maxdepth 1 \
    -name "opt_snapshot_*" \
    -type d \
    -mtime +${RETENTION_DAYS} \
    -print0 |
while IFS= read -r -d '' snap; do
    btrfs subvolume delete "$snap"
done