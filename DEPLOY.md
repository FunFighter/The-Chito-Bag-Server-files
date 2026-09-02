# Deploying to the local physical server

## Short answer

**Yes, GitHub Actions is free for this — but only with a self-hosted runner on the
server itself.** Do not build on GitHub-hosted runners and push an image.

GitHub does not meter self-hosted runner minutes at all, on any plan, public or
private. The hosted-runner route is what runs into limits:

| | GitHub-hosted + GHCR | Self-hosted runner |
|---|---|---|
| Minutes (private repo, Free plan) | 2,000/mo — a ~10 min build 3×/week ≈ 120 min, fits, but shares the pool with everything else | unmetered |
| Package storage (Free plan, private) | **500 MB** — this image is ~2 GB, so it does not fit | none needed |
| Reaching a home server behind NAT | needs exposed SSH, a tunnel, or a pull agent | not applicable, it *is* the server |
| Transfer per deploy | ~2 GB pull over your home connection | 0 |
| Mod redistribution | making the repo/package public to dodge storage limits would republish ~193 CurseForge jars, which their licences and ToS do not allow | jars never leave the machine |

That last row is the one that actually settles it. The only way to get free
unlimited GHCR storage is a public package, and a public package here would mean
redistributing other people's mods. A self-hosted runner sidesteps the whole
question: the image is built and consumed on the same box and never published.

## Set up the self-hosted runner

> **Only attach a self-hosted runner to a private repo.** On a public repo,
> anyone can open a pull request that executes arbitrary code on your machine.

1. Push this repo to GitHub as **private**.

2. On the server: *Repo → Settings → Actions → Runners → New self-hosted runner*
   and follow the shown commands. Then give it the label the workflow expects:

   ```bash
   cd ~/actions-runner
   ./config.sh --url https://github.com/<you>/<repo> --token <TOKEN> \
               --labels chitobag --name chitobag-host --unattended
   sudo ./svc.sh install
   sudo ./svc.sh start
   ```

3. The runner user needs Docker access and a checkout that already has `.env`:

   ```bash
   sudo usermod -aG docker "$USER"     # log out and back in
   cp .env.example .env                # then edit it -- see below
   ```

   `.env` is intentionally *not* in git (it holds host-specific paths). The
   workflow fails fast with a clear message if it is missing.

4. Push to `main`, or run the workflow manually from the Actions tab.

[.github/workflows/deploy.yml](.github/workflows/deploy.yml) checks the drive is
mounted, builds, warns players over the console, restarts, and waits for the
healthcheck before reporting success.

## Alternative: no runner at all

If you would rather not run a runner daemon, a pull-based timer is the simplest
thing that works and has no moving parts beyond systemd:

```ini
# /etc/systemd/system/chitobag-deploy.service
[Service]
Type=oneshot
WorkingDirectory=/srv/chitobag
ExecStart=/bin/bash -c 'git pull --ff-only && docker compose up -d --build'
```

```ini
# /etc/systemd/system/chitobag-deploy.timer
[Timer]
OnCalendar=*:0/15
[Install]
WantedBy=timers.target
```

`systemctl enable --now chitobag-deploy.timer`. You trade the Actions UI and
push-triggered deploys for up to 15 minutes of lag and no build logs in a
browser. Nothing inbound is exposed either way.

**Gitea / Forgejo Actions** is the third option if you want to leave GitHub
entirely — it runs the same workflow YAML with its own runner, fully self-hosted
and free, but you are then also operating the forge.

## What I would pick

Self-hosted GitHub Actions runner. It is free with no asterisks for a private
repo, keeps the 2 GB image local, gives you real build logs and a deploy history,
and the workflow already guards the two things that actually break a Minecraft
deploy — an unmounted drive and a restart that does not wait for the world save.

## This deployment (wonton, 192.168.50.10)

| | |
|---|---|
| Host | `wonton`, CachyOS, Ryzen 9 7945HX3D (32 threads), 30 GB RAM |
| Repo checkout | `/srv/chitobag/repo` |
| World data | `/srv/chitobag/data` (btrfs, COW disabled — see below) |
| CurseForge key | `/srv/chitobag/cf_api_key.txt`, mode 600, deliberately outside the checkout |
| Runner | staged at `/srv/chitobag/actions-runner`, **not yet registered** |

### Memory: 18 GB heap inside a 25 GB budget

The box has 30 GB total, and its only swap is 30 GB of *zram* — compressed swap
that lives in RAM. Pushing a pre-touched heap into that causes multi-second
stalls, so the server must never reach its limit.

25 GB is the container budget, not the heap. A 25 GB *heap* would need ~29 GB
with JVM metaspace, GC structures, code cache and direct buffers, leaving
nothing for the OS.

20 GB was tried first and idled at **21.6 GiB of 25 GiB (86%)** with no players
connected — too close to an OOM-kill once off-heap grows under load, and a
container OOM-kill is an unclean stop. At `MC_XMX=18G` the same server idles at
**19.5 GiB (78%)**, leaving ~5.5 GB of headroom. The pack itself recommends
10 GB, so 18 GB is already generous.

Raise `MC_XMX` in `.env` if you want more, but watch `docker stats` under a full
player load before trusting it.

`vm.swappiness=1` is set in `/etc/sysctl.d/99-chitobag.conf` for the same reason.

### CPU

`MC_BG_THREADS=30` sets both `-Dmax.bg.threads` (Minecraft's worldgen/IO pool)
and `-XX:ActiveProcessorCount`; `MC_CPUS=30` caps the container. Two threads are
left for the OS and Docker.

### btrfs

`/srv/chitobag/data` has copy-on-write disabled (`chattr +C`, set while the
directory was empty). Minecraft rewrites region files in place constantly, and
COW fragments them badly. If you ever recreate that directory, re-apply `+C`
**before** the server first runs — it only affects files created afterwards.

### Ports

No host firewall is active (ufw installed but inactive, no nftables ruleset), so
only the router needs forwarding: **25565/tcp** and **24454/udp**.
