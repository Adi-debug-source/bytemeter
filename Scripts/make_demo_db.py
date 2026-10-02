#!/usr/bin/env python3
"""
Make a synthetic Bytemeter database, for screenshots and for trying the
dashboard without waiting a month.

    python3 Scripts/make_demo_db.py <folder> [--now TIME] [--force] [--seed N]
    .build/release/Bytemeter --dashboard <folder> [--as-of TIME]

The first command writes <folder>/bytemeter.db. It refuses to replace an
existing database unless given --force. The second builds dashboard.html from
it without starting the menu bar app.

TIME is a local date and time such as 2026-09-29T21:30. Given --now, the data
ends at that minute instead of at the real clock, and nothing is written after
it. Give the dashboard the same moment with --as-of and the page is drawn as
if it were then, which is how the README's screenshots are made at a fixed,
believable hour whatever the time of day they are regenerated. These are
the README's own commands:

    python3 Scripts/make_demo_db.py /tmp/bytemeter-demo --now 2026-09-29T21:30 --force
    .build/release/Bytemeter --dashboard /tmp/bytemeter-demo --as-of 2026-09-29T21:30

Every figure is invented
------------------------
Nothing here is read from a real Bytemeter database, not even its shape. The
daily rhythm, the volumes, the process names and the counter values are all
made up in this file, so a screenshot of the result says nothing about whoever
ran it. That is why the README's screenshots can be published.

It is deterministic. The random seed is fixed, so two runs with the same
--now, or in the same minute without it, produce the same rows, byte for byte
with the same Python; a different Python writes the same content but stamps
its own SQLite version in the file header. Times are relative to that moment
and to this Mac's time zone, because the dashboard works out "today" in local
time; a later moment on the same day keeps the same history and simply
carries on further.

The schema is deliberately the old one
--------------------------------------
This writes the schema exactly as Database.swift creates it at user_version 1,
and nothing newer. In particular it does not add the `estimated` column. When
Bytemeter opens the file, its own migration adds that column and marks the
spread sleep rows by reading the gap_sleep events, just as it does when it
upgrades a real database. So the demo goes through the real upgrade path, and
this script never has to keep up with the schema as it grows.

What it writes
--------------
1. About 35 days of per-minute `samples` on en0, ending at the current minute:
   a quiet overnight floor, a morning rise, working hours with music and the
   odd video call, an evening peak of video, and weekends that start later
   and run later. One Saturday afternoon is on a wired adapter, en1.
2. A few bursts: a macOS update downloaded overnight, a game downloaded over
   the wire, a photo library upload, an iCloud Drive upload, app updates.
3. A handful of overnight sleeps, spread over the minutes they span exactly as
   Ledger.swift does it, each with a gap_sleep event at the wake moment.
4. Two reboots, each with a counter_reset event, plus the seed and baseline
   events and the state rows the app keeps.
5. `proc_samples` for invented but ordinary processes, adding up to roughly
   70 to 85% of the interface bytes, which is how nettop's figures behave.

It finishes by checking its own output: every sleep window holds the rows its
event describes, and the en0 counter in `state` agrees with the samples since
the last reset, to the byte.

Python 3 standard library only, so it runs on the python3 that ships with the
Command Line Tools.
"""

from __future__ import annotations

import argparse
import math
import os
import random
import re
import sqlite3
import sys
import time
from datetime import date, datetime, timedelta

DEFAULT_SEED = 20260920   # the day the first version started counting
DAYS = 35                 # enough for a full 30 day chart and heatmap

KB = 1_000                # decimal units, matching Units.swift
MB = 1_000_000
GB = 1_000_000_000

# Keys.swift writes this placeholder into `ssid` while network name capture is
# off, which is the default. A demo with network names would need a Location
# grant on a real Mac, so it should not show any.
SSID = "-"

# What nettop calls the processes. It reports the kernel's short process name,
# which stops at 15 characters, so Safari's page loads arrive under its WebKit
# networking helper with the name cut short. The real app shows exactly this.
BROWSER = "com.apple.WebKi"

# Copied verbatim from Database.swift's migrate(), version 1. Do not add the
# `estimated` column here: see the docstring.
SCHEMA = """
CREATE TABLE IF NOT EXISTS samples(
    minute    INTEGER NOT NULL,
    iface     TEXT    NOT NULL,
    ssid      TEXT    NOT NULL,
    bytes_in  INTEGER NOT NULL DEFAULT 0,
    bytes_out INTEGER NOT NULL DEFAULT 0,
    idle      INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(minute, iface, ssid)
);
CREATE TABLE IF NOT EXISTS proc_samples(
    minute    INTEGER NOT NULL,
    proc      TEXT    NOT NULL,
    bytes_in  INTEGER NOT NULL DEFAULT 0,
    bytes_out INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(minute, proc)
);
CREATE TABLE IF NOT EXISTS state(
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS events(
    ts     INTEGER NOT NULL,
    kind   TEXT    NOT NULL,
    detail TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_samples_minute ON samples(minute);
CREATE INDEX IF NOT EXISTS idx_proc_minute    ON proc_samples(minute);
CREATE INDEX IF NOT EXISTS idx_events_ts      ON events(ts);
PRAGMA user_version=1;
"""


# MARK: - Time

def epoch_minute(day: date, minutes: float) -> int:
    """The epoch minute that is `minutes` after local midnight on `day`.

    Wall clock arithmetic, then converted, so a clock change mid-window lands
    on the right local hour, which is what the dashboard groups by.
    """
    wall = datetime(day.year, day.month, day.day) + timedelta(minutes=minutes)
    return int(wall.timestamp()) // 60


def epoch_second(day: date, minutes: float) -> int:
    wall = datetime(day.year, day.month, day.day) + timedelta(minutes=minutes)
    return int(wall.timestamp())


def clamp_gauss(rng: random.Random, mean: float, sd: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, rng.gauss(mean, sd)))


# MARK: - The traffic

class Traffic:
    """Per-minute bytes, built up activity by activity before any row exists.

    Working in arrays first, and writing rows only at the end, is what lets
    the sleep gaps and reboots be cut out cleanly: an activity that overlaps a
    sleeping minute simply adds nothing there, as on a real Mac.
    """

    def __init__(self, start_minute: int, now_minute: int):
        self.start = start_minute
        self.n = now_minute - start_minute + 1
        self.down = [0.0] * self.n
        self.up = [0.0] * self.n
        self.awake = [True] * self.n
        self.touched = [False] * self.n      # any keyboard or trackpad input
        self.wired = [False] * self.n        # en1 plugged in
        self.procs: dict = {}                # (index, name) -> [down, up]

    def index(self, minute: int) -> int:
        return minute - self.start

    def add(self, minute: int, down: float, up: float, proc: str = "",
            seen: float = 0.0, touch: bool = False) -> None:
        i = minute - self.start
        if i < 0 or i >= self.n or not self.awake[i]:
            return
        self.down[i] += down
        self.up[i] += up
        if touch:
            self.touched[i] = True
        if proc and seen > 0:
            # nettop never sees all of it: a process that quits between two
            # samples takes its tail with it, and the kernel's own traffic is
            # never attributed. `seen` is the share that reaches the table.
            entry = self.procs.setdefault((i, proc), [0.0, 0.0])
            entry[0] += down * seen
            entry[1] += up * seen

    def sleep(self, first_minute: int, last_minute: int) -> None:
        """Mark whole minutes when the machine was asleep or rebooting."""
        for minute in range(first_minute, last_minute + 1):
            i = minute - self.start
            if 0 <= i < self.n:
                self.awake[i] = False


# MARK: - Activities

def chatter(t: Traffic, rng: random.Random, minute: int, daytime: bool) -> None:
    """What a Mac does on its own every minute it is awake.

    Mostly unattributed on purpose: multicast, ARP and the kernel's own
    traffic never appear in nettop, which is part of why the per-app table
    never adds up to the interface total.
    """
    down = rng.lognormvariate(math.log(6 * KB), 0.55)
    t.add(minute, down, down * rng.uniform(0.4, 0.8))
    if rng.random() < 0.25:
        t.add(minute, rng.uniform(0.4, 2.5) * KB, rng.uniform(0.3, 1.5) * KB, "apsd", 1.0)
    if rng.random() < 0.035:
        d = min(8 * MB, rng.lognormvariate(math.log(250 * KB), 1.0))
        t.add(minute, d, d * rng.uniform(0.1, 0.5), "cloudd", rng.uniform(0.85, 0.95))
    if rng.random() < 0.012:
        d = min(12 * MB, rng.lognormvariate(math.log(700 * KB), 0.9))
        t.add(minute, d, d * 0.02, "nsurlsessiond", rng.uniform(0.85, 0.95))
    if rng.random() < (0.07 if daytime else 0.02):
        d = rng.lognormvariate(math.log(60 * KB), 0.9)
        if rng.random() < 0.04:
            d += rng.uniform(1, 7) * MB      # the occasional attachment
        t.add(minute, d, rng.uniform(2, 25) * KB, "Mail", rng.uniform(0.8, 0.95))


def browse(t: Traffic, rng: random.Random, start: int, end: int, intensity: float) -> None:
    """Someone at the keyboard reading the web: page loads with a long tail."""
    clip = 0
    for minute in range(start, end):
        touch = rng.random() < 0.88
        if clip > 0:
            # A short embedded video, the kind that autoplays in an article.
            d = rng.uniform(6, 12) * MB
            t.add(minute, d, d * 0.012 + 15 * KB, BROWSER, rng.uniform(0.72, 0.86), touch)
            clip -= 1
        elif rng.random() < 0.6 * intensity:
            d = min(60 * MB, rng.lognormvariate(math.log(2.2 * MB), 1.15))
            u = d * rng.uniform(0.03, 0.08) + rng.uniform(8, 25) * KB
            t.add(minute, d, u, BROWSER, rng.uniform(0.66, 0.84), touch)
            t.add(minute, rng.uniform(2, 9) * KB, rng.uniform(1, 4) * KB, "mDNSResponder", 1.0)
        else:
            t.add(minute, rng.uniform(10, 90) * KB, rng.uniform(4, 25) * KB, BROWSER, 0.6, touch)
        if rng.random() < 0.03 * intensity:
            clip = rng.randint(3, 11)
        if rng.random() < 0.06:
            t.add(minute, rng.uniform(5, 60) * KB, rng.uniform(2, 10) * KB, "Safari", 1.0)
        if rng.random() < 0.03:
            t.add(minute, rng.uniform(5, 30) * KB, rng.uniform(2, 6) * KB, "trustd", 1.0)


def music(t: Traffic, rng: random.Random, start: int, end: int) -> None:
    """Streaming music fetches each track in a lump as it starts playing."""
    minute = start
    while minute < end:
        track = rng.uniform(7, 10.5) * MB
        seen = rng.uniform(0.82, 0.92)
        t.add(minute, track * 0.7, 40 * KB, "Music", seen)
        t.add(minute + 1, track * 0.3, 15 * KB, "Music", seen)
        minute += rng.randint(3, 5)


def video(t: Traffic, rng: random.Random, start: int, end: int, rate: float,
          touch_every: float) -> None:
    """Streamed video: a buffer fill, then a steady rate that the player nudges
    up and down. Nobody touches the keyboard during a film, so most of it ends
    up idle, which is exactly what the idle split should show."""
    level = rate
    for k, minute in enumerate(range(start, end)):
        if k % 9 == 0:
            level = rate * rng.uniform(0.8, 1.2)
        d = level * rng.uniform(0.85, 1.15) * (2.2 if k < 2 else 1.0)
        touch = k < 2 or rng.random() < 1.0 / touch_every
        t.add(minute, d, d * 0.011 + rng.uniform(10, 30) * KB, BROWSER, rng.uniform(0.72, 0.88), touch)


def call(t: Traffic, rng: random.Random, start: int, end: int) -> None:
    """A video call is the one everyday thing that uploads as much as it downloads."""
    for minute in range(start, end):
        t.add(minute, rng.uniform(5.5, 8.5) * MB, rng.uniform(5.0, 8.0) * MB,
              "zoom.us", rng.uniform(0.85, 0.95), rng.random() < 0.3)


def transfer(t: Traffic, rng: random.Random, start: int, total: float, rate: float,
             proc: str, upload: bool = False) -> int:
    """One big download or upload at a roughly steady rate. Returns the minute after."""
    minute = start
    left = total
    seen = rng.uniform(0.88, 0.95)
    while left > 0:
        chunk = min(left, rate * rng.uniform(0.8, 1.15))
        if upload:
            t.add(minute, chunk * 0.03, chunk, proc, seen)
        else:
            # TCP acknowledgements are why a download always uploads a little.
            t.add(minute, chunk, chunk * 0.018, proc, seen)
        left -= chunk
        minute += 1
    return minute


# MARK: - The plan

class Day:
    """One local day's routine, in minutes after local midnight."""

    def __init__(self, day: date, rng: random.Random):
        self.day = day
        self.rng = rng
        self.weekday = day.weekday()                     # 0 is Monday
        weekend = self.weekday >= 5
        if weekend:
            self.kind = "weekend"
            self.first = clamp_gauss(rng, 9 * 60 + 50, 35, 8 * 60 + 40, 11 * 60)
        else:
            # Some weekdays are spent out, and the Mac sits idle all day.
            self.kind = "out" if rng.random() < 0.18 else "home"
            self.first = clamp_gauss(rng, 7 * 60 + 40, 15, 7 * 60 + 5, 8 * 60 + 20)
        if self.weekday in (4, 5):                       # Friday and Saturday nights run late
            self.bed = clamp_gauss(rng, 24 * 60 + 35, 30, 23 * 60 + 40, 25 * 60 + 40)
        elif self.weekday == 6:
            self.bed = clamp_gauss(rng, 23 * 60 + 15, 20, 22 * 60 + 40, 24 * 60 + 10)
        else:
            self.bed = clamp_gauss(rng, 23 * 60 + 35, 25, 22 * 60 + 50, 24 * 60 + 30)
        self.scale = rng.lognormvariate(0, 0.25)         # some days are simply busier
        self.video_p = 0.8 if weekend or self.weekday == 4 else 0.62
        self.calls = rng.choice([0, 0, 1, 1, 1, 2]) if self.kind == "home" else 0
        self.home_afternoon = rng.random() > 0.35        # weekends only
        self.evening_until: float | None = None          # a restart can cut the evening short

    def at(self, minutes: float) -> int:
        return epoch_minute(self.day, minutes)


def build_plan(seed: int, today: date, days: dict) -> dict:
    """The few events that make a month look lived in, placed relative to today.

    Offsets rather than dates, so the story reads the same whichever day the
    script runs: an update about a fortnight ago, a wired Saturday last week.
    """
    rng = random.Random(seed)
    used: set = set()

    def pick(candidates: list) -> int:
        free = [c for c in candidates if c not in used]
        choice = rng.choice(free)
        used.add(choice)
        return choice

    def weekdays(lo: int, hi: int) -> list:
        return [o for o in range(lo, hi + 1) if days[o].weekday < 5]

    plan: dict = {}
    plan["install"] = (-DAYS, rng.uniform(19 * 60 + 5, 20 * 60 + 40))
    plan["restart"] = (pick(weekdays(-29, -23)), rng.uniform(14 * 60, 16 * 60 + 30), rng.randint(95, 210))
    update_day = pick(weekdays(-17, -11))
    plan["update"] = {
        "day": update_day,
        "download_at": rng.uniform(2 * 60, 3 * 60 + 40),
        "size": rng.uniform(1.6, 2.2) * GB,
        "rate": rng.uniform(45, 70) * MB,
        "restart_at": rng.uniform(22 * 60 + 15, 22 * 60 + 45),
        "downtime": rng.randint(18 * 60, 27 * 60),
    }
    plan["wired"] = {
        "day": pick([o for o in range(-12, -3) if days[o].weekday == 5]),
        "plug_at": rng.uniform(13 * 60 + 15, 13 * 60 + 35),
        "size": rng.uniform(3.6, 4.4) * GB,
        "rate": rng.uniform(55, 75) * MB,
        "linger": rng.uniform(70, 150),
    }
    plan["photos"] = (pick([o for o in range(-22, -7) if days[o].weekday == 6]),
                      rng.uniform(16 * 60, 17 * 60 + 30), rng.uniform(0.8, 1.2) * GB)
    plan["drive"] = (pick([o for o in weekdays(-30, -3) if days[o].kind == "home"]),
                     rng.uniform(10 * 60, 15 * 60 + 30), rng.uniform(0.35, 0.6) * GB)
    plan["app_updates"] = [(-1, rng.uniform(10 * 60, 16 * 60), rng.uniform(180, 450) * MB)]
    for offset in rng.sample(range(-33, -2), 2):
        plan["app_updates"].append((offset, rng.uniform(1 * 60, 5 * 60), rng.uniform(120, 600) * MB))

    # Nights are named by the morning they end. The update night and the first
    # night stay awake: the update downloads while the Mac sits idle.
    forbidden = {update_day, -DAYS + 1}
    nights: list = []
    candidates = [k for k in range(-33, 0) if k not in forbidden]
    while len(nights) < 5:
        k = rng.choice(candidates)
        if all(abs(k - other) >= 3 for other in nights):
            nights.append(k)
    plan["sleep_nights"] = sorted(nights) + [0]

    # Gap sizes for each sleep, decided here so they do not depend on the time
    # the script happens to run. A sleeping Mac usually moves a few MB in its
    # dark wakes. Last night it did more, as a Mac does when Power Nap pulls an
    # iCloud Photos sync and an update overnight, and that is deliberate: it is
    # the night the Today chart shows, beside an evening of several hundred MB
    # an hour, so the hatched hours need this much to be seen in a screenshot
    # rather than drawn as slivers a pixel or two high.
    plan["sleep_sizes"] = {k: (rng.uniform(6, 28) * MB, rng.uniform(0.2, 0.4))
                           for k in plan["sleep_nights"]}
    plan["sleep_sizes"][0] = (rng.uniform(380, 520) * MB, rng.uniform(0.08, 0.15))
    plan["sleep_lag"] = {k: (rng.uniform(4, 18), rng.uniform(0, 59), rng.uniform(0, 59))
                         for k in plan["sleep_nights"]}
    plan["reset_counts"] = [(rng.randint(900_000, 3_200_000), rng.randint(250_000, 900_000))
                            for _ in range(2)]
    # Kept well clear of 4.29 GB, so nobody reading the events mistakes the
    # invented figure for a 32 bit counter that has wrapped.
    plan["seed_counts"] = (rng.uniform(2.0, 3.8) * GB, rng.uniform(0.08, 0.15))
    plan["en1_first"] = (rng.randint(9_000, 30_000), rng.randint(3_000, 12_000))
    return plan


# MARK: - The day itself

def live_day(t: Traffic, d: Day) -> None:
    rng = d.rng
    s = d.scale

    # Chatter for every minute of the day the Mac is awake.
    start = d.at(0)
    end = d.at(24 * 60)
    for minute in range(start, end):
        local_hour = (minute - start) // 60
        chatter(t, rng, minute, 7 <= local_hour < 23)

    first = d.first
    evening_cut = d.evening_until if d.evening_until is not None else d.bed

    if d.kind == "weekend":
        morning_end = first + rng.uniform(60, 110)
        browse(t, rng, d.at(first), d.at(morning_end), 0.6 * s)
        if rng.random() < 0.5:
            music(t, rng, d.at(first + 10), d.at(morning_end))
        if d.home_afternoon:
            a = rng.uniform(12 * 60 + 15, 13 * 60)
            b = rng.uniform(17 * 60, 18 * 60)
            if rng.random() < 0.7:
                v = rng.uniform(14 * 60, 16 * 60)
                w = v + rng.uniform(30, 90)
                browse(t, rng, d.at(a), d.at(v), 0.35 * s)
                video(t, rng, d.at(v), d.at(w), rng.uniform(9, 15) * MB, 12)
                browse(t, rng, d.at(w), d.at(max(w, b)), 0.35 * s)
            else:
                browse(t, rng, d.at(a), d.at(b), 0.35 * s)
        ev = rng.uniform(18 * 60 + 20, 19 * 60 + 10)
    else:
        breakfast = first + rng.uniform(15, 45)
        browse(t, rng, d.at(first), d.at(breakfast), 0.8 * s)
        if rng.random() < 0.5:
            music(t, rng, d.at(first + 5), d.at(breakfast))
        if d.kind == "home":
            work = rng.uniform(8 * 60 + 50, 9 * 60 + 15)
            lunch = rng.uniform(12 * 60 + 20, 12 * 60 + 50)
            back = lunch + rng.uniform(35, 60)
            done = rng.uniform(17 * 60, 18 * 60 + 30)
            browse(t, rng, d.at(work), d.at(lunch), 0.6 * s)
            browse(t, rng, d.at(back), d.at(done), 0.6 * s)
            for _ in range(rng.choice([1, 1, 2])):
                m = rng.uniform(work, done - 60)
                music(t, rng, d.at(m), d.at(m + rng.uniform(50, 120)))
            for _ in range(d.calls):
                c = rng.uniform(9 * 60 + 30, 16 * 60 + 30)
                call(t, rng, d.at(c), d.at(c + rng.uniform(20, 55)))
            if rng.random() < 0.4:
                v = lunch + rng.uniform(5, 15)
                video(t, rng, d.at(v), d.at(v + rng.uniform(10, 25)), rng.uniform(7, 11) * MB, 6)
        ev = rng.uniform(18 * 60 + 20, 19 * 60 + 40)

    # The evening: browsing either side of a film or a few episodes, and
    # nothing else while it plays, so the film's minutes can fall idle.
    film = None
    if rng.random() < d.video_p:
        if d.kind == "weekend" or d.weekday == 4:
            v = rng.uniform(19 * 60 + 30, 22 * 60)
            length, rate = rng.uniform(95, 150), rng.uniform(13, 19) * MB
        else:
            v = rng.uniform(19 * 60 + 15, 21 * 60 + 45)
            length, rate = rng.uniform(45, 140), rng.uniform(9, 14) * MB
        length = min(length, evening_cut - 10 - v)
        # Half the time the film has the screen to itself; otherwise someone
        # is half watching and picking the next episode.
        touch_every = 40 if rng.random() < 0.5 else 9
        if length > 15:
            film = (v, v + length, rate, touch_every)
    if film is None:
        browse(t, rng, d.at(ev), d.at(evening_cut - 5), 0.5 * s)
    else:
        v, w, rate, touch_every = film
        browse(t, rng, d.at(ev), d.at(v), 0.5 * s)
        video(t, rng, d.at(v), d.at(w), rate, touch_every)
        browse(t, rng, d.at(w), d.at(evening_cut - 5), 0.5 * s)


# MARK: - Build

def build(seed: int, now_ts: int) -> dict:
    now_minute = now_ts // 60
    today = datetime.fromtimestamp(now_ts).date()

    days: dict = {}
    for offset in range(-DAYS, 1):
        day = today + timedelta(days=offset)
        days[offset] = Day(day, random.Random(seed * 100_003 + day.toordinal()))

    plan = build_plan(seed, today, days)

    install_offset, install_at = plan["install"]
    install_ts = epoch_second(days[install_offset].day, install_at)
    t = Traffic(install_ts // 60, now_minute)
    events: list = []

    # The first launch: a seed lump that is never counted, then a baseline.
    seed_in, seed_ratio = plan["seed_counts"]
    seed_in = int(seed_in)
    seed_out = int(seed_in * seed_ratio)
    events.append((install_ts, "seed",
                   f"Since boot before Bytemeter started counting: en0 {seed_in} in, {seed_out} out. "
                   "Counter source mib64. "
                   "Recorded as a lump with no time detail, and deliberately not counted in any total."))
    base_in, base_out = seed_in + 4_811, seed_out + 1_377
    events.append((install_ts, "baseline",
                   f"en0 first seen at {base_in} in, {base_out} out. "
                   "Counted from here; earlier traffic is not attributable to any minute."))

    # Restarts. The minutes in between have no rows at all, because nothing
    # was running to write them, and nothing is estimated for them.
    restarts = []
    r_off, r_at, r_down = plan["restart"]
    shut = epoch_second(days[r_off].day, r_at)
    restarts.append((shut, shut + r_down))
    upd = plan["update"]
    shut = epoch_second(days[upd["day"]].day, upd["restart_at"])
    restarts.append((shut, shut + upd["downtime"]))
    days[upd["day"]].evening_until = upd["restart_at"] - 10
    days[upd["day"]].bed = max(days[upd["day"]].bed, upd["restart_at"] + upd["downtime"] / 60 + 25)
    for shut, back in restarts:
        t.sleep(shut // 60 + 1, back // 60 - 1)

    # Sleeps. The wake moment is when someone opens the lid in the morning.
    # The newest night is cut short so the Mac is awake now, because someone
    # is plainly sitting at it to look at the dashboard.
    gaps = []
    for k in plan["sleep_nights"]:
        evening = days[k - 1]
        morning = days[k]
        lag, s1, s2 = plan["sleep_lag"][k]
        sleep_ts = epoch_second(evening.day, evening.bed + lag) + int(s1) - 30
        wake_ts = epoch_second(morning.day, morning.first) + int(s2)
        if k == 0:
            wake_ts = min(wake_ts, now_ts - int(9 * 60 + s2))
            if wake_ts - sleep_ts < 45 * 60:
                continue                               # still up; no sleep yet tonight
        gaps.append((k, sleep_ts, wake_ts))
        t.sleep(sleep_ts // 60 + 1, wake_ts // 60 - 1)
        woke = t.index(wake_ts // 60)
        if 0 <= woke < t.n:
            t.touched[woke] = True

    # The wired Saturday and the photo upload Sunday are afternoons at home.
    days[plan["wired"]["day"]].home_afternoon = True
    days[plan["photos"][0]].home_afternoon = True

    # Daily life, then the bursts on top.
    for offset in range(-DAYS, 1):
        live_day(t, days[offset])

    brng = random.Random(seed + 1)
    d = days[upd["day"]]
    transfer(t, brng, d.at(upd["download_at"]), upd["size"], upd["rate"], "softwareupdated")

    w = plan["wired"]
    wd = days[w["day"]]
    plug_ts = epoch_second(wd.day, w["plug_at"])
    plug = plug_ts // 60
    browse(t, brng, plug, plug + 12, 0.7)
    finished = transfer(t, brng, plug + 2, w["size"], w["rate"], "steam_osx")
    unplug = finished + int(w["linger"])
    for minute in range(plug, unplug + 1):
        i = t.index(minute)
        if 0 <= i < t.n:
            t.wired[i] = True
    # The Steam client keeps checking in for as long as it is open.
    for minute in range(finished, unplug):
        if brng.random() < 0.3:
            t.add(minute, brng.uniform(3, 40) * KB, brng.uniform(1, 8) * KB, "steam_osx", 1.0)

    p_off, p_at, p_size = plan["photos"]
    transfer(t, brng, days[p_off].at(p_at), p_size, brng.uniform(38, 55) * MB, "cloudphotod", upload=True)
    dr_off, dr_at, dr_size = plan["drive"]
    transfer(t, brng, days[dr_off].at(dr_at), dr_size, brng.uniform(30, 45) * MB, "cloudd", upload=True)
    for a_off, a_at, a_size in plan["app_updates"]:
        transfer(t, brng, days[a_off].at(a_at), a_size, brng.uniform(60, 120) * MB, "appstoreagent")
    # Podcasts and the like, fetched in the small hours on some awake nights.
    for offset in range(-DAYS + 1, 1):
        if offset not in plan["sleep_nights"] and brng.random() < 0.4:
            at = brng.uniform(1 * 60, 5 * 60 + 30)
            transfer(t, brng, days[offset].at(at), brng.uniform(15, 90) * MB,
                     brng.uniform(20, 40) * MB, "nsurlsessiond")

    # The last few minutes: whoever is about to open the dashboard.
    for minute in range(now_minute - 8, now_minute + 1):
        if t.awake[t.index(minute)]:
            browse(t, brng, minute, minute + 1, 0.6)
            t.touched[t.index(minute)] = True

    # Idle is "no input for five minutes", taken per five second sample and
    # combined with MIN, so a minute is active if input came in the five
    # minutes up to it.
    idle = [1] * t.n
    last_touch = -10
    for i in range(t.n):
        if t.touched[i]:
            last_touch = i
        if i - last_touch <= 4:
            idle[i] = 0

    # Rows. en1 takes the traffic while it is plugged in; Wi-Fi stays
    # associated and keeps a trickle of its own.
    rrng = random.Random(seed + 2)
    rows: dict = {}
    for i in range(t.n):
        down, upload = int(t.down[i]), int(t.up[i])
        if t.wired[i] and t.awake[i]:
            trickle_in = min(down, int(rrng.uniform(1.5, 5) * KB))
            trickle_out = min(upload, int(rrng.uniform(0.8, 2.5) * KB))
            rows[(i, "en1")] = [down - trickle_in, upload - trickle_out, idle[i]]
            down, upload = trickle_in, trickle_out
        rows[(i, "en0")] = [down, upload, idle[i]]

    # Sleep gaps, spread exactly as Ledger.ingest does: the delta divided
    # evenly over the minutes from the one after the sleep to the wake minute
    # inclusive, the remainder on the last, and zero rows skipped. The wake
    # minute also carries whatever happened after waking, as it would live.
    for k, sleep_ts, wake_ts in gaps:
        delta_in_f, out_ratio = plan["sleep_sizes"][k]
        delta_in = int(delta_in_f)
        delta_out = int(delta_in * out_ratio)
        prev_minute, now_min = sleep_ts // 60, wake_ts // 60
        parts = now_min - prev_minute
        each_in, each_out = delta_in // parts, delta_out // parts
        rem_in, rem_out = delta_in - each_in * parts, delta_out - each_out * parts
        for step in range(parts):
            i = t.index(prev_minute + 1 + step)
            last = step == parts - 1
            bin_ = each_in + (rem_in if last else 0)
            bout = each_out + (rem_out if last else 0)
            if bin_ == 0 and bout == 0:
                continue
            row = rows.setdefault((i, "en0"), [0, 0, 0])
            # The spread rows are written in the same call as the wake sample,
            # with the wake minute's idle flag, and someone just woke it.
            row[0] += bin_
            row[1] += bout
            row[2] = 0
        events.append((wake_ts, "gap_sleep",
                       f"en0 gap of {wake_ts - sleep_ts} seconds. "
                       f"{delta_in} in and {delta_out} out spread evenly across {parts} minutes."))

    # Counters. Each reboot starts the kernel's count again from a small
    # number, and the raw value in `state` must equal the post-reset baseline
    # plus every byte recorded since, or the accounting check fails.
    counter_in, counter_out = base_in, base_out
    segment_start = 0
    boundaries = []
    for n, (shut_ts, back_ts) in enumerate(sorted(restarts)):
        boundaries.append((t.index(shut_ts // 60), t.index(back_ts // 60), back_ts, plan["reset_counts"][n]))
    for end_i, back_i, back_ts, (c_in, c_out) in boundaries:
        seg_in = sum(v[0] for (i, f), v in rows.items() if f == "en0" and segment_start <= i <= end_i)
        seg_out = sum(v[1] for (i, f), v in rows.items() if f == "en0" and segment_start <= i <= end_i)
        before_in, before_out = counter_in + seg_in, counter_out + seg_out
        events.append((back_ts, "counter_reset",
                       f"en0 counter fell from {before_in}/{before_out} to {c_in}/{c_out}. "
                       "Reboot or interface reset. Baseline moved, no traffic recorded for the gap."))
        counter_in, counter_out = c_in, c_out
        segment_start = back_i
    seg_in = sum(v[0] for (i, f), v in rows.items() if f == "en0" and i >= segment_start)
    seg_out = sum(v[1] for (i, f), v in rows.items() if f == "en0" and i >= segment_start)
    raw_en0 = f"{counter_in + seg_in},{counter_out + seg_out},{now_ts}"

    first_in, first_out = plan["en1_first"]
    events.append((plug_ts, "baseline",
                   f"en1 first seen at {first_in} in, {first_out} out. "
                   "Counted from here; earlier traffic is not attributable to any minute."))
    en1_in = sum(v[0] for (i, f), v in rows.items() if f == "en1")
    en1_out = sum(v[1] for (i, f), v in rows.items() if f == "en1")
    raw_en1 = f"{first_in + en1_in},{first_out + en1_out},{unplug * 60 + 52}"

    # Restarts and sleeps write nothing for per-app use either. nettop needs
    # one run after launch to baseline, so the relaunch minute has none.
    for _, back_ts in restarts:
        back_i = t.index(back_ts // 60)
        for key in [k for k in t.procs if k[0] == back_i]:
            del t.procs[key]

    state = {
        "seed_recorded": "1",
        "counter_source": "mib64",
        "raw:en0": raw_en0,
        "raw:en1": raw_en1,
        "status_mode": "today",
        "seen_menu_hint": "1",
        "last_maintenance": str(now_ts - int(random.Random(seed + 3).uniform(2, 20) * 3600)),
    }

    events.sort(key=lambda e: e[0])
    return {
        "start": t.start,
        "rows": rows,
        "procs": t.procs,
        "events": events,
        "state": state,
    }


# MARK: - Write and check

def write(path: str, data: dict) -> None:
    start = data["start"]
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    with db:
        db.executemany(
            "INSERT INTO samples(minute,iface,ssid,bytes_in,bytes_out,idle) VALUES(?,?,?,?,?,?);",
            [(start + i, iface, SSID, v[0], v[1], v[2])
             for (i, iface), v in sorted(data["rows"].items())
             if v[0] > 0 or v[1] > 0])
        db.executemany(
            "INSERT INTO proc_samples(minute,proc,bytes_in,bytes_out) VALUES(?,?,?,?);",
            [(start + i, name, int(v[0]), int(v[1]))
             for (i, name), v in sorted(data["procs"].items())
             if int(v[0]) > 0 or int(v[1]) > 0])
        db.executemany("INSERT INTO events(ts,kind,detail) VALUES(?,?,?);", data["events"])
        db.executemany("INSERT INTO state(key,value) VALUES(?,?);", sorted(data["state"].items()))
    db.execute("VACUUM;")
    db.close()


def parse_now(text: str) -> int:
    """A local date and time, as epoch seconds floored to the minute.

    It takes exactly the two forms the app's --as-of takes (parseLocal in
    TimeRanges.swift), so any moment that works for one works for the other,
    and the page and the data cannot end up naming different moments.
    """
    for form in ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S"):
        try:
            moment = datetime.strptime(text, form)
        except ValueError:
            continue
        return int(moment.timestamp()) // 60 * 60
    raise argparse.ArgumentTypeError(f"wants a local time such as 2026-09-29T21:30, not \"{text}\"")


GAP = re.compile(r"^en0 gap of (\d+) seconds\. (\d+) in and (\d+) out spread evenly across (\d+) minutes\.$")


def check(path: str, now_ts: int) -> list:
    """Read the file back and prove the three things the app relies on.

    1. Nothing is recorded after `now`, so a page drawn as of that moment
       shows everything there is.
    2. Each gap_sleep window holds exactly the rows the event describes, so
       the app's migration marks the right ones.
    3. The en0 counter in `state` equals the last post-reset baseline plus
       every byte recorded since, to the byte.
    """
    db = sqlite3.connect(path)
    now_minute = now_ts // 60
    late = (db.execute("SELECT COUNT(*) FROM samples WHERE minute>?;", (now_minute,)).fetchone()[0]
            + db.execute("SELECT COUNT(*) FROM proc_samples WHERE minute>?;", (now_minute,)).fetchone()[0]
            + db.execute("SELECT COUNT(*) FROM events WHERE ts>?;", (now_ts,)).fetchone()[0])
    stamps = [int(v.split(",")[2]) for (v,) in db.execute("SELECT value FROM state WHERE key LIKE 'raw:%';")]
    if late or any(at > now_ts for at in stamps):
        raise SystemExit("Something was written after --now.")
    report = []
    for ts, detail in db.execute("SELECT ts, detail FROM events WHERE kind='gap_sleep' ORDER BY ts;"):
        found = GAP.match(detail)
        if not found:
            raise SystemExit(f"Malformed gap event: {detail}")
        delta_in, delta_out, parts = int(found.group(2)), int(found.group(3)), int(found.group(4))
        last = ts // 60
        first = last - parts + 1
        rows = db.execute("SELECT minute, bytes_in, bytes_out FROM samples "
                          "WHERE iface='en0' AND minute BETWEEN ? AND ? ORDER BY minute;",
                          (first, last)).fetchall()
        base = (delta_in // parts, delta_out // parts)
        body = rows[:-1]
        if len(rows) != parts or any((r[1], r[2]) != base for r in body):
            raise SystemExit(f"Sleep window ending at minute {last} does not match its event.")
        if rows[-1][1] < delta_in - base[0] * (parts - 1):
            raise SystemExit(f"Sleep window ending at minute {last} lost its remainder.")
        report.append((ts, parts, delta_in, delta_out))

    raw = dict(db.execute("SELECT key, value FROM state;"))["raw:en0"].split(",")
    reset_ts, detail = db.execute("SELECT ts, detail FROM events WHERE kind='counter_reset' "
                                  "ORDER BY ts DESC LIMIT 1;").fetchone()
    after = re.search(r"to (\d+)/(\d+)\.", detail)
    since = db.execute("SELECT SUM(bytes_in), SUM(bytes_out) FROM samples "
                       "WHERE iface='en0' AND minute>=?;", (reset_ts // 60,)).fetchone()
    if (int(after.group(1)) + since[0], int(after.group(2)) + since[1]) != (int(raw[0]), int(raw[1])):
        raise SystemExit("The en0 counter in state does not match the samples since the last reset.")
    db.close()
    return report


def summarise(path: str, gaps: list) -> None:
    db = sqlite3.connect(path)
    samples = db.execute("SELECT COUNT(*) FROM samples;").fetchone()[0]
    per_iface = db.execute("SELECT iface, COUNT(*), SUM(bytes_in), SUM(bytes_out) FROM samples "
                           "GROUP BY iface ORDER BY iface;").fetchall()
    procs = db.execute("SELECT COUNT(*), SUM(bytes_in)+SUM(bytes_out) FROM proc_samples;").fetchone()
    kinds = db.execute("SELECT kind, COUNT(*) FROM events GROUP BY kind ORDER BY kind;").fetchall()
    total = sum(r[2] + r[3] for r in per_iface)
    first, last = db.execute("SELECT MIN(minute), MAX(minute) FROM samples;").fetchone()

    # Whole local days only, so today's partial figure does not drag the low end down.
    daily = []
    day = datetime.fromtimestamp(first * 60).date() + timedelta(days=1)
    today = datetime.fromtimestamp(last * 60).date()
    while day < today:
        a = epoch_minute(day, 0)
        b = epoch_minute(day + timedelta(days=1), 0)
        down = db.execute("SELECT COALESCE(SUM(bytes_in),0), COALESCE(SUM(bytes_out),0) FROM samples "
                          "WHERE minute>=? AND minute<?;", (a, b)).fetchone()
        daily.append(down)
        day += timedelta(days=1)
    db.close()

    def gb(v: float) -> str:
        return f"{v / GB:.2f} GB"

    print(f"Wrote {path}")
    print(f"  {samples} sample rows from {time.strftime('%d %b %Y %H:%M', time.localtime(first * 60))} "
          f"to {time.strftime('%d %b %Y %H:%M', time.localtime(last * 60))}")
    for iface, count, bi, bo in per_iface:
        print(f"    {iface}: {count} rows, {gb(bi)} down, {gb(bo)} up")
    print(f"  {procs[0]} per-app rows, {procs[1] / total:.0%} of interface bytes")
    print("  events: " + ", ".join(f"{kind} {count}" for kind, count in kinds))
    downs = sorted(d[0] for d in daily)
    print(f"  whole days: {len(daily)}, download {gb(downs[0])} to {gb(downs[-1])}, "
          f"median {gb(downs[len(downs) // 2])}")
    for ts, parts, delta_in, delta_out in gaps:
        print(f"  sleep woke {time.strftime('%d %b %H:%M:%S', time.localtime(ts))}: "
              f"{parts} minutes, {delta_in} in, {delta_out} out")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Write a synthetic Bytemeter database for screenshots and demos.")
    parser.add_argument("folder", help="folder to write bytemeter.db into; created if missing")
    parser.add_argument("--now", type=parse_now, metavar="TIME",
                        help="local time the data ends at, for example 2026-09-29T21:30 "
                             "(default: the current minute)")
    parser.add_argument("--force", action="store_true", help="replace an existing bytemeter.db")
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED, help="random seed (default %(default)s)")
    args = parser.parse_args()

    folder = os.path.abspath(os.path.expanduser(args.folder))
    path = os.path.join(folder, "bytemeter.db")
    # The write-ahead log files go too. A stale -wal beside a fresh database
    # would be replayed into it by SQLite on first open.
    siblings = [path, path + "-wal", path + "-shm"]
    existing = [p for p in siblings if os.path.exists(p)]
    if existing and not args.force:
        print(f"{path} already exists. Pass --force to replace it.", file=sys.stderr)
        return 1

    os.makedirs(folder, exist_ok=True)
    # Floored to the minute, so two runs at the same moment agree to the byte.
    now_ts = args.now if args.now is not None else int(time.time()) // 60 * 60
    data = build(args.seed, now_ts)

    # Written beside the target and moved into place, so an interrupted run
    # never leaves a half written database where the app would find it.
    temporary = path + ".partial"
    if os.path.exists(temporary):
        os.remove(temporary)
    write(temporary, data)
    for p in existing:
        os.remove(p)
    os.replace(temporary, path)

    gaps = check(path, now_ts)
    summarise(path, gaps)
    print("Checked: nothing after the end moment, every sleep window matches its event, "
          "and the en0 counter matches the samples.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
