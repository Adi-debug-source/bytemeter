#!/bin/bash
# What Bytemeter costs while it sits in the menu bar: processor time and
# memory of the real app, sampling for real, over a stretch of doing nothing.
#
#   Scripts/measure_idle.sh [--binary PATH] [--seconds N] [--mode MODE] [--live-speed]
#
#   --binary PATH   the Bytemeter binary to run (default .build/release/Bytemeter)
#   --seconds N     how long to watch it for, after a 10 second settle (default 120)
#   --mode MODE     the menu bar figure: today, week, month or all_time (default all_time,
#                   the dearest, because it reads every row)
#   --live-speed    switch the live speed on, which redraws the item every second
#
# It never touches the installed app or its data. The copy it starts is given a
# home folder of its own (CFFIXED_USER_HOME), holding a demo database from
# Scripts/make_demo_db.py, so it takes its own lock, counts into its own file
# and leaves a running Bytemeter alone. A second Bytemeter item shows in the
# menu bar while it runs. Everything it made is removed at the end.
#
# The engine's own timings, a reading, the menu bar figure, the menu and the
# dashboard, come from: swift run -c release BytemeterSelfTest --measure
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
binary="$here/.build/release/Bytemeter"
seconds=120
mode="all_time"
live=0

while [ $# -gt 0 ]; do
    case "$1" in
        --binary) binary="$2"; shift 2 ;;
        --seconds) seconds="$2"; shift 2 ;;
        --mode) mode="$2"; shift 2 ;;
        --live-speed) live=1; shift ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Did not expect \"$1\". Try --help." >&2; exit 2 ;;
    esac
done

case "$mode" in today|week|month|all_time) ;; *) echo "--mode is today, week, month or all_time." >&2; exit 2 ;; esac
case "$seconds" in ''|*[!0-9]*) echo "--seconds wants a whole number." >&2; exit 2 ;; esac
[ -x "$binary" ] || { echo "No binary at $binary. Run: swift build -c release" >&2; exit 1; }

home="$(mktemp -d "${TMPDIR:-/tmp}/bytemeter_measure.XXXXXX")"
data="$home/Library/Application Support/Bytemeter"
pid=""
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$home"
}
trap cleanup EXIT

python3 "$here/Scripts/make_demo_db.py" "$data" > /dev/null
sqlite3 "$data/bytemeter.db" \
    "INSERT INTO state(key,value) VALUES('status_mode','$mode') ON CONFLICT(key) DO UPDATE SET value=excluded.value;
     INSERT INTO state(key,value) VALUES('live_speed','$live') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"

# Processor time so far, user and system together, in hundredths of a second.
cpu_centiseconds() {
    ps -o utime=,stime= -p "$1" | awk '{
        total = 0
        for (i = 1; i <= NF; i++) { n = split($i, part, ":"); t = 0; for (j = 1; j <= n; j++) t = t * 60 + part[j]; total += t }
        printf "%d", total * 100 + 0.5 }'
}

# The dashboard and the bare launch, timed before the app starts, best of five.
best_ms() {
    local best=""
    for _ in 1 2 3 4 5; do
        local start end ms
        start="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
        "$@" > /dev/null 2>&1
        end="$(perl -MTime::HiRes=time -e 'printf "%d", time * 1000')"
        ms=$((end - start))
        if [ -z "$best" ] || [ "$ms" -lt "$best" ]; then best="$ms"; fi
    done
    echo "$best"
}
launch_ms="$(best_ms env CFFIXED_USER_HOME="$home" "$binary" --help)"
dashboard_ms="$(best_ms env CFFIXED_USER_HOME="$home" "$binary" --dashboard "$data")"

CFFIXED_USER_HOME="$home" "$binary" 2> "$home/bytemeter.err" &
pid=$!
sleep 5
kill -0 "$pid" 2>/dev/null || { echo "Bytemeter did not stay running:" >&2; cat "$home/bytemeter.err" >&2; exit 1; }
startup="$(cpu_centiseconds "$pid")"
sleep 5
before="$(cpu_centiseconds "$pid")"
sleep "$seconds"
after="$(cpu_centiseconds "$pid")"
rss_kb="$(ps -o rss= -p "$pid" | tr -d ' ')"
footprint="$(footprint "$pid" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]* [A-Z]*\).*/\1/p' | head -1 || true)"

used=$((after - before))
echo "Bytemeter idle cost: $binary"
echo "  figure $mode, live speed $([ "$live" = 1 ] && echo on || echo off), watched for $seconds seconds"
awk -v used="$used" -v seconds="$seconds" 'BEGIN {
    printf "  processor time while idle        %.2f s, %.3f%% of one core\n", used / 100, used / seconds }'
awk -v startup="$startup" 'BEGIN { printf "  processor time, first 5 seconds  %.2f s\n", startup / 100 }'
awk -v kb="$rss_kb" 'BEGIN { printf "  memory, resident                 %.1f MB\n", kb / 1024 }'
[ -n "$footprint" ] && echo "  memory, footprint                $footprint"
echo "  bare launch, --help              $launch_ms ms"
echo "  --dashboard on the demo month    $dashboard_ms ms"
