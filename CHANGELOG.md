# Changelog

## 1.4.1, not yet released

A wording release. No figure changes, and the self-test runs the same 1,309 checks as 1.4.0.

- The dashboard's footer says 'Nothing here has left it' where it said 'the machine'. The README's tour clip is made again, so its last frame shows the new footer.
- The README and the accuracy page say Mac where they said 'the machine', quoted words take single quotes, and the README links Tokenmeter.
- CONTRIBUTING.md and an issue form for a figure that looks wrong are new, and the README's contributing section points at them.
- For contributors: a verify skill, `.claude/skills/verify/SKILL.md`, smoke-tests the app on synthetic data before a commit, and the release steps in MAINTENANCE.md use `vX.Y.Z` and `gh release create --verify-tag`.

## 1.4.0, 21 November 2026

A shorter menu. It held 33 lines and 35 figures; it now holds ten rows that say how much has been used, and the rest is one click deeper or on the dashboard. No figure changes: the CSV and the dashboard's figures are as before for the same database. The self-test runs 1,309 checks, up from 1,280.

- The menu opens with Data used, then Today, Last 7 days, Last 30 days and All time, one figure each, the download, as the menu bar shows. These are Tokenmeter's four, so the two apps read alike; this week and this month stay on the dashboard. The one in the menu bar carries a tick, and clicking another puts it there, which replaces the Menu bar shows submenu. Each row's tooltip says where it starts.
- The right-click on the menu bar figure steps through the same four. A saved this week or this month comes back as the last 7 or the last 30 days.
- Under them, one line: where the month is heading, or, with a cap set, what is used of the cap and the days left, over a thin bar in the dashboard's teal.
- Top Apps Today is a submenu, with today's top five apps by download, a bar for each and plain names for three background processes: Web content (WebKit), iCloud and Background downloads. Any other process keeps its own name. The submenu is left out while per-app sampling is off.
- This week, this month, upload, yesterday, the four averages and the two peaks leave the menu. This week, this month, upload, the busiest hour today and all time's daily average are on the dashboard.
- The live rate, while live speed is on, sits at the right of the menu's header. Its switch is in Preferences, and the right-click hint is in the menu bar item's tooltip, so both leave the menu.
- The commands are in title case: Open Dashboard, Preferences…, Quit Bytemeter.
- The rows are 13 points, the size of the commands below them, and every figure ends on one right edge. The four period rows are standard menu items, so Return, the tick and VoiceOver work as they do anywhere in macOS.
- The README's menu picture, the hero and the social preview show the new menu and its four periods, from the synthetic month.

## 1.3.1, 20 November 2026

A security review, a tidy of the code and a new front page. No figure changes, and the CSV is byte for byte as before for the same database. The dashboard page differs by one line in its head, below, and draws the same pixels. The self-test runs 1,280 checks, up from 1,278.

- A process whose name holds commas can no longer put figures of its own into another app's row in Top talkers. `nettop` does not quote a name, so the two byte counts are now read from the end of each row, where they were read from the start. The interface totals were never affected.
- The dashboard page carries a Content-Security-Policy that refuses scripts and anything fetched. Every outside text on the page was already escaped, and CI already fails on a script or a web address; the policy means a slip in either would still do nothing.
- `install.sh` stops if `HOME` is empty, `/` or not a folder, where it would have gone on to remove `/Applications/Bytemeter.app`.
- CI uses its one action by commit, not by a tag that can move, leaves no token in the checkout, and parses every shell script. Dependabot keeps the pinned commit current.
- The code is tidier with no change in behaviour: the choice between 'This month' and 'This cycle' is made in one place, where it was typed out six times; the projection no longer returns a date nobody read; and a few bare numbers have names.
- The README has a new first screen, a picture of the menu beside the dashboard, and two clips made from the synthetic month by `Scripts/make_clips.sh`. Its long reference sections moved, word for word, to `docs/guide.md`, `docs/accuracy.md` and `docs/how-it-works.md`. The pictures moved to `docs/screenshots/`.
- `Scripts/make_art.sh` draws the README's hero and a social preview for GitHub from two pages in `docs/art`, and `Scripts/snapshot.swift` takes `--width` for them.
- MAINTENANCE.md opens with what to read for which job and a release at a glance. Its steps are unchanged.

## 1.3.0, 20 November 2026

Leaner while it sits in the menu bar, with two small additions. No figure changes: the CSV is byte for byte as before for the same database, and so is the dashboard page apart from the port names below. The self-test runs 1,278 checks, up from 1,193.

- Bytemeter takes far less of the processor while idle. Watched for two minutes on the Mac it was developed on, it used 0.05% of one core with all time in the menu bar, where 1.2.5 used 0.46%; 0.07% with today, where it used 0.22%; and 0.66% with the live speed on, where it used 1.37%. Memory is unchanged at about 12 MB. Three things did it:
  - A reading asks the kernel for its list of interfaces once. It used to ask once for the names and again for every interface's index, six times on a Mac with five ports, and fetching that list was most of what the app spent. The counters themselves are read exactly as before, from the 64 bit interface MIB.
  - The menu bar figure is a running total. It was added up whole after every reading, 15.7 milliseconds for all time on 90 days of minute rows. The hours that are over are now added up once and kept, and only the current hour is read each time, 22 microseconds. The kept sum is thrown away by anything that can change a row in it, and the self-test holds the figure to the total read whole through every kind of write.
  - The menu bar item is drawn again only when its words change, and a per-app sample is written as one commit, where it was one for every app.
- The menu has Menu bar shows, with Today, This week, This month and All time and a tick on the one showing, so the total in the menu bar can be seen and chosen from the keyboard or with VoiceOver. The right-click still steps through them.
- The dashboard names each interface as macOS names its port, such as Wi-Fi (en0) or iPhone USB (en7), so a phone sharing its connection over a cable is told apart from the Wi-Fi. The CSV keeps the kernel's names, and so does `--dashboard` on a folder given on the command line.
- A read of the database that ends on an error is reported as one, where it passed for the end of its rows.
- `swift run -c release BytemeterSelfTest --measure` times the engine's repeated work on 90 days of rows, and `Scripts/measure_idle.sh` measures the running app's processor time and memory against a demo database in a home folder of its own, so the installed app and its data are never touched.
- `--demo` takes `--open-menu`, and `Scripts/menu_shots.swift` uses it to take the README's picture of the menu, which was a capture by hand.
- The README is rewritten: what Bytemeter does and how to install it come first, with a section for anyone reading the code.

## 1.2.5, 3 November 2026

Three gaps the reviews of 1.2.4 found, with no change to any figure. The self-test runs 1,193 checks, up from 1,166.

- `--dashboard` waits for the app to finish bringing the database up to date, where it gave up after 3 seconds and could fail as busy behind a slow first upgrade of a large file. An open that finds the file out of date now waits up to a minute for the write lock; a file already up to date, and every statement after the open, still waits 3 seconds at most. The app's own lock is still not taken, because the app holds it for as long as it runs, so `--dashboard` keeps working while the app is up.
- `--demo` says the right thing about a database it cannot read. A file from an older build is still told to run `--dashboard` on its folder; a file from a later Bytemeter is told to update this one, since `--dashboard` cannot help with that.
- The self-test checks the query plans of the statements the engine really runs, caught as they are prepared, where it checked copies of them that an edited query would have left behind.

## 1.2.4, 2 November 2026

Leaner, with no change to any figure. The dashboard builds about a quarter faster, and the database drops two indexes that repeated what its keys already do. The self-test runs 1,166 checks, up from 957.

- The dashboard reads its minute rows once, where it read the same rows three times, and works out today's hours once. The calendar keeps its date formatters, one per pattern and time zone, where it made a new one for every label. On five weeks of history the dashboard went from 135 to 97 milliseconds, with the page and the CSV byte for byte as before.
- The database is at version 4: the indexes on the minute of each reading and each app's reading are gone, since each table's key already starts with the minute and every query finds its rows through it just as fast. A new database is about a fifth smaller, and each reading, every five seconds, updates two indexes rather than four. An existing database keeps its size and fills the freed space before it grows. 1.2.3 still opens a version 4 database, so going back is safe.

## 1.2.3, 2 November 2026

The menu bar tooltip, which 1.2.2 did not fully fix, and some tidying. The self-test runs 957 checks, up from 951.

- The menu bar item's tooltip no longer pops up away from the item. 1.2.2 stopped it changing while the pointer was elsewhere, but it still appeared mid-desktop on its own, most likely when the figure in the menu bar changed width. The item now carries a tooltip only while the pointer is on it, so there is nothing for macOS to show anywhere else.
- The dashboard's options come from one place, for the menu's Open dashboard and for `--dashboard`, so the two pages cannot differ.
- Two functions only the self-test used move out of the engine into the self-test, and the self-test shares its helpers instead of repeating them.
- The README names the menu items as the menu does, and MAINTENANCE says the tag goes on the commit that dates the changelog.

## 1.2.2, 2 November 2026

An audit of 2 November 2026: the menu bar tooltip that popped up across the desktop, the cap typed with a decimal comma, and a guard on the demo script. The self-test runs 951 checks, up from 919.

- The menu bar item's tooltip no longer pops up across the desktop. The item set a new tooltip every time its figure changed, up to once a second, and once its tooltip had been seen, macOS could show each new one at the pointer, wherever it was. A new tooltip now waits until the pointer is on the item and goes in then, so it shows where it belongs and with the current figures.
- On a billing cycle, the menu bar item's tooltip calls the month figure This cycle, as the menu does, rather than This month.
- A monthly cap typed with a decimal comma, as much of Europe writes one, is read as a decimal: 1,5 is 1.5 GB, where it was stored as 15 GB. So are 0,250 and ,500, since no thousands group follows a lone 0. 1,000 is still a thousand.
- `Scripts/make_demo_db.py` refuses the folder where the app keeps its real data, however it is spelt, so `--force` can never delete a real database. CI checks it.
- On the dashboard a figure stays on the same line as its unit, so a sentence no longer breaks between 2.11 and GB. The README's dashboard image, which showed that break, is made again from the same demo.
- The README and MAINTENANCE say what an adapter, dock or tethered phone unplugged and plugged back in while Bytemeter is not running can cost, where the README said quitting lost nothing.

## 1.2.1, 16 October 2026

A review of 16 October 2026: the cap bar, the images, the icon, the ignore list and a security policy.

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
