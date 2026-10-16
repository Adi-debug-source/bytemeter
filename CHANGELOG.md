# Changelog

## Unreleased

- The cap bar in the menu rounds down like the percentage beside it, so it is full only once the cap is reached. At 95.9% it drew twelve full cells beside "2.40 GB left". The self-test checks the bar at four points, 919 checks in all.
- The README's icon and menu images are plain sRGB. The icon carried the colour profile of the display it was made on, under that display's name, and the menu image carried Display P3.
- The app icon itself is sRGB too. `AppIcon.icns` carried the same display profile in each of its sizes; the conversion changed only what that profile implied, and the design is as it was.
- `.gitignore` leaves out SQLite databases and their journals, and `.env`, so a try-out database made in the working copy cannot be committed.
- A `SECURITY.md` says how to report a vulnerability.

## 1.2.0, 15 October 2026

This version corrects several figures, fixes how per-app traffic and sleep are recorded, and makes the cap and the dashboard say exactly what they show. It moves the database to schema version 3 the first time it opens it, as the first item under Counting and accuracy explains.

### The menu bar

- On the first day of a month or billing cycle, the projection runs the last 24 hours on to the cycle's end instead of treating a few hours as a whole day, and with under a day counted it says it is too early to project, in the menu and on the dashboard.
- No figure prints as 1000 of a smaller unit: 999.6 MB reads 1.00 GB, so the menu bar no longer shows 1000 MB as the day crosses 1 GB.
- The live speed updates every second without a pause, where it used to stall for about five seconds every half minute while `nettop` ran.
- The cap, in the menu and in the dashboard's Monthly cap panel, shows the real percentage, past 100% once the cap is passed, and says what is left and how many days are to go, or how far over the cap the month is, with only the bar stopping at full.
- Preferences offers to track a monthly cap, where it used to offer a warning that never came.
- Preferences says the billing cycle can start on any day from 1 to 28.
- If the database cannot be written, for example on a full disk, a line at the top of the menu says recording has stopped and since when, until a write succeeds again, where before the figures simply stopped moving.
- Before the first byte is counted, a line at the top of the menu says counting has started, so a new install's menu of 0 B explains itself.

### The dashboard

- Today is compared with yesterday at the same time of day, so an ordinary morning no longer reads as down on yesterday.
- The heatmap is an average over the last four whole weeks, so every weekday is counted the same number of times, and it leaves out today and any day before counting began.
- The seven-day average covers only whole days counted, so a new install no longer shows a rising trend that is not there and the line no longer dips at today, and its key shows only when the line is drawn. Each point averages the week up to its day, reaching back before the chart's first day where needed, so once five whole weeks have been counted the line starts on the chart's first day rather than its seventh. The chart's scale takes in the line as well as the bars, so a heavy day just before the chart cannot push those first points past its top.
- Hovering over a day in the last 30 days that came before Bytemeter started counting says so, rather than showing it as a day with no traffic.
- Chart axes use two decimals where one would round, so a 2.5 GB axis marks its middle line 1.25 GB.
- A chart with nothing on it yet, such as today's just after midnight or every chart on a new install, draws its baseline alone rather than an axis from 0 B to 1 B, and the heatmap's key names no top figure until there is one.
- On a billing cycle, the second Top talkers table is this cycle, and Month by month and the CSV export name each cycle by the day it starts, such as 15 Aug 2026, not by the month it starts in.
- Once Month by month has more bars than its labels fit under, it labels every second bar, or fewer, counting back from the current month or cycle so it always has its label, and more than a year of billing cycles, or a long history of months, never runs its dates together.
- Per interface and Per network say they cover the last 30 days, and the idle note says that mouse input counts too.
- Every chart has a name a screen reader announces, with both figures for the idle split, and a process name cut short shows in full on hover.
- Muted text is a lighter grey, which meets the WCAG AA contrast for small text on the page.
- Recent events read in plain words: each has a label such as Asleep, Restart or New interface, and a gap says how long it lasted and how much traffic was spread across it, in place of the raw event names and byte counts.

### Counting and accuracy

- The database moves to schema version 3 the first time this version opens it, adding each row's estimated bytes and filling them in from the rows already marked estimated, so every existing figure reads exactly as before; an older build can still open the file afterwards, but traffic it then spreads across a gap, and hours its tidy up collapses, read as measured once this version is back, and its `--demo` refuses the file.
- Estimated traffic is kept as an exact byte count, so an hour collapsed after 90 days no longer counts all its traffic as estimated because one minute in it was spread, which made Month by month overstate the estimated share, and the bytes measured in the minute a Mac wakes no longer count as estimated either.
- Per-app figures leave out loopback traffic, which never leaves the Mac, so a local development server, a database or a VPN client's local proxy can no longer top Top talkers, and a `nettop` run takes hundredths of a second rather than about five.
- Per-app sampling switched off and on again starts afresh, instead of booking everything the apps did while it was off into one minute, and with the clock set back it files its rows no earlier than the last reading, as the interface counts already did.
- A stand-in that macOS can give in place of a Wi-Fi network's name, such as Loading..., is recorded as Unknown network rather than as a network of its own, and minutes already recorded under one read as Unknown network on the dashboard and in the CSV export.
- Traffic spread across a sleep is recorded as idle, because nobody can use a sleeping Mac, rather than taking the flag of the moment it woke; the minute it woke in still counts as active if someone was there.

### Project

- The dashboard page and its CSV export are a library of their own, `BytemeterDashboard`, built from Foundation and the engine alone, so the self-test can check the page and another platform could show it.
- The self-test runs 915 checks, up from 526, in one file per subject, and builds a dashboard and reads the page and the CSV, so the promise that the page fetches nothing is checked on every run.
- CI checks out with `actions/checkout` v7 and holds read-only access to the repository, which is all it needs.
- CI builds the app bundle in a fresh clone of the commit under test, so nothing untracked and no build output from its earlier steps can help it.
- CI builds the demo dashboard from the synthetic database on every push, and fails if the page has a script or names a web address.
- The stated minimum is macOS 13.5 with the Command Line Tools 15 or later, because both install routes build with Swift 5.9, which needs them.

## 1.0.0, 6 October 2026

First public release. Bytemeter was built as a personal utility in September 2026; this release packages it so anyone can build and run it.

### The menu bar

- One total in the menu bar, with monospaced digits so the width does not jitter. Right-click, a two-finger click or a Control-click cycles it through today, this week, this month and all time, and the choice persists. A left-click opens the menu.
- A live-speed toggle shows the current rate beside the total, never in place of it.
- A menu with totals (today, yesterday, this week, last 7 days, this month, last 30 days, and all time with its start date and day count), averages per hour and per day, a month-end projection, the peak hour, the peak day, and top talkers per app.

### The dashboard

- One dark, self-contained HTML page, regenerated on each open, with hand-rolled inline SVG and native tooltips. Zero JavaScript, zero network requests.
- Set in Fraunces and Inter Tight, the same pair as Tokenmeter. Both fonts travel inside the page under the SIL Open Font License, so it still fetches nothing.
- Seven sections: today by hour, the last 30 days with a rolling 7-day average, a day-against-hour heatmap, top talkers, idle against active, per interface and per network, and month by month once a second month begins. A CSV export sits beside it.

### Counting and accuracy

- Reads the interface MIB through `sysctl`, not `getifaddrs`, whose 32-bit counter wraps every 4.29 GB. Values match `netstat -ib` to the byte, with the 32-bit counters kept as a wrap-aware fallback.
- Polls every 5 seconds into minute buckets; every larger figure is computed from them at query time, so no two figures disagree.
- Counts only physical interfaces, so a VPN, bridge, AirDrop or loopback is never double-counted. Decimal units throughout.
- A counter that falls is treated as a reset, never negative traffic. The kernel's boot session id tells a reboot, after which the bytes since boot are counted, from an interface reset, after which nothing is booked.
- Sleep traffic is counted, but its timing is spread across the minutes of the gap and marked as estimated, drawn hatched on the dashboard, so manufactured shape is never shown as measured fact. Totals are unaffected.
- Per-app figures come from `nettop` and under-report rather than over-report; the interface counters are the source of truth.

### Privacy

- No network requests of any kind. Everything stays in a local SQLite database, and the dashboard fetches nothing when opened.
- Wi-Fi network name capture is off by default and never touches Location Services until it is switched on.

### Project

- Install with Homebrew (`brew tap adi-debug-source/bytemeter https://github.com/Adi-debug-source/bytemeter`, then `brew install adi-debug-source/bytemeter/bytemeter`, then `bytemeter-setup`) or from a clone (`./install.sh`). Both build on your own Mac, so the app is not quarantined and opens without a warning. `--uninstall` keeps your data.
- A self-test executable, 526 checks and no XCTest, runs in CI on every push, which also builds the app bundle from a clean checkout and verifies its signature.
- MIT licence.
