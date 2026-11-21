---
name: verify
description: Smoke-test Bytemeter end to end on a synthetic database. Use before committing any change to Bytemeter, after the self-test passes, to check the app builds, writes its dashboard and export, and starts its real menu read-only.
---

# Verify Bytemeter

The gate (`swift run -c release BytemeterSelfTest`) proves the engine. This proves the app runs and looks right. Run the gate first; nothing here repeats it.

Every step uses a demo database in the system temp folder. Never point a step at `~/Library/Application Support/Bytemeter/`, never start the built app without `--dashboard` or `--demo` (a plain start opens the real data), and never stop the installed copy.

## 1. Build

```sh
python3 Scripts/make_fonts.py --check
swift build -c release
```

Working means both exit 0. `ld: warning: search path ... not found` lines are harmless.

## 2. Dashboard and export from a demo database

```sh
T=$(mktemp -d -t bytemeter-verify)
python3 Scripts/make_demo_db.py "$T/demo"
.build/release/Bytemeter --dashboard "$T/demo"
grep -Eic '<script|https?:' "$T/demo/dashboard.html"
```

Working means: each command exits 0; `dashboard.html` and `bytemeter_export.csv` are written and not empty; the `grep` prints 0. Open `dashboard.html` in a browser and look: today's total, the week and month rows and the hourly chart all show figures, in the dark theme, with no gaps.

## 3. Launch and quit the real menu, read-only

```sh
.build/release/Bytemeter --demo "$T/demo" 2> "$T/demo.log" &
PID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do grep -q "Read only" "$T/demo.log" && break; sleep 1; done
cat "$T/demo.log"; kill -0 $PID && echo alive; kill $PID
```

Working means the log says `Bytemeter demo: showing ... Read only.` and the process is still alive when checked. The loop only waits up to ten seconds for that line; it is not a retry. Stop it by the `PID` you kept, never by name. Demo mode never writes and leaves an installed Bytemeter alone.

What this covers: the app launches in demo mode, opens the database, builds its menu bar item and stays up. What it does not: the menu's contents, which need a click. For a change to the menu, take the menu image as MAINTENANCE.md, 'Screenshots and clips', says (`Scripts/menu_shots.swift`), which needs screen recording allowed, and look at it.

The temp folder holds only synthetic data; delete it by its printed path when done.

## When it fails

- Fix the cause and run the failing step again. If it still fails after three rounds, stop and bring in a person, with the command and its output.
- Never skip a step or a check, add a sleep, or retry a flaky one until it passes. Find the root cause; if you cannot, stop and say so.

## Keep this file current

When a command here, in AGENTS.md or in MAINTENANCE.md changes, update this file in the same commit, and cut any step that no longer earns its place.
