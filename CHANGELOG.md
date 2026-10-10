# Changelog

## Unreleased

### The menu bar

- On the first day of a month or billing cycle, the projection runs the last 24 hours on to the cycle's end, instead of treating a few hours as a whole day, and with under a day counted it says it is too early to project, in the menu and on the dashboard.
- No figure prints as 1000 of a smaller unit: 999.6 MB reads 1.00 GB, so the menu bar no longer shows 1000 MB as the day crosses 1 GB.

### The dashboard

- The heatmap is an average over the last four whole weeks, so every weekday is counted the same number of times, and it leaves out today and any day before counting began.
- The seven day average covers only whole days counted, so a new install no longer shows a rising trend that is not there and the line no longer dips at today, and its key shows only when the line is drawn.
- Hovering over a day in the last 30 days that came before Bytemeter started counting says so, rather than showing it as a day with no traffic.
- Today is compared with yesterday at the same time of day, so an ordinary morning no longer reads as down on yesterday.
- Chart axes use two decimals where one would round, so a 2.5 GB axis marks its middle line 1.25 GB.

### Counting and accuracy

- Per-app figures leave out loopback traffic, which never leaves the Mac, so a local development server, a database or a VPN client's local proxy can no longer top Top talkers.
- Per-app sampling switched off and on again starts afresh, instead of booking everything the apps did while it was off into one minute, and with the clock set back it files its rows no earlier than the last reading, as the interface counts already did.
- Traffic spread across a sleep is recorded as idle, because nobody can use a sleeping Mac, rather than taking the flag of the moment it woke; the minute it woke in still counts as active if someone was there.
- Estimated traffic is kept as an exact byte count, so an hour collapsed after 90 days no longer counts all its traffic as estimated because one minute in it was spread, which made Month by month overstate the estimated share, and the bytes measured in the minute a Mac wakes no longer count as estimated either.

## 1.0.0, 6 October 2026

First public release. Bytemeter was built as a personal utility in September 2026; this release packages it so anyone can build and run it.

### The menu bar

- One total in the menu bar, with monospaced digits so the width does not jitter. Right-click, a two-finger click or a Control-click cycles it through today, this week, this month and all time, and the choice persists. A left-click opens the menu.
- A live-speed toggle shows the current rate beside the total, never in place of it.
- A menu with totals (today, yesterday, this week, last 7 days, this month, last 30 days, and all time with its start date and day count), averages per hour and per day, a month-end projection, the peak hour, the peak day, and top talkers per app.

### The dashboard

- One dark, self-contained HTML page, regenerated on each open, with hand-rolled inline SVG and native tooltips. Zero JavaScript, zero network requests.
- Set in Fraunces and Inter Tight, the same pair as Tokenmeter. Both fonts travel inside the page under the SIL Open Font Licence, so it still fetches nothing.
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

- Install with Homebrew (`brew install adi-debug-source/bytemeter/bytemeter`, then `bytemeter-setup`) or from a clone (`./install.sh`). Both build on your own Mac, so the app is not quarantined and opens without a warning. `--uninstall` keeps your data.
- A self-test executable, 526 checks and no XCTest, runs in CI on every push, which also builds the app bundle from a clean checkout and verifies its signature.
- MIT licence.
