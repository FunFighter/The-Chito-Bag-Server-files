# syntax=docker/dockerfile:1.7
#
# The Chito Bag Server -- Minecraft 1.21.1 / NeoForge
#
# Three stages so mod downloads and the NeoForge install cache independently:
#   neoforge -> runs the official installer, produces libraries/ + run scripts
#   mods     -> downloads every file in manifest.json from CurseForge
#   runtime  -> JRE + the two above, immutable; all mutable state lives in /data
#
# Mods are NOT committed to the repo -- they are fetched at build time, so the
# image is reproducible from manifest.json alone and no jars are redistributed.

ARG NEOFORGE_VERSION=21.1.248
ARG JAVA_VERSION=21

# ---------------------------------------------------------------- neoforge --
FROM eclipse-temurin:${JAVA_VERSION}-jdk AS neoforge
ARG NEOFORGE_VERSION
WORKDIR /build
RUN set -eux; \
    curl -fsSL -o installer.jar \
      "https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/neoforge-${NEOFORGE_VERSION}-installer.jar"; \
    java -jar installer.jar --installServer /build/server > /build/install.log 2>&1 \
      || { tail -50 /build/install.log; exit 1; }; \
    rm -f installer.jar /build/server/*.log; \
    test -d /build/server/libraries

# -------------------------------------------------------------------- mods --
FROM python:3.12-slim AS mods
WORKDIR /build
COPY manifest.json /build/manifest.json
COPY docker/fetch_mods.py docker/client_only.txt /build/docker/
# CF_API_KEY is optional. With it the official CurseForge API is used; without
# it the public download endpoint. Passed as a build secret so it never lands
# in image history:  docker build --secret id=cf_api_key,env=CF_API_KEY
RUN --mount=type=secret,id=cf_api_key,required=false \
    set -eux; \
    if [ -f /run/secrets/cf_api_key ]; then export CF_API_KEY="$(cat /run/secrets/cf_api_key)"; fi; \
    python3 /build/docker/fetch_mods.py /build/manifest.json /build/out

# ----------------------------------------------------------------- runtime --
FROM eclipse-temurin:${JAVA_VERSION}-jre AS runtime
ARG NEOFORGE_VERSION
ENV NEOFORGE_VERSION=${NEOFORGE_VERSION} \
    MC_HOME=/opt/chitobag \
    DATA_DIR=/data \
    MC_XMS= \
    MC_XMX=auto \
    EULA=false

# gosu drops root to the runtime uid so files on the mounted drive stay owned
# by a real user rather than root.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gosu tini python3-minimal; \
    rm -rf /var/lib/apt/lists/*; \
    # Recent Ubuntu bases ship a stock 'ubuntu' account already holding
    # uid/gid 1000, which is the id we want for the mounted drive.
    if getent passwd ubuntu >/dev/null; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi; \
    if getent group ubuntu >/dev/null; then groupdel ubuntu || true; fi; \
    groupadd -r minecraft --gid 1000; \
    useradd -r -g minecraft --uid 1000 --home-dir /data --shell /usr/sbin/nologin minecraft

COPY --from=neoforge /build/server/libraries      ${MC_HOME}/libraries
COPY --from=neoforge /build/server/user_jvm_args.txt ${MC_HOME}/user_jvm_args.txt.default
COPY --from=mods     /build/out/mods              ${MC_HOME}/mods
COPY --from=mods     /build/out/datapacks         ${MC_HOME}/datapacks
COPY --from=mods     /build/out/mods.list         ${MC_HOME}/mods.list
# Pack configs ship as defaults; the entrypoint seeds them into /data once and
# never overwrites an admin's edits afterwards.
COPY overrides/config                             ${MC_HOME}/defaults/config
# Server list icon, seeded into /data on first run.
COPY overrides/server-icon.png                    ${MC_HOME}/defaults/server-icon.png
# Any jar in overrides/mods (pack-local mods not on CurseForge).
COPY overrides/mods                               ${MC_HOME}/override-mods
COPY docker/entrypoint.sh                         /usr/local/bin/entrypoint.sh
COPY docker/rcon.py                               /usr/local/bin/rcon.py

RUN set -eux; \
    chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/rcon.py; \
    # `docker exec chitobag-server mc-cmd "say hello"` for admin commands.
    printf '#!/bin/sh\nexec /usr/local/bin/rcon.py "$@"\n' > /usr/local/bin/mc-cmd; \
    chmod +x /usr/local/bin/mc-cmd; \
    # Fold overrides/mods into the image mod set and record the final list.
    if ls ${MC_HOME}/override-mods/*.jar >/dev/null 2>&1; then \
        cp -a ${MC_HOME}/override-mods/*.jar ${MC_HOME}/mods/; \
    fi; \
    rm -rf ${MC_HOME}/override-mods; \
    ls -1 ${MC_HOME}/mods > ${MC_HOME}/mods.list; \
    echo "$(wc -l < ${MC_HOME}/mods.list) mods in image"

WORKDIR /data
EXPOSE 25565/tcp
VOLUME ["/data"]

# tini reaps zombies; entrypoint execs the JVM as PID 1 of its group so a
# SIGTERM from `docker stop` reaches Minecraft's shutdown hook and saves.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
