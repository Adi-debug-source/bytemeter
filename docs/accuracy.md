# How accurate Bytemeter is

Bytemeter has one claim: its figures match what the Mac's network interfaces carried. This page says how far that holds, where it can miss bytes and by how much, and what it does not claim. How the counting works is in [How it works](how-it-works.md).

## What it measures, and how closely

Bytemeter aims to be exact about what it can measure, and plain about what it cannot.

- **The count is exact.** Bytemeter records exactly what the kernel's own interface counters say, to the byte. On the Mac it was developed on, the sum of every saved minute since the last reboot matched the kernel counter's own movement over the same period to 0 bytes in and 0 bytes out, checked repeatedly over several days, across two reinstalls and a database migration.
- **Where it can miss bytes, and by how much.** The gaps are small and bounded:
  1. the last few seconds before a shutdown or restart, at most one 5-second reading, because the counter starts again from zero at boot;
  2. an interface reset that is not a reboot, up to one 5-second reading, because there is no start time to measure from;
  3. traffic between quitting Bytemeter and restarting the Mac before you open it again. Quitting on its own loses nothing, because the next launch picks up everything since the last reading, and a crash loses nothing either, because it restarts within seconds and does the same;
  4. an adapter, dock or tethered phone unplugged and plugged back in while Bytemeter is not running. Its counter starts again from zero when it is plugged in, and with no reading in between Bytemeter cannot tell that from a counter that kept going. It then misses what the interface carried between its last reading and the unplug, and either everything since the replug, if the new count in either direction is below the old one, or as much as the old count, if neither is. The same applies, usually to a few seconds, when it is plugged in while the Mac sleeps;
  5. traffic from before Bytemeter was first installed, which is not counted by design.
- **Timing.** Figures are kept per minute. A reading that straddles a minute boundary lands in the later minute, so a minute can be out by at most 5 seconds' worth of traffic, and hourly and daily figures the same way, only at their edges. Sleep periods are the exception: the bytes are exact, but their timing is spread evenly and marked as estimated. And if the Mac's clock is ever set ahead by hand and then corrected, new traffic is filed under the later time until the clock catches up; nothing is lost or counted twice.
- **Rounding on screen.** The menu and the dashboard round for readability: under 10 GB they show two decimals (3.21 GB, so plus or minus 5 MB), and from 10 GB up one decimal (plus or minus 50 MB). The menu bar figure is shorter, so its width stays steady: one decimal in GB, and whole numbers of MB, kB or bytes below that. A figure never shows as 1000 of a smaller unit. The database and the CSV export keep exact byte counts.
- **Per-app figures are a guide, not an exact split.** They come from `nettop`, leave out loopback traffic, which never leaves the Mac, and only ever under-report. The interface bytes no app is credited with belong to processes that exited between samples, and to traffic `nettop` does not attribute.
- **Traffic inside your own network counts too.** The interface counters cannot tell internet traffic from traffic to another device at home, so Time Machine to a network disk, a NAS, AirPlay, screen sharing and copies between Macs all count, though none of it reaches your provider.
- **Against a provider's or router's figure, expect small differences, not a match to the byte.** A provider or router counts at its own point in the network and in its own way, and a router counts every device on the connection, while Bytemeter counts only what this Mac's own interfaces moved.
- **Units are decimal** (1 GB = 1,000,000,000 bytes), as providers count; see [Counting](how-it-works.md#counting).

## What it does not claim

Bytemeter is careful about saying what it knows and what it does not.

- **Per-app figures under-report.** They come from `nettop`, and a process that exits between samples takes its last few seconds with it, so a per-app total is a good guide rather than an exact split. The interface counters are the source of truth, and the two will not reconcile to the byte.
- **Sleep is counted, but its timing is estimated.** The traffic across a sleep is real, so it is counted, but its timing is not observed. Bytemeter spreads it evenly across the gap and marks those minutes as estimated. The dashboard draws them hatched, with a one-line key, and its tooltips say how much of a figure is estimated. Totals never change because of this.
- **"All time" means since Bytemeter started counting**, not since the Mac was new. Traffic already on the counter when Bytemeter first runs has no timestamps, so it is left out rather than folded in to flatter the figure.
- **Reboots are told from interface resets.** Bytemeter uses the kernel's boot session id, which changes only at a reboot. After a genuine reboot, everything on the counter since boot is counted. After an interface reset without a reboot, the baseline moves and nothing is booked, because there is no start time to measure from.
- **Weeks start on Monday, dates read day first, and the clock is yours.** Bytemeter uses ISO 8601 weeks and writes dates day first whatever your Mac's region is set to, by choice, so a figure means the same thing on every machine. Daily, hourly and heatmap figures track local time correctly across clock changes, including half-hour time zones.
- **It is not the first of its kind.** Other menu bar data meters exist, some with alerts and per-app limits. Bytemeter's part is being exact, open and private.

[Back to the README](../README.md)
