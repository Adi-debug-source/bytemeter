#!/bin/bash
# Makes the README's two clips from the synthetic month, with the real
# dashboard generator and no screen capture:
#
#   Scripts/make_clips.sh
#
#   docs/screenshots/dashboard-day.gif   one invented day, a page every half hour
#   docs/screenshots/dashboard-tour.gif  the whole page, top to bottom, in six stops
#
# Run it from the top of the repository after `swift build -c release`. It
# needs ffmpeg (brew install ffmpeg) and a Retina screen, as snapshot.swift
# does. Everything it makes on the way goes in a scratch folder, removed at
# the end. The demo database is written there and nowhere else.
set -euo pipefail

day=2026-09-29
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/frames"

swiftc -O Scripts/snapshot.swift -o "$scratch/snapshot"
python3 Scripts/make_demo_db.py "$scratch/demo" --now "${day}T23:50" --force >/dev/null

# The top of the page, masthead to the foot of Today by hour, as snapshot.swift
# reports it: the same box as docs/screenshots/dashboard-today.png. Each page
# is cropped as it is made, because the page's full height changes through
# the day and ffmpeg wants every frame the same size.
top="crop=2360:2069:220:32,scale=1000:-1:flags=lanczos"

frame=0
for time in $(seq -f '%02g:30' 0 23 | paste -d' ' - <(seq -f '%02g:00' 1 23; echo 23:50) | tr ' ' '\n'); do
    .build/release/Bytemeter --dashboard "$scratch/demo" --as-of "${day}T${time}" >/dev/null
    "$scratch/snapshot" "$scratch/demo/dashboard.html" "$scratch/page.png" >/dev/null
    ffmpeg -v error -y -i "$scratch/page.png" -vf "$top" "$(printf '%s/frames/%03d.png' "$scratch" "$frame")"
    frame=$((frame + 1))
done

# Eight pages a second, and the last one held for two and a half seconds
# before the loop.
ffmpeg -v error -y -framerate 8 -i "$scratch/frames/%03d.png" \
    -vf "palettegen=max_colors=96:stats_mode=diff" "$scratch/palette-day.png"
ffmpeg -v error -y -framerate 8 -i "$scratch/frames/%03d.png" -i "$scratch/palette-day.png" \
    -lavfi "paletteuse=dither=none:diff_mode=rectangle" -final_delay 250 \
    -loop 0 docs/screenshots/dashboard-day.gif

# The tour reads the page as it stood at 21:30, the moment of the stills, in
# six stops from the top to the foot, each held for 1.8 seconds. The stops are
# pixel rows of the page, chosen so no section is cut through its heading.
.build/release/Bytemeter --dashboard "$scratch/demo" --as-of "${day}T21:30" >/dev/null
"$scratch/snapshot" "$scratch/demo/dashboard.html" "$scratch/page.png" >/dev/null
mkdir "$scratch/stops"
stop=0
for row in 0 1990 3000 3900 5090 6178; do
    ffmpeg -v error -y -i "$scratch/page.png" \
        -vf "crop=2360:1380:220:${row},scale=1000:-1:flags=lanczos" "$scratch/stops/$stop.png"
    stop=$((stop + 1))
done
ffmpeg -v error -y -framerate 5/9 -i "$scratch/stops/%d.png" -vf "palettegen=max_colors=128" "$scratch/palette-tour.png"
ffmpeg -v error -y -framerate 5/9 -i "$scratch/stops/%d.png" -i "$scratch/palette-tour.png" \
    -lavfi "paletteuse=dither=none" -final_delay 180 -loop 0 docs/screenshots/dashboard-tour.gif

ls -l docs/screenshots/dashboard-day.gif docs/screenshots/dashboard-tour.gif | awk '{ print $5, $9 }'
