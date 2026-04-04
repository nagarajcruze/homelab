#!/bin/bash

SRC="/mnt/c/Users/nagaraj/Music/My FLACs/"
DEST="root@pve1:/mnt/media/flacs/"

echo "===== DRY RUN (Review changes) ====="
rsync -rtvh --dry-run --size-only --itemize-changes --delete "$SRC" "$DEST" | grep -E "deleting|>f"

echo ""
read -p "Proceed with actual sync? (y/n): " confirm

if [[ "$confirm" == "y" ]]; then
    echo "===== RUNNING RSYNC ====="
    rsync -rtvh --size-only --delete --info=progress2 "$SRC" "$DEST"
else
    echo "Aborted."
fi