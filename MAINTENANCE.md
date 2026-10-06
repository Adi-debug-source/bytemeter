# Maintenance

How to keep Bytemeter building, and how to release it. Its only claim is that
its figures match what the network interfaces carried, so the self-test
comes first and the release steps exist to make sure a stranger gets the same
app you tested.

## Before anything else

    swift build -c release
    swift run -c release BytemeterSelfTest

Both need only the Xcode command line tools, not full Xcode. The self-test is a
plain executable rather than an XCTest target because XCTest cannot be resolved
with the command line tools alone. It prints how many checks ran and exits
non-zero if any failed. Run it after any change.

Two `ld: warning: search path ... not found` lines under the command line tools
are harmless. They name folders that only exist with full Xcode.

## How it fits together

| Part | Does |
|---|---|
| `Sources/BytemeterCore` | the engine: counting, the database, the totals. No AppKit, so another platform could use it untouched |
| `Sources/Bytemeter` | the macOS app: menu bar, sampling, per-app usage, the dashboard, Preferences |
| `Sources/BytemeterSelfTest` | the checks |
| `VERSION` | the version and build number, and the only place either lives |
| `Scripts/Info.plist` | template for the app's `Info.plist` |
| `Scripts/bytemeter.plist` | template for the LaunchAgent that starts it at login |
| `Resources/AppIcon.icns` | the icon, committed as a binary |
| `install.sh` | builds the app, and installs, updates or removes it |

`./install.sh --help` lists its options. `--dry-run` works with all of them and
says exactly what would happen, with full paths, without changing anything.

## The version

`VERSION` holds both numbers:

    VERSION=1.0.0
    BUILD=1

`install.sh` writes them into `CFBundleShortVersionString` and
`CFBundleVersion` when it builds the app. Nothing else in the repository
carries a version, so there is nothing else to keep in step.

To bump it:

1. Change `VERSION`: a fix moves the last number, a new feature the middle one.
2. Add one to `BUILD`, whatever `VERSION` did. It only ever goes up.
3. Commit with the version as the message, for example `Bytemeter 1.0.1`.
4. The tag is the same number with a `v` in front: `v1.0.1`.

## The icon

`Resources/AppIcon.icns` is the only copy of the design. The code that drew it
was a one-off and no longer exists, so it cannot be regenerated from this
repository. Do not redraw it to "rebuild" it: a redraw is a different icon.
If a generator is ever written, it has to reproduce this file before it
replaces it, checked by eye at 32 and 1024 pixels.

Its SHA-256 is
`c5793d5e74ebd6e8da8b5195d6fdde4c549eec35005280c2f4c198cfdb34d6cd`. It holds
the 32, 64, 256, 512 and 1024 pixel sizes, and macOS scales the others from
those.

## The login item

`install.sh` writes `Scripts/bytemeter.plist` to
`~/Library/LaunchAgents/io.github.adi-debug-source.bytemeter.plist`. The label
is the same however Bytemeter was installed. Five things here are easy to get
wrong:

1. **`KeepAlive` is `SuccessfulExit: false`, not `true`.** launchd starts the
   app again after a crash but not after a clean exit. With a plain `true`,
   Quit never stuck: launchd started it again within seconds. Quitting from
   the menu, and a second copy stepping aside because one is already running,
   both exit with status 0. Anything that makes either exit non-zero brings
   the old bug back, and a second copy would then be retried every ten
   seconds for as long as the first one runs.
2. **Reload with `bootout` and `bootstrap`, never `kickstart`.** launchd
   caches the code signature it registered for the path, and an ad hoc
   signature changes on every build, so a kickstart launches the new binary
   against the old signature and the kernel kills it.
3. **Stop it with `bootout`, not `kill`.** While launchd holds the job, a
   killed copy counts as a crash and is started again.
4. **Paths are absolute.** launchd does not expand `~`, so the template says
   `__HOME__` and `install.sh` fills it in. It also checks that the template
   and the script agree on where the app and the log live.
5. **Errors go to `~/Library/Logs/Bytemeter/bytemeter.err`**, which survives a
   reboot, unlike `/tmp`.

## Where things live on an installed Mac

| What | Where |
|---|---|
| the app | `~/Applications/Bytemeter.app` |
| the login item | `~/Library/LaunchAgents/io.github.adi-debug-source.bytemeter.plist` |
| the data | `~/Library/Application Support/Bytemeter/`: `bytemeter.db` and its WAL files, `bytemeter.lock`, `dashboard.html`, `bytemeter_export.csv` |
| the error log | `~/Library/Logs/Bytemeter/bytemeter.err` |

`./install.sh --uninstall` stops the app and moves the app and the login item
to the Bin. It never touches the data or the log.

## Checks before a release

1. The self-test passes.
2. `bash -n install.sh` is clean, and so is `shellcheck install.sh` if you have
   it.
3. `./install.sh --dry-run` prints the paths you expect.
4. A fresh clone builds the app from cold. This is the step that proves a
   stranger gets an app and not a bare binary:

        dir="$(mktemp -d)"
        git clone . "$dir/bytemeter"
        "$dir/bytemeter/install.sh" --bundle-only "$dir/out"
        codesign --verify --deep --strict "$dir/out/Bytemeter.app"
        plutil -p "$dir/out/Bytemeter.app/Contents/Info.plist"

   The last line should show the version in `VERSION`.
5. `./install.sh` on your own Mac, then, in this order:
   1. Bytemeter is in the menu bar, and `pgrep -lf Bytemeter.app` shows one
      copy.
   2. Stand in for a crash while launchd is running it:
      `pkill -9 -f 'Bytemeter.app/Contents/MacOS/Bytemeter$'`. launchd should
      start it again within about ten seconds, with a new pid.
   3. Quit it from its menu and wait half a minute. It should stay quit:
      `pgrep` finds nothing, and
      `launchctl print gui/$UID/io.github.adi-debug-source.bytemeter` still
      lists the job.
   4. Open it again from `~/Applications`. The dashboard opens from its menu.

   A copy opened by hand is not launchd's, so it is not restarted after a
   crash until the next login. That is why the crash check comes first.
6. CI is green for the commit you are about to tag.

## Cutting a release

There is no prebuilt download. Bytemeter is ad hoc signed, not notarised, so a
downloaded app would carry a quarantine mark and Gatekeeper would refuse it.
Both install routes, Homebrew and a clone, build it on the Mac it runs on,
where there is no such mark. A release is a tag, its notes, and the formula
pointed at it.

1. Bump the version as above and commit it.
2. Run the checks above, then tag the commit and push both:

        git tag -a v1.0.1 -m "Bytemeter 1.0.1"
        git push origin main v1.0.1

3. Create the release, with no files attached:

        gh release create v1.0.1 --title "Bytemeter 1.0.1" --notes-file notes.md

   Write the notes as prose: what changed and why, not a list of commits.

4. Point the formula at the new tag, below.

Never move or re-push a tag once it is published. The formula pins the
checksum of the tag's source tarball, so a moved tag breaks every install until
the formula is updated.

## After a release

1. The release page shows the notes, and the tag points at the commit CI
   passed.
2. The formula on `main` names the new tag and its checksum.
3. Install it as a stranger would, below, and check the version.

## Homebrew

The formula lives in this repository, at `Formula/bytemeter.rb`. There is no
separate tap repository: Homebrew is pointed at this one once, by its address.

    brew tap adi-debug-source/bytemeter https://github.com/Adi-debug-source/bytemeter
    brew install adi-debug-source/bytemeter/bytemeter
    bytemeter-setup

How it works:

1. `brew tap` with an address clones this repository as a tap and finds the
   formula in `Formula/`. The short form, without the address, only works for
   a repository named `homebrew-something`, which is why the address is given.
2. `brew install` downloads the tag's source tarball named in the formula and
   runs `./install.sh --bundle-only #{prefix} --disable-sandbox`. Homebrew
   builds inside a sandbox, and SwiftPM's own sandbox cannot start inside
   another one, hence the flag.
3. The formula keeps `install.sh` and `Scripts/` in `libexec` and writes a
   `bytemeter-setup` wrapper.
4. `bytemeter-setup` runs `install.sh --app #{opt_prefix}/Bytemeter.app`,
   which copies that app to `~/Applications` and loads the login item without
   building anything. Homebrew cannot write to the home folder itself, which
   is why this is a second step. `bytemeter-setup --uninstall` and
   `--dry-run` pass straight through to `install.sh`.

After each release:

1. Take the checksum of the new tag's tarball, as GitHub serves it:

        curl -sL https://github.com/Adi-debug-source/bytemeter/archive/refs/tags/v1.0.1.tar.gz | shasum -a 256

2. In `Formula/bytemeter.rb`, set `url` to the new tag and `sha256` to that
   checksum. Commit it to `main` and push. This commit comes after the tag, so
   the tagged tarball always carries the previous checksum; that is expected,
   because Homebrew reads the formula from `main`, never from the tarball.
3. Check it as a user would:

        brew update
        brew upgrade bytemeter
        brew test bytemeter
        bytemeter-setup
        plutil -extract CFBundleShortVersionString raw -o - ~/Applications/Bytemeter.app/Contents/Info.plist

   The last line should print the new version, and Bytemeter should be back
   in the menu bar.
4. `brew audit --strict adi-debug-source/bytemeter/bytemeter` should be clean.

## Screenshots

The README images are made from a synthetic month, never from a real database, so they show nobody's usage or app list. They are reproducible byte for byte: the generator is deterministic for a given `--now`, and the dashboard renders as at `--as-of`.

```bash
swift build -c release
python3 Scripts/make_demo_db.py /tmp/bytemeter-demo --now 2026-09-29T21:30 --force
.build/release/Bytemeter --dashboard /tmp/bytemeter-demo --as-of 2026-09-29T21:30
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
  --user-data-dir="$(mktemp -d)" --hide-scrollbars --force-device-scale-factor=2 \
  --window-size=1400,3600 --screenshot=/tmp/bytemeter-demo/page.png \
  file:///tmp/bytemeter-demo/dashboard.html
sips -c 1898 2360 --cropOffset 32 220   /tmp/bytemeter-demo/page.png --out docs/dashboard.png
sips -c 850 2360  --cropOffset 1936 220 /tmp/bytemeter-demo/page.png --out docs/thirty-days.png
sips -c 880 2336  --cropOffset 2788 232 /tmp/bytemeter-demo/page.png --out docs/heatmap.png
sips -s format png -Z 256 Resources/AppIcon.icns --out docs/icon.png
```

1. Headless Chrome does not always exit after writing the file. Stop it once `page.png` exists.
2. The crop offsets are twice the CSS boxes at 1400 pixels wide. If the dashboard's layout changes, measure them again.
3. The menu image comes from the real menu running read-only against the same database: `.build/release/Bytemeter --demo /tmp/bytemeter-demo --as-of 2026-09-29T21:30`. Open the menu, capture it (Cmd+Shift+4, then Space, then click the menu), save it as `docs/menu.png`, and choose Quit from that menu to end it. The demo never writes and leaves a running Bytemeter alone.

## Known limits

- **macOS 13 and later.**
- **Not notarised.** Ad hoc signed only, so there is no prebuilt download.
  Homebrew and a clone both build on the Mac they run on, which avoids
  Gatekeeper's quarantine check.
- **A clock set ahead and then corrected.** While the clock reads earlier than
  the last reading, new readings are filed at the last reading's minute until
  real time catches up. Every byte is still counted once, but the figures look
  still for that stretch. A clock set backwards is handled fully. Using elapsed
  time within a boot session would remove this, and is left for a later
  version, since macOS sets the clock itself and this needs a clock moved by
  hand.
- **The 32 bit fallback.** It is used only if the 64 bit interface counter
  cannot be read, and it can only recognise a wrap if under 200 MB moved
  between two readings.
