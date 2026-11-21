# A guide to Bytemeter

Everything the menu bar item, the menu, Preferences and the dashboard show, in full. The [README](../README.md) has the short version.

## The menu bar

The menu bar item shows one total, with monospaced digits so its width does not jitter as the figure changes.

- Left-click opens the menu.
- The four period rows in the menu choose the total: Today, Last 7 days, Last 30 days or All time. The last 7 and 30 days count today as one of their days, from midnight, whatever the billing cycle. The one showing carries a tick; click another, or reach it with the arrow keys or VoiceOver. Right-click, a two-finger click or a Control-click on the figure steps through the same four, as the item's tooltip says. The choice is kept across restarts.
- Live speed is a switch in Preferences. When it is on, the current download rate appears beside the total, never in its place, and at the right of the menu's header.

The menu holds, from the top:

- **Data used**, the header, with the live download rate at its right while live speed is on.
- A **warning line**, only when something is wrong: if recording stops because the database cannot be written, for example on a full disk, it says so and since when. On a new install, until the first figures arrive, it says counting has started.
- **Four period rows:** Today, Last 7 days, Last 30 days and All time, each with one figure, its download, as the menu bar shows. Hover over a row for where it starts, for example 'From 23 Sep', and for all time its start date and day count, for example 'Since 1 Jan 2026 · 90.0 days counted'.
- **One line about the month:** a month-end projection, download and upload combined as a provider counts them, for example 'On track for 100.8 GB in total this month'. It carries the month's rate so far on to its end. On the first day of a month it runs the last 24 hours on instead, and with under a day counted at all it says it is too early to project. When a cap is set, the cap takes its place: '97.1 of 150.0 GB, 2 days left' over a thin bar. Every other figure in the menu is download; the projection and the cap add the two together, and their tooltips say so.
- **Top Apps Today**, a submenu: the five apps that used the most today, by download, each with a bar for its share and a plain name where the process has one ('Web content (WebKit)', 'iCloud', 'Background downloads'). It is a guide, not an exact split, and is left out while per-app sampling is off.
- **Open Dashboard** (⌘D), **Preferences…** (⌘,) and **Quit Bytemeter** (⌘Q).

This week, this month, upload, yesterday, the busiest hour and the per-app upload are on the dashboard.

## Preferences

Preferences, from the menu, has five settings:

1. **Live speed in the menu bar**, beside the total and never in its place.
2. **Per-app sampling with `nettop`**, on by default. While it is off, nothing new is recorded per app, the menu leaves out Top Apps Today, and the dashboard's Top talkers says sampling is off.
3. **The Wi-Fi network name**, off by default. It needs Location Services, for the reasons under [Privacy](../README.md#privacy). While it is on and macOS allows it, the dashboard splits traffic by network.
4. **A monthly cap in GB**, off by default. The menu shows what is used of the cap over a bar, with the days left or how far over it the month is, and the dashboard a Monthly cap panel with the percentage, what is left and how many days are to go. It counts download and upload together, as a provider does, over the month or the billing cycle below. It is a figure to watch, and sends no alert.
5. **The day the billing cycle starts**, from 1 to 28. 1, the default, means calendar months. On any other day, this month becomes this cycle in the menu and on the dashboard, including the projection and Month by month.

## The dashboard

Open Dashboard writes one dark, self-contained HTML page and opens it. It is made again each time, with hand-rolled inline SVG and native SVG tooltips: zero JavaScript, zero network requests. A CSV export sits beside it as a real file.

The top of the page gives today's download, compared with yesterday at the same time of day, beside this week, the last 7 days, this month, the last 30 days, the projection and all time, then a Monthly cap panel when a cap is set.

Seven sections, and an eighth once a second month begins:

1. Today, by hour.
2. The last 30 days, with a seven-day average of whole days counted, which stops at yesterday because today is not over.
3. A day-of-week against hour-of-day heatmap, an average over the last four whole weeks, so every weekday counts the same.
4. Top talkers, per app.
5. Idle against active.
6. Per interface, each under the name macOS gives its port, such as Wi-Fi (en0) or iPhone USB (en7), so a phone sharing its connection over a cable is told apart from the Wi-Fi.
7. Per network.
8. Month by month, once a second month begins.

The footer says how the figures are made and lists recent events in plain words, such as a sleep with how long it lasted and how much traffic was spread across it.

![The last 30 days, with a seven-day average](screenshots/dashboard-thirty-days.png)

![The day-against-hour heatmap](screenshots/dashboard-heatmap.png)

[Back to the README](../README.md)
