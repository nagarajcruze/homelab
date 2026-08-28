#!/bin/bash

SRC="/mnt/c/Users/nagaraj/Music/My FLACs/"
DEST="root@homelab:/mnt/media/flacs/"

#Change folder paths
#sed -i 's#C:\\Users\\nagaraj\\Music\\My FLACs#/music#; s#\\#/#g' "/mnt/c/Users/nagaraj/Music/My FLACs/Playlists/"*.m3u

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