"""Retention policy tests.

The policy is easy to get subtly wrong -- an off-by-one at the window edge
silently deletes a week of backups -- so it is tested rather than eyeballed.
"""
from datetime import datetime, timedelta

import pytest

from prune import parse_stamp, plan

NOW = datetime(2026, 9, 2, 21, 0)


def stamps(start: datetime, count: int, every_minutes: int = 30) -> list[str]:
    return [(start + timedelta(minutes=every_minutes * i)).strftime("%Y-%m-%d_%H%M")
            for i in range(count)]


def test_parse_stamp():
    assert parse_stamp("2026-09-02_2130") == datetime(2026, 9, 2, 21, 30)
    assert parse_stamp("latest") is None
    assert parse_stamp("2026-09-02_2130.partial") is None
    assert parse_stamp("2026-13-02_2130") is None      # month 13
    assert parse_stamp("2026-09-02_2560") is None      # hour 25


def test_everything_inside_the_window_is_kept():
    # Two days of half-hourly backups, all recent.
    names = stamps(NOW - timedelta(days=2), 96)
    keep, delete = plan(names, NOW, keep_all_days=7)
    assert delete == []
    assert len(keep) == 96


def test_older_than_the_window_collapses_to_one_per_day():
    # 10 days of half-hourly backups.
    names = stamps(NOW - timedelta(days=10), 10 * 48)
    keep, delete = plan(names, NOW, keep_all_days=7)

    kept_old = [n for n in keep if parse_stamp(n) < NOW - timedelta(days=7)]
    days = {parse_stamp(n).date() for n in kept_old}
    assert len(kept_old) == len(days), "more than one backup kept for some day"
    assert delete, "nothing was pruned"
    # Everything still inside the window survives untouched.
    assert all(parse_stamp(n) >= NOW - timedelta(days=7)
               for n in delete) is False


def test_the_survivor_of_a_day_is_the_last_one():
    day = NOW - timedelta(days=9)
    day = day.replace(hour=0, minute=0)
    names = stamps(day, 48)
    keep, _ = plan(names, NOW, keep_all_days=7)
    assert len(keep) == 1
    assert parse_stamp(keep[0]).hour == 23
    assert parse_stamp(keep[0]).minute == 30


def test_window_boundary_is_not_off_by_one():
    just_inside = (NOW - timedelta(days=7) + timedelta(minutes=1)).strftime("%Y-%m-%d_%H%M")
    just_outside = (NOW - timedelta(days=7) - timedelta(minutes=1)).strftime("%Y-%m-%d_%H%M")
    keep, delete = plan([just_inside, just_outside], NOW, keep_all_days=7)
    assert just_inside in keep
    # The outside one is the only backup for its day, so it is kept as that
    # day's daily -- not deleted.
    assert just_outside in keep
    assert delete == []


def test_dailies_are_kept_forever_by_default():
    names = [(NOW - timedelta(days=d)).strftime("%Y-%m-%d_%H%M") for d in range(1, 400)]
    keep, delete = plan(names, NOW, keep_all_days=7, daily_keep_days=0)
    assert delete == [], "dailies should not expire by default"
    assert len(keep) == len(names)


def test_dailies_expire_when_a_cap_is_set():
    names = [(NOW - timedelta(days=d)).strftime("%Y-%m-%d_%H%M") for d in range(1, 100)]
    keep, delete = plan(names, NOW, keep_all_days=7, daily_keep_days=30)
    assert delete, "nothing expired with a 30 day cap"
    for n in keep:
        assert parse_stamp(n) >= NOW - timedelta(days=30)


def test_unparseable_names_are_left_completely_alone():
    names = ["latest", "README", "2026-09-02_2130.partial", ".lock"]
    keep, delete = plan(names, NOW)
    assert keep == [] and delete == []


def test_empty_directory():
    assert plan([], NOW) == ([], [])


def test_realistic_seven_day_run():
    """48/day for 14 days: week one intact, week two down to dailies."""
    names = stamps(NOW - timedelta(days=14), 14 * 48)
    cutoff = NOW - timedelta(days=7)
    keep, delete = plan(names, NOW, keep_all_days=7)

    recent = [n for n in keep if parse_stamp(n) >= cutoff]
    older = [n for n in keep if parse_stamp(n) < cutoff]

    assert len(recent) == 7 * 48, "the whole window should survive intact"

    # The cutoff lands mid-day, so the older range covers one more calendar
    # day than it does 24h periods -- exactly one survivor for each.
    expected_days = {parse_stamp(n).date() for n in names
                     if parse_stamp(n) < cutoff}
    assert len(older) == len(expected_days)
    assert len({parse_stamp(n).date() for n in older}) == len(older)

    assert len(delete) == 14 * 48 - len(keep)
