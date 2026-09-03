#!/usr/bin/env python3
"""Apply the backup retention policy.

  - Everything from the last N days (default 3) is kept, at full 30-minute
    granularity.
  - Older than that, one backup per calendar day survives: the last one taken
    that day, since it reflects the most play.
  - Dailies are kept forever unless DAILY_KEEP_DAYS is set.

Separate from backup.sh and pure, so the policy can be tested without moving a
byte on disk. --dry-run prints what would go without deleting.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from datetime import datetime, timedelta
from pathlib import Path

# 2026-09-02_2130
NAME_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})(\d{2})$")


def parse_stamp(name: str) -> datetime | None:
    m = NAME_RE.match(name)
    if not m:
        return None
    y, mo, d, h, mi = (int(x) for x in m.groups())
    try:
        return datetime(y, mo, d, h, mi)
    except ValueError:
        return None


def plan(names: list[str], now: datetime, keep_all_days: int = 3,
         daily_keep_days: int = 0) -> tuple[list[str], list[str]]:
    """Return (keep, delete) for the given backup directory names."""
    dated = sorted(
        ((n, ts) for n in names if (ts := parse_stamp(n)) is not None),
        key=lambda p: p[1],
    )
    if not dated:
        return [], []

    recent_cutoff = now - timedelta(days=keep_all_days)
    keep: set[str] = set()
    by_day: dict[tuple, list[tuple[str, datetime]]] = {}

    for name, ts in dated:
        if ts >= recent_cutoff:
            keep.add(name)          # inside the window: keep every one
        else:
            by_day.setdefault((ts.year, ts.month, ts.day), []).append((name, ts))

    for day, entries in by_day.items():
        if daily_keep_days:
            newest = max(e[1] for e in entries)
            if newest < now - timedelta(days=daily_keep_days):
                continue            # this day has aged out entirely
        # Last of the day: it reflects the most play.
        keep.add(max(entries, key=lambda e: e[1])[0])

    delete = [n for n, _ in dated if n not in keep]
    return sorted(keep), delete


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("root", help="directory holding the backup snapshots")
    ap.add_argument("--keep-all-days", type=int, default=3)
    ap.add_argument("--daily-keep-days", type=int, default=0,
                    help="0 keeps one-per-day forever")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    root = Path(a.root)
    if not root.is_dir():
        print(f"prune: {root} is not a directory", file=sys.stderr)
        return 1

    names = [p.name for p in root.iterdir()
             if p.is_dir() and parse_stamp(p.name)]
    keep, delete = plan(names, datetime.now(), a.keep_all_days, a.daily_keep_days)

    for name in delete:
        target = root / name
        if a.dry_run:
            print(f"  would delete {name}")
            continue
        # Hardlinked trees share inodes, so removing one only frees the blocks
        # no surviving snapshot still references.
        shutil.rmtree(target, ignore_errors=True)
        print(f"  deleted {name}")

    print(f"prune: kept {len(keep)}, removed {len(delete)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
