#!/usr/bin/env bash
# Mirror the local backup snapshots to a second machine.
#
# The local snapshots live on the same NVMe as the world, so they protect
# against a bad command, a corrupted chunk or griefing -- but not against that
# disk failing. This is the copy that survives the disk.
#
# rsync -H is what makes it affordable: without it, every hardlink in the
# snapshot tree is sent as a separate full copy and a ~12 GB backup set
# balloons to ~100 GB on the far end.
set -uo pipefail

CONF="${CONF:-/srv/chitobag/offsite.env}"
[ -r "$CONF" ] && . "$CONF"

BACKUP_DIR="${BACKUP_DIR:-/srv/chitobag/backups}"
OFFSITE_HOST="${OFFSITE_HOST:-}"
OFFSITE_USER="${OFFSITE_USER:-}"
OFFSITE_PATH="${OFFSITE_PATH:-}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"

log() { echo "[offsite] $*"; }

[ -n "$OFFSITE_HOST" ] && [ -n "$OFFSITE_USER" ] && [ -n "$OFFSITE_PATH" ] || {
    log "not configured; set OFFSITE_HOST/USER/PATH in $CONF"; exit 0; }

exec 9>"$BACKUP_DIR/.offsite.lock"
flock -n 9 || { log "previous sync still running; skipping this slot"; exit 0; }

TARGET="$OFFSITE_USER@$OFFSITE_HOST"

# Preflight. The destination is a machine someone else runs, so it being down
# is an expected state, not an incident -- exit 0 so the timer does not fill
# the journal with failures for something that will fix itself.
if ! timeout 15 ssh $SSH_OPTS "$TARGET" true 2>/dev/null; then
    log "cannot reach $TARGET over ssh yet -- skipping."
    log "on that machine:  sudo systemctl enable --now sshd"
    log "then authorise:   $(cat ~/.ssh/id_ed25519.pub 2>/dev/null | cut -c1-60)..."
    exit 0
fi

ssh $SSH_OPTS "$TARGET" "mkdir -p '$OFFSITE_PATH'" 2>/dev/null \
    || { log "cannot create $OFFSITE_PATH on $TARGET"; exit 1; }

log "syncing $BACKUP_DIR -> $TARGET:$OFFSITE_PATH"
start=$(date +%s)

# --delete mirrors the retention policy outward, so the far end does not grow
# without bound. That does mean it is a mirror, not an archive: a local prune
# propagates. It protects against hardware loss, not against a bad prune.
rsync -aH --delete --numeric-ids --partial \
      --exclude='.lock' --exclude='.offsite.lock' --exclude='*.partial' \
      -e "ssh $SSH_OPTS" \
      "$BACKUP_DIR/" "$TARGET:$OFFSITE_PATH/"
rc=$?

if [ $rc -ne 0 ] && [ $rc -ne 24 ]; then
    log "ERROR: rsync failed ($rc)"
    exit 1
fi

remote_count=$(ssh $SSH_OPTS "$TARGET" \
    "find '$OFFSITE_PATH' -maxdepth 1 -mindepth 1 -type d -name '20*' | wc -l" 2>/dev/null)
remote_size=$(ssh $SSH_OPTS "$TARGET" "du -sh '$OFFSITE_PATH' 2>/dev/null | cut -f1" 2>/dev/null)

log "done in $(( $(date +%s) - start ))s: ${remote_count:-?} snapshots, ${remote_size:-?} on $OFFSITE_HOST"
