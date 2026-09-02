# Running the pack in Docker

```bash
cp .env.example .env      # set MC_DATA_DIR to a path on your drive, EULA=true
docker compose up -d --build
docker compose logs -f
```

First build takes ~4 minutes (it downloads all 195 pack files from CurseForge).
First boot generates every dimension; later boots take a few seconds.

## How it is split

The image is immutable and holds the pack: 192 mod jars, the NeoForge 21.1.248
libraries, and the pack configs as *defaults*. Everything mutable lives on the
drive you mount at `/data` — world, logs, player data, `server.properties`, the
live configs, and the mods themselves.

Mods are **not** committed to this repo. The build downloads them from
`manifest.json`, so nothing is redistributed and the repo stays small.

On every start the entrypoint:

- copies in mod jars that are new and deletes ones the previous image had and
  this one does not — jars you added by hand are left alone;
- seeds config files that are **missing**, never overwriting your edits;
- drops the 4 pack datapacks into `world/datapacks/` if absent;
- rewrites `user_jvm_args.txt` from `MC_XMS`/`MC_XMX`.

So `MC_DATA_DIR` survives rebuilds, and changing a config on the drive sticks.

## Ports

| Port | Proto | What |
|---|---|---|
| `MC_PORT` (25565) | TCP | Minecraft |
| `MC_VOICE_PORT` (24454) | UDP | Simple Voice Chat |
| 25575 | TCP | RCON — deliberately **not** published; container-internal only |

Simple Voice Chat is in this pack and needs its own UDP port opened on the
router/firewall. Without it players connect normally and voice just silently
never works.

## Admin commands

```bash
docker exec chitobag-server mc-cmd "say hello"
docker exec chitobag-server mc-cmd "op SomePlayer"
docker attach chitobag-server        # live console, Ctrl-P Ctrl-Q to detach
```

## Stopping safely

`docker compose stop` is safe. This matters more than usual here:

**Minecraft does not save on SIGTERM.** Tested on this pack — the JVM exits in
about 2 seconds and the world save never runs. So the entrypoint traps SIGTERM
and issues a real `stop` over RCON instead, then waits for the JVM. A verified
shutdown logs `All dimensions are saved` and exits 0.

`stop_grace_period` is 180s and `MC_STOP_TIMEOUT` 120s because this pack's
AllTheLeaks reports stuck threads at shutdown; the save completes first, then
the entrypoint escalates if the JVM lingers.

Never `docker kill` the container, and do not lower `stop_grace_period`.

## Changing the pack

Edit `manifest.json` (or `overrides/`), then `docker compose up -d --build`.
The entrypoint reconciles `/data/mods` against the new image on the next start.

To exclude a mod from the server only — client-only mods crash a dedicated
server — add its CurseForge project ID to [docker/client_only.txt](docker/client_only.txt).
Smooth Swapping is already listed.

## Memory

`MC_XMX` defaults to 10G (what the manifest recommends) and `MC_MEM_LIMIT` to
13g. Keep the container limit meaningfully above the heap — the JVM also needs
metaspace, GC structures and direct buffers, and a container OOM-kill is an
unclean stop.
