#!/bin/bash

set -euo pipefail

SNAPSHOT_DIR="/.snapshots"
RETENTION_DAYS=7
SNAP_NAME="$SNAPSHOT_DIR/opt_snapshot_$(date +%F_%H-%M)"

echo "[$(date '+%F %T')] Taking BTRFS snapshot: $SNAP_NAME"

btrfs subvolume snapshot /opt "$SNAP_NAME"

echo "[$(date '+%F %T')] Cleaning snapshots older than $RETENTION_DAYS days"

cutoff=$(date -d "$RETENTION_DAYS days ago" +%Y-%m-%d_%H-%M)

find /.snapshots -maxdepth 1 -type d -name 'opt_snapshot_*' -printf '%f\n' |
while read -r snap; do
    ts=${snap#opt_snapshot_}
    if [[ "$ts" < "$cutoff" ]]; then
        echo "DELETE: /.snapshots/$snap"
        btrfs subvolume delete "/.snapshots/$snap"
    fi
done