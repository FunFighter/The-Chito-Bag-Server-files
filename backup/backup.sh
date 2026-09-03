#!/usr/bin/env bash
# Snapshot the Chito Bag server state.
#
# Hardlink snapshots, not archives. The world is 250 MB and only compresses to
# 182 MB -- region files are already compressed internally -- so full copies
# every 30 minutes would cost ~26 GB for the three-day window alone. With
# --link-dest, an unchanged region file costs one inode and no blocks, so a
# snapshot costs roughly what actually changed.
#
# Each snapshot is a complete, browsable tree. Restoring is a plain copy; there
# is nothing to unpack and no chain of increments to replay.
set -uo pipefail

DATA_DIR="${DATA_DIR:-/srv/chitobag/data}"
BACKUP_DIR="${BACKUP_DIR:-/srv/chitobag/backups}"
CONTAINER="${CONTAINER:-chitobag-server}"
KEEP_ALL_DAYS="${KEEP_ALL_DAYS:-3}"
DAILY_KEEP_DAYS="${DAILY_KEEP_DAYS:-0}"   # 0 = keep one per day forever
MIN_FREE_GB="${MIN_FREE_GB:-20}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[backup] $*"; }
die() { log "ERROR: $*"; exit 1; }

mkdir -p "$BACKUP_DIR" || die "cannot create $BACKUP_DIR"

# One at a time. A 30-minute timer must never stack runs on a slow disk.
exec 9>"$BACKUP_DIR/.lock"
flock -n 9 || { log "another backup is still running; skipping this slot"; exit 0; }

free_gb=$(df -BG --output=avail "$BACKUP_DIR" | tail -1 | tr -dc '0-9')
[ "${free_gb:-0}" -lt "$MIN_FREE_GB" ] \
    && die "only ${free_gb}G free at $BACKUP_DIR, need ${MIN_FREE_GB}G"

STAMP="$(date +%Y-%m-%d_%H%M)"
DEST="$BACKUP_DIR/$STAMP"
[ -e "$DEST" ] && { log "$STAMP already exists; skipping"; exit 0; }

running=false
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; then
    running=true
fi

# save-off must ALWAYS be undone. If it is not, the server silently stops
# writing to disk and every later backup captures the same stale world -- the
# worst possible failure for a backup system, because it looks like it works.
restore_saving() {
    if [ "$running" = true ]; then
        if docker exec "$CONTAINER" mc-cmd "save-on" >/dev/null 2>&1; then
            log "saving re-enabled"
        else
            log "CRITICAL: could not re-enable saving. Run this now:"
            log "  docker exec $CONTAINER mc-cmd save-on"
        fi
    fi
}
trap restore_saving EXIT INT TERM

if [ "$running" = true ]; then
    # Flush to disk and hold writes, so the snapshot is a consistent moment
    # rather than a smear across an autosave.
    docker exec "$CONTAINER" mc-cmd "save-off" >/dev/null 2>&1 \
        || log "warning: save-off failed; continuing with a live world"
    docker exec "$CONTAINER" mc-cmd "save-all flush" >/dev/null 2>&1 \
        || log "warning: save-all flush failed"
    sleep 3
else
    log "server is not running; snapshotting the world at rest"
fi

# Newest existing snapshot becomes the hardlink base.
LINK_DEST=""
prev="$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
        -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$' \
        -printf '%f\n' 2>/dev/null | sort | tail -1)"
[ -n "$prev" ] && LINK_DEST="--link-dest=$BACKUP_DIR/$prev"

# Written to .partial first, so an interrupted run never leaves a snapshot that
# looks complete. Excludes are things rebuilt from the image or regenerated.
rsync -a --delete \
    --exclude='mods/' \
    --exclude='libraries' \
    --exclude='logs/' \
    --exclude='.mixin.out/' \
    --exclude='dynamic-data-pack-cache/' \
    --exclude='.rcon_password' \
    $LINK_DEST \
    "$DATA_DIR/" "$DEST.partial/"
rc=$?
[ $rc -ne 0 ] && [ $rc -ne 24 ] && { rm -rf "$DEST.partial"; die "rsync failed ($rc)"; }

mv "$DEST.partial" "$DEST" || die "could not finalise $DEST"

restore_saving
trap - EXIT INT TERM

ln -sfn "$DEST" "$BACKUP_DIR/latest"

# level.dat is the file a restore cannot do without; if it is missing the
# snapshot is not a backup.
[ -s "$DEST/world/level.dat" ] || log "WARNING: $STAMP has no world/level.dat"

size="$(du -sh "$DEST" 2>/dev/null | cut -f1)"
log "$STAMP done (tree $size)"

python3 "$HERE/prune.py" "$BACKUP_DIR" \
    --keep-all-days "$KEEP_ALL_DAYS" \
    --daily-keep-days "$DAILY_KEEP_DAYS" 2>&1 | sed 's/^/[backup] /'

total="$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)"
count="$(find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d \
         -regextype posix-extended -regex '.*/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4}$' | wc -l)"
log "$count snapshots, $total on disk, $(df -BG --output=avail "$BACKUP_DIR" | tail -1 | tr -d ' ') free"
