#!/usr/bin/env bash
# Seeds /data from the image, then hands off to the JVM as PID 1.
#
# Ownership model: everything the server can change lives in /data (the mounted
# drive). Everything from the pack build lives in $MC_HOME (immutable, in the
# image). Mods are synced by difference so admin-added jars in /data/mods
# survive, while jars dropped from the pack are removed on the next start.
set -euo pipefail

MC_HOME="${MC_HOME:-/opt/chitobag}"
DATA_DIR="${DATA_DIR:-/data}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log() { echo "[entrypoint] $*"; }

# Without this a `set -e` abort is silent -- the container just exits with a
# bare status and no indication of where it stopped.
trap 'rc=$?; log "ERROR: aborted at line $LINENO with status $rc"; exit $rc' ERR

# --------------------------------------------------------------- ownership --
# Match the container user to the drive's owner so bind mounts stay writable
# from the host without root-owned files appearing on it.
if [ "$(id -u)" = "0" ]; then
    current_gid="$(getent group minecraft | cut -d: -f3)"
    current_uid="$(id -u minecraft)"
    [ "$PGID" != "$current_gid" ] && groupmod -o -g "$PGID" minecraft
    [ "$PUID" != "$current_uid" ] && usermod  -o -u "$PUID" minecraft
fi

mkdir -p "$DATA_DIR"/{mods,config,logs,world/datapacks}

# ------------------------------------------------------------------- eula --
# Minecraft refuses to start without this. It is a deliberate, explicit opt-in:
# set EULA=true in .env only if you accept https://aka.ms/MinecraftEULA
if [ "${EULA:-false}" = "true" ] || [ "${EULA:-false}" = "TRUE" ] || [ "${EULA:-false}" = "True" ]; then
    echo "eula=true" > "$DATA_DIR/eula.txt"
else
    echo "eula=false" > "$DATA_DIR/eula.txt"
    log "ERROR: EULA not accepted. Set EULA=true in your .env to run the server."
    log "       (https://aka.ms/MinecraftEULA)"
    exit 1
fi

# ------------------------------------------------------------------- mods --
# Copy in jars that are new, delete jars that the previous image had and this
# one does not, leave anything the admin added alone.
prev_list="$DATA_DIR/.mods.list"
new_list="$MC_HOME/mods.list"
added=0 removed=0

if [ -f "$prev_list" ]; then
    while IFS= read -r jar; do
        [ -z "$jar" ] && continue
        if ! grep -qxF "$jar" "$new_list" && [ -f "$DATA_DIR/mods/$jar" ]; then
            rm -f "$DATA_DIR/mods/$jar"; removed=$((removed+1))
        fi
    done < "$prev_list"
fi

while IFS= read -r jar; do
    [ -z "$jar" ] && continue
    if [ ! -f "$DATA_DIR/mods/$jar" ]; then
        cp -a "$MC_HOME/mods/$jar" "$DATA_DIR/mods/$jar"; added=$((added+1))
    fi
done < "$new_list"

cp -a "$new_list" "$prev_list"
log "mods: $(ls -1 "$DATA_DIR/mods" | wc -l) present (+${added} new, -${removed} dropped)"

# --------------------------------------------------------------- datapacks --
# Manifest .zip datapacks are per-world; Minecraft auto-enables new ones.
if [ -d "$MC_HOME/datapacks" ]; then
    for dp in "$MC_HOME"/datapacks/*.zip; do
        [ -e "$dp" ] || continue
        [ -f "$DATA_DIR/world/datapacks/$(basename "$dp")" ] || cp -a "$dp" "$DATA_DIR/world/datapacks/"
    done
    log "datapacks: $(ls -1 "$DATA_DIR/world/datapacks" 2>/dev/null | wc -l) present"
fi

# ----------------------------------------------------------------- configs --
# Seed only what is missing -- never clobber an edited config.
seeded=0
while IFS= read -r -d '' src; do
    rel="${src#"$MC_HOME/defaults/config/"}"
    dst="$DATA_DIR/config/$rel"
    if [ ! -e "$dst" ]; then
        mkdir -p "$(dirname "$dst")"; cp -a "$src" "$dst"; seeded=$((seeded+1))
    fi
done < <(find "$MC_HOME/defaults/config" -type f -print0)
log "config: seeded $seeded new file(s)"

# ------------------------------------------------------- server.properties --
if [ ! -f "$DATA_DIR/server.properties" ]; then
    cat > "$DATA_DIR/server.properties" <<PROPS
motd=${MC_MOTD:-The Chito Bag Server}
level-name=world
server-port=25565
online-mode=${MC_ONLINE_MODE:-true}
max-players=${MC_MAX_PLAYERS:-20}
view-distance=${MC_VIEW_DISTANCE:-8}
simulation-distance=${MC_SIMULATION_DISTANCE:-6}
allow-flight=true
enforce-secure-profile=false
sync-chunk-writes=false
max-tick-time=180000
PROPS
    log "server.properties: created from defaults"
fi

# ---------------------------------------------------------------- jvm args --
# Written fresh each start so MC_XMS/MC_XMX/MC_BG_THREADS in .env stay
# authoritative. Aikar's G1 tuning has two variants and the cutoff is 12 GB:
# above it, larger regions and a bigger young gen avoid long mixed collections.
heap_mb() {
    v="${1^^}"
    case "$v" in
        *G) echo $(( ${v%G} * 1024 )) ;;
        *M) echo "${v%M}" ;;
        *)  echo "$v" ;;
    esac
}

# Derive a heap from the container's own memory limit. A fixed default is
# always wrong: too small and most of the container sits unused, too large and
# the cgroup OOM-kills the JVM, which is an unclean stop and risks the world.
autosize_heap_mb() {
    local raw="" limit_mb headroom_mb heap_mb
    # cgroup v2 first, then v1.
    if [ -r /sys/fs/cgroup/memory.max ]; then
        raw="$(cat /sys/fs/cgroup/memory.max)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        raw="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
    fi
    # "max", empty, or an absurd number all mean "no limit set".
    case "$raw" in
        ''|max|*[!0-9]*) echo ""; return ;;
    esac
    [ "$raw" -gt 1152921504606846976 ] 2>/dev/null && { echo ""; return; }

    limit_mb=$(( raw / 1048576 ))
    # Measured on this pack: non-heap usage (metaspace for ~190 mods, code
    # cache, G1 structures, netty direct buffers) runs 1.7-2.7 GiB. 15% or 3
    # GiB, whichever is larger, keeps a real margin at every size.
    headroom_mb=$(( limit_mb * 15 / 100 ))
    [ "$headroom_mb" -lt 3072 ] && headroom_mb=3072
    heap_mb=$(( limit_mb - headroom_mb ))
    # Round down to a whole 512 MB so the flag reads tidily.
    heap_mb=$(( heap_mb / 512 * 512 ))
    [ "$heap_mb" -lt 2048 ] && heap_mb=2048
    echo "$heap_mb"
}

# MC_XMX=auto (or unset) sizes the heap from the container limit.
if [ -z "${MC_XMX:-}" ] || [ "${MC_XMX,,}" = "auto" ]; then
    AUTO_MB="$(autosize_heap_mb)"
    if [ -n "$AUTO_MB" ]; then
        MC_XMX="${AUTO_MB}M"
        log "heap auto-sized to ${AUTO_MB}M from the container memory limit"
        # Non-heap usage is dominated by metaspace for ~190 mods and barely
        # shrinks, so a small limit starves the heap rather than the overhead.
        if [ "$AUTO_MB" -lt 4096 ]; then
            log "WARNING: only ${AUTO_MB}M left for the heap. This pack needs a"
            log "         container limit of at least 12g to run comfortably;"
            log "         raise MC_MEM_LIMIT or set MC_XMX explicitly."
        fi
    else
        MC_XMX="4G"
        log "no container memory limit found; defaulting heap to ${MC_XMX}"
    fi
fi
# Xms defaults to Xmx: a dedicated server gains nothing from growing the heap
# at runtime, and AlwaysPreTouch commits it up front anyway.
: "${MC_XMS:=$MC_XMX}"

XMX_MB="$(heap_mb "$MC_XMX")"

if [ "$XMX_MB" -ge 12288 ]; then
    G1_NEW=40; G1_MAX_NEW=50; G1_REGION=16M; G1_RESERVE=15; G1_IHOP=20
    log "large-heap G1 tuning (${MC_XMX} >= 12G)"
else
    G1_NEW=30; G1_MAX_NEW=40; G1_REGION=8M;  G1_RESERVE=20; G1_IHOP=15
fi

{
    echo "-Xms${MC_XMS}"
    echo "-Xmx${MC_XMX}"
    echo "-XX:+UseG1GC"
    echo "-XX:+ParallelRefProcEnabled"
    echo "-XX:MaxGCPauseMillis=200"
    echo "-XX:+UnlockExperimentalVMOptions"
    echo "-XX:+DisableExplicitGC"
    echo "-XX:+AlwaysPreTouch"
    echo "-XX:G1NewSizePercent=${G1_NEW}"
    echo "-XX:G1MaxNewSizePercent=${G1_MAX_NEW}"
    echo "-XX:G1HeapRegionSize=${G1_REGION}"
    echo "-XX:G1ReservePercent=${G1_RESERVE}"
    echo "-XX:G1HeapWastePercent=5"
    echo "-XX:G1MixedGCCountTarget=4"
    echo "-XX:InitiatingHeapOccupancyPercent=${G1_IHOP}"
    echo "-XX:G1MixedGCLiveThresholdPercent=90"
    echo "-XX:G1RSetUpdatingPauseTimePercent=5"
    echo "-XX:SurvivorRatio=32"
    echo "-XX:+PerfDisableSharedMem"
    echo "-XX:MaxTenuringThreshold=1"
    if [ -n "${MC_BG_THREADS:-}" ]; then
        # Minecraft's Util.backgroundExecutor pool -- chunk gen, I/O, worldgen.
        # Defaults to cores-1; pin it so a CPU limit and the pool agree.
        echo "-Dmax.bg.threads=${MC_BG_THREADS}"
        # Keep the JVM's own pools (GC, ForkJoin) sized to the same budget.
        echo "-XX:ActiveProcessorCount=${MC_BG_THREADS}"
    fi
} > "$DATA_DIR/user_jvm_args.txt"

# NeoForge's generated arg file references libraries/ relative to the game dir.
ln -sfn "$MC_HOME/libraries" "$DATA_DIR/libraries"

if [ "$(id -u)" = "0" ]; then
    chown -R "$PUID:$PGID" "$DATA_DIR" 2>/dev/null || true
fi

# -------------------------------------------------------------------- rcon --
# SIGTERM does NOT make Minecraft save -- verified: the JVM exits in ~2s with no
# "Saving worlds" in the log. A console `stop` is the only dependable shutdown,
# and RCON is the supported way to issue one. The port is never published in
# docker-compose.yml, so it is reachable only from inside the container.
RCON_PORT="${RCON_PORT:-25575}"
PASSWORD_FILE="$DATA_DIR/.rcon_password"
if [ -n "${RCON_PASSWORD:-}" ]; then
    printf '%s' "$RCON_PASSWORD" > "$PASSWORD_FILE"
elif [ ! -s "$PASSWORD_FILE" ]; then
    # Random per-deployment secret; nothing outside the container can reach it.
    # Order matters: `head` must come FIRST. Written the other way round --
    # `tr -dc ... < /dev/urandom | head -c 32` -- head exits after 32 bytes, tr
    # dies of SIGPIPE, and pipefail turns that into a 141 that kills the
    # entrypoint before the JVM ever starts. Every stage below reads to EOF.
    # (python3 here is python3-minimal, which has no `secrets` module.)
    head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-32 > "$PASSWORD_FILE"
fi
chmod 600 "$PASSWORD_FILE"
RCON_PASSWORD="$(cat "$PASSWORD_FILE")"
export RCON_PASSWORD RCON_PORT

# These three keys are infrastructure, not preference -- re-assert them every
# boot so an edited server.properties cannot break graceful shutdown.
python3 - "$DATA_DIR/server.properties" "$RCON_PORT" "$RCON_PASSWORD" <<'PY'
import sys
path, port, password = sys.argv[1], sys.argv[2], sys.argv[3]
forced = {"enable-rcon": "true", "rcon.port": port, "rcon.password": password}
try:
    lines = open(path).read().splitlines()
except FileNotFoundError:
    lines = []
kept = [l for l in lines if l.split("=", 1)[0].strip() not in forced]
kept += [f"{k}={v}" for k, v in forced.items()]
open(path, "w").write("\n".join(kept) + "\n")
PY

if [ "$(id -u)" = "0" ]; then
    chown "$PUID:$PGID" "$PASSWORD_FILE" "$DATA_DIR/server.properties" 2>/dev/null || true
fi

log "starting NeoForge ${NEOFORGE_VERSION} (heap ${MC_XMS}-${MC_XMX})"

ARGFILE="$MC_HOME/libraries/net/neoforged/neoforge/${NEOFORGE_VERSION}/unix_args.txt"
[ -f "$ARGFILE" ] || { log "ERROR: missing $ARGFILE"; exit 1; }

# stdin is inherited straight from the container, so `docker attach` still gives
# you a working server console.
if [ "$(id -u)" = "0" ]; then
    gosu minecraft java "@$DATA_DIR/user_jvm_args.txt" "@$ARGFILE" nogui "$@" &
else
    java "@$DATA_DIR/user_jvm_args.txt" "@$ARGFILE" nogui "$@" &
fi
JAVA_PID=$!

STOPPING=0
on_term() {
    if [ "$STOPPING" = "1" ]; then return 0; fi
    STOPPING=1
    log "shutdown requested -- issuing 'stop' over RCON"
    if ! /usr/local/bin/rcon.py stop; then
        log "RCON stop failed; falling back to SIGTERM (the world may not save)"
        kill -TERM "$JAVA_PID" 2>/dev/null || true
    fi
    (
        # This pack logs "server is stuck while trying to close" from AllTheLeaks,
        # so escalate rather than sit until Docker's SIGKILL.
        sleep "${MC_STOP_TIMEOUT:-120}"
        if kill -0 "$JAVA_PID" 2>/dev/null; then
            log "stop did not finish in ${MC_STOP_TIMEOUT:-120}s -- SIGTERM to the JVM"
            kill -TERM "$JAVA_PID" 2>/dev/null || true
            sleep 20
            kill -KILL "$JAVA_PID" 2>/dev/null || true
        fi
    ) &
}
trap on_term TERM INT

# `wait` returns >128 when a trap interrupts it; keep waiting for the real exit
# so the container outlives the world save.
rc=0; wait "$JAVA_PID" || rc=$?
while [ "$rc" -gt 128 ] && kill -0 "$JAVA_PID" 2>/dev/null; do
    rc=0; wait "$JAVA_PID" || rc=$?
done

log "server exited with code $rc"
exit "$rc"
