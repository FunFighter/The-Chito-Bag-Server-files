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

## Adding a mod

```bash
tools/add-mod.py https://www.curseforge.com/minecraft/mc-mods/<slug>
git commit -am "Add <mod>" && git push
```

That is the whole flow. The push triggers the deploy workflow, which rebuilds
the image on the runner, restarts the server and waits for it to report healthy.

The script finds the newest file matching the pack's Minecraft version and
loader, appends it to `manifest.json`, and — if CurseForge tags the mod
Client — also lists it in `docker/client_only.txt` so it is kept out of the
server image. Nothing else needs editing.

```bash
tools/add-mod.py <slug> --dry-run           # show what would change
tools/add-mod.py <slug> --file-id 1234567   # pin an exact file
tools/add-mod.py 429235                     # by project ID
```

A slug that returns 404 just means cfwidget has not indexed it; pass the numeric
**Project ID** from the mod's CurseForge page instead. Re-running for a mod
already in the pack repins its file, so this is also how you upgrade one.

To check before pushing:

```bash
docker compose build && docker compose up -d
```

### Clients need updating too

Server and client are not the same mod set. `manifest.json` is the *client* pack
as well, so anyone importing it gets the client-only mods too. Regenerate the
pack zip from `manifest.json` after adding a mod, or players will be missing it.

## Changing the pack by hand

Edit `manifest.json` (or `overrides/`), then `docker compose up -d --build`.
The entrypoint reconciles `/data/mods` against the new image on the next start.

To exclude a mod from the server only — client-only mods crash a dedicated
server — add its CurseForge project ID to [docker/client_only.txt](docker/client_only.txt).

## Memory

`MC_XMX` defaults to `auto`, which derives the heap from the container's own
cgroup limit at startup and leaves the larger of 3 GB or 15% for non-heap use
(metaspace for ~190 mods, code cache, G1 structures, netty buffers). On the
26 GB limit in use on `wonton` that comes out at 22 GB. `MC_XMS` follows
`MC_XMX`, since Aikar's G1 flags assume a fixed heap.

Set `MC_XMX` explicitly to override. Keep the container limit meaningfully
above the heap — the JVM also needs
metaspace, GC structures and direct buffers, and a container OOM-kill is an
unclean stop.
