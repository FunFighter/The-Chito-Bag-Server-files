#!/usr/bin/env python3
"""Download every file in a CurseForge manifest.json.

Jars land in <out>/mods, zip datapacks in <out>/datapacks. Project IDs listed in
client_only.txt are skipped -- they crash a dedicated server.

Uses the official CurseForge API when CF_API_KEY is set, otherwise the public
website download endpoint. Every archive is integrity-checked; any failure is
fatal so a broken image is never produced.
"""
import json, os, sys, time, zipfile, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "manifest.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/build/out"
API_KEY = os.environ.get("CF_API_KEY", "").strip()
# Flipped off if the key turns out to be rejected, so a bad or stale key
# degrades to the public endpoint instead of failing the whole build.
_USE_OFFICIAL = bool(API_KEY)
_AUTH_WARNED = False
UA = "Mozilla/5.0 (compatible; chitobag-server-build/1.0)"
RETRIES = 5

def _skip_ids():
    path = os.path.join(HERE, "client_only.txt")
    ids = set()
    if os.path.exists(path):
        for line in open(path):
            line = line.split("#")[0].strip()
            if line:
                ids.add(int(line.split()[0]))
    return ids

def _open(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA, **(headers or {})})
    return urllib.request.urlopen(req, timeout=120)

def _official_url(pid, fid):
    r = _open(f"https://api.curseforge.com/v1/mods/{pid}/files/{fid}/download-url",
              {"x-api-key": API_KEY, "Accept": "application/json"})
    return json.load(r)["data"]

def resolve_and_download(entry):
    global _USE_OFFICIAL, _AUTH_WARNED
    pid, fid = entry["projectID"], entry["fileID"]
    last = ""
    for attempt in range(RETRIES):
        try:
            if _USE_OFFICIAL:
                try:
                    url = _official_url(pid, fid)
                except urllib.error.HTTPError as exc:
                    if exc.code in (401, 403):
                        if not _AUTH_WARNED:
                            _AUTH_WARNED = True
                            # Surface what CurseForge actually said -- "403" alone
                            # cannot distinguish a bad key from a key that lacks
                            # access to this endpoint.
                            try:
                                detail = exc.read().decode("utf-8", "replace")[:300].strip()
                            except Exception:
                                detail = "(no response body)"
                            print(f"[fetch] WARNING: CurseForge rejected the API key "
                                  f"(HTTP {exc.code}): {detail or '(empty body)'}",
                                  flush=True)
                            print("[fetch] falling back to the public endpoint for "
                                  "all downloads", flush=True)
                        _USE_OFFICIAL = False
                        continue
                    raise
                resp = _open(url)
            else:
                # Public endpoint 307/302-redirects to the CDN; the final path
                # carries the real filename.
                resp = _open(f"https://www.curseforge.com/api/v1/mods/{pid}/files/{fid}/download")
                url = resp.geturl()
            name = unquote(os.path.basename(urlparse(url).path))
            if not name:
                raise RuntimeError(f"no filename in {url}")
            sub = "mods" if name.lower().endswith(".jar") else "datapacks"
            dest = os.path.join(OUT, sub, name)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with resp, open(dest, "wb") as fh:
                while chunk := resp.read(1 << 20):
                    fh.write(chunk)
            if not zipfile.is_zipfile(dest):
                os.remove(dest)
                raise RuntimeError("not a valid archive")
            return (pid, fid, name, None)
        except Exception as exc:
            last = f"{type(exc).__name__}: {exc}"
            time.sleep(2 * (attempt + 1))
    return (pid, fid, None, last)

def main():
    manifest = json.load(open(MANIFEST))
    skip = _skip_ids()
    files = [f for f in manifest["files"] if f["projectID"] not in skip]
    print(f"[fetch] {len(files)} files to download "
          f"({len(manifest['files']) - len(files)} skipped as client-only), "
          f"auth={'official api key' if API_KEY else 'public endpoint'}", flush=True)

    with ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(resolve_and_download, files))

    failed = [r for r in results if r[2] is None]
    for pid, fid, _, err in failed:
        print(f"[fetch] FAILED project={pid} file={fid}: {err}", file=sys.stderr)
    if failed:
        sys.exit(f"[fetch] {len(failed)} file(s) could not be downloaded -- aborting build")

    jars = sorted(os.listdir(os.path.join(OUT, "mods")))
    with open(os.path.join(OUT, "mods.list"), "w") as fh:
        fh.write("\n".join(jars) + "\n")
    dp = os.path.join(OUT, "datapacks")
    print(f"[fetch] ok: {len(jars)} jars, "
          f"{len(os.listdir(dp)) if os.path.isdir(dp) else 0} datapacks", flush=True)

if __name__ == "__main__":
    main()
