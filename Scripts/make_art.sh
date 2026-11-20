#!/bin/bash
# Draws the README's hero and the GitHub social preview from the pages in
# docs/art and the screenshots already in docs/screenshots:
#
#   Scripts/make_art.sh
#
# Run it from the top of the repository, after the screenshots are made
# (MAINTENANCE.md, "Screenshots and clips"). The snapshot may read only the folder its
# page is in, so the pages, the two fonts and the images are copied into a
# scratch folder first, and that folder is removed at the end.
set -euo pipefail

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

cp docs/art/art.css docs/art/hero.html docs/art/social-preview.html "$scratch/"
cp Resources/Fonts/fraunces.woff2 Resources/Fonts/inter-tight.woff2 "$scratch/"
cp docs/screenshots/menu-totals.png docs/screenshots/dashboard-today.png "$scratch/"
sips -s format png -Z 256 --matchTo '/System/Library/ColorSync/Profiles/sRGB Profile.icc' \
    Resources/AppIcon.icns --out "$scratch/icon.png" >/dev/null

mkdir -p docs/screenshots docs/github
swift Scripts/snapshot.swift "$scratch/hero.html" docs/screenshots/hero.png --width 800 | tail -1
swift Scripts/snapshot.swift "$scratch/social-preview.html" docs/github/social-preview.png --width 640 | tail -1
swift Scripts/snapshot.swift --strip docs/screenshots/hero.png docs/github/social-preview.png
