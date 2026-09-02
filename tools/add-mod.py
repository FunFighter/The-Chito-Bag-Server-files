#!/usr/bin/env python3
"""Add (or update) a CurseForge mod in manifest.json.

    tools/add-mod.py https://www.curseforge.com/minecraft/mc-mods/jei
    tools/add-mod.py jei                    # slug works too
    tools/add-mod.py 238222                 # so does a project ID
    tools/add-mod.py jei --file-id 1234567  # pin an exact file
    tools/add-mod.py jei --dry-run          # show what would change

Picks the newest file matching the pack's Minecraft version and loader, and
routes CurseForge Client-tagged mods into docker/client_only.txt so they are
kept out of the server image.
"""
import argparse, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, "manifest.json")
CLIENT_ONLY = os.path.join(ROOT, "docker", "client_only.txt")


def cfwidget(ref):
    """Resolve a project through cfwidget.

    CurseForge's own API needs a key and its search endpoint is Cloudflare
    -blocked, so this uses the public cfwidget proxy. Its slug index has gaps --
    a numeric project ID always works and is the documented fallback.
    """
    path = ref if ref.isdigit() else f"minecraft/mc-mods/{ref}"
    status = ""
    for _ in range(3):
        p = subprocess.run(["curl", "-s", "--max-time", "60", "-A", "chitobag/1.0",
                            "-w", "\n%{http_code}",
                            f"https://api.cfwidget.com/{path}"],
                           capture_output=True, text=True)
        body, _, status = p.stdout.rpartition("\n")
        try:
            d = json.loads(body)
        except Exception:
            d = {}
        if "title" in d:
            return d
        # cfwidget indexes a project on first request and 202s until ready.
        if status == "202" or d.get("error") == "in_queue":
            continue
        break
    if status == "404" and not ref.isdigit():
        sys.exit(f"'{ref}' is not in cfwidget's slug index (HTTP 404).\n"
                 f"Use the numeric project ID instead -- it is on the mod's "
                 f"CurseForge page under 'Project ID' in the right-hand panel:\n"
                 f"    tools/add-mod.py <projectID>")
    sys.exit(f"could not look up '{ref}' (HTTP {status or '?'}). "
             f"If the project is new, retry in a moment.")


def parse_ref(raw):
    m = re.search(r"curseforge\.com/minecraft/mc-mods/([^/?#]+)", raw)
    return m.group(1) if m else raw.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mod", help="CurseForge URL, slug, or project ID")
    ap.add_argument("--file-id", type=int, help="pin a specific file instead of the newest")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    man = json.load(open(MANIFEST))
    mc = man["minecraft"]["version"]
    loader = man["minecraft"]["modLoaders"][0]["id"].split("-")[0]      # "neoforge"
    loader_tag = {"neoforge": "NeoForge", "forge": "Forge", "fabric": "Fabric"}[loader]

    d = cfwidget(parse_ref(a.mod))
    pid, title = d["id"], d["title"]

    if a.file_id:
        f = next((x for x in d.get("files", []) if x["id"] == a.file_id), None)
        if not f:
            sys.exit(f"file {a.file_id} not found on '{title}'")
    else:
        cands = [x for x in d.get("files", [])
                 if mc in x.get("versions", []) and loader_tag in x.get("versions", [])]
        if not cands:
            # Some older projects tag the game version but not the loader.
            cands = [x for x in d.get("files", [])
                     if mc in x.get("versions", [])
                     and not {"Fabric", "Quilt"} & set(x.get("versions", []))]
        if not cands:
            sys.exit(f"'{title}' has no {mc} {loader_tag} file on CurseForge")
        f = max(cands, key=lambda x: x["id"])

    side = f.get("versions", [])
    client_only = "Client" in side and "Server" not in side

    existing = next((x for x in man["files"] if x["projectID"] == pid), None)
    if existing and existing["fileID"] == f["id"]:
        print(f"{title} is already pinned to {f['name']} -- nothing to do")
        return
    action = "update" if existing else "add"

    print(f"  {action}: {title}")
    print(f"    projectID {pid}  fileID {f['id']}")
    print(f"    file      {f['name']}")
    print(f"    side      {'CLIENT-ONLY (excluded from the server)' if client_only else 'client + server'}")
    if a.dry_run:
        print("\n  --dry-run: nothing written")
        return

    if existing:
        existing["fileID"] = f["id"]
    else:
        man["files"].append({"projectID": pid, "fileID": f["id"],
                             "required": True, "isLocked": False})
    json.dump(man, open(MANIFEST, "w"), indent=2)

    if client_only:
        txt = open(CLIENT_ONLY).read()
        if not re.search(rf"^{pid}\b", txt, re.M):
            open(CLIENT_ONLY, "a").write(f"{pid:<9} # {title}\n")
            print(f"    -> also listed in docker/client_only.txt")

    print(f"\n  manifest.json now has {len(man['files'])} files. Next:")
    print(f"    git commit -am 'Add {title}' && git push")
    print(f"    (the deploy workflow rebuilds and restarts the server on its own)")


if __name__ == "__main__":
    main()
