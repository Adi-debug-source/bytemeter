# Bytemeter

A menu bar app that keeps track of how much data this Mac uses. It runs all the
time, counts every byte in and out of the physical network interfaces, and shows
today, this week or this month in the menu bar.

## Running it

The app is installed at `~/Applications/Bytemeter.app` and started at login by
`~/Library/LaunchAgents/io.github.adi-debug-source.bytemeter.plist`, which also restarts it if it dies.

- **Click** the menu bar figure to cycle today, this week and this month.
- **Right-click** (or control-click) for the menu: totals, averages, the
  projection, peak hour and day, top talkers, the live speed toggle, the
  dashboard and Preferences.

Data lives in `~/Library/Application Support/Bytemeter/bytemeter.db`.

## Building

There is no full Xcode on this machine, only Command Line Tools, so there is no
`.xcodeproj` and no `xcodebuild`.

```
swift build -c release            # build
swift run -c release BytemeterSelfTest   # run the checks
```

To reinstall after a change:

```
cp .build/release/Bytemeter ~/Applications/Bytemeter.app/Contents/MacOS/Bytemeter
codesign --force -s - ~/Applications/Bytemeter.app
launchctl unload ~/Library/LaunchAgents/io.github.adi-debug-source.bytemeter.plist
launchctl load   ~/Library/LaunchAgents/io.github.adi-debug-source.bytemeter.plist
```

`Bytemeter --dashboard [folder]` rebuilds the dashboard from an existing database
and prints where it landed, without starting the menu bar app.

## How it is put together

Two targets, and the split is deliberate:

1. **BytemeterCore** is the engine: reading interface counters, working out deltas,
   spotting resets, bucketing by minute, the SQLite schema, every aggregation
   query and all the formatting. It imports nothing macOS only, so an iOS
   version can use it untouched.
2. **Bytemeter** is the macOS app: the menu bar item, `nettop` sampling, the
   dashboard generator, preferences, sleep and wake handling.
3. **BytemeterSelfTest** is a plain executable rather than an XCTest target, because
   XCTest cannot be resolved with Command Line Tools alone.

## The counting rules

1. Interface counters are read every five seconds and the difference goes into a
   one minute bucket. Every other figure is worked out from those buckets at
   query time, so no two figures can disagree.
2. The last raw reading is saved after every sample. On launch the live counter
   is compared against it, so traffic that happened while the app was not
   running is picked up rather than lost.
3. A counter that falls is a reboot, not traffic. The baseline moves and nothing
   is recorded, so there is never a phantom multi gigabyte spike.
4. On wake, the delta covers the whole sleep. It is spread evenly over the
   minutes it spans and an event row records the gap.
5. Only physical interfaces (`en0` and friends) are counted. A VPN's `utun`
   interface carries the same bytes as the Wi-Fi underneath it, so counting both
   would double everything.
6. Units are decimal throughout: 1 GB is 1,000,000,000 bytes, the way routers
   and internet providers count.

## Where the counters come from

Not `getifaddrs`. On this machine `getifaddrs` hands back a `struct if_data`,
whose `ifi_ibytes` is a `u_int32_t`, and en0 passed 4.29 GB since boot long ago,
so that field has wrapped and reads about 4.29 GB low. The route socket
`NET_RT_IFLIST2` path returns the same truncated value.

Bytemeter reads `net.link.generic.ifdata.<index>.general` instead, which fills a
`struct ifmibdata` whose `ifmd_data` really is an `if_data64`. Its value matches
`netstat -ib` exactly. There is still a wrap aware fallback to the 32 bit
counters in case the MIB is ever unavailable.

## What it does not claim

Per-app figures come from `nettop`, which reports totals per process. A process
that quits between samples takes its last few seconds with it, and a process
seen for the first time is baselined rather than having its whole lifetime
counted. So top talkers is a good guide, not an exact split, and it will not
reconcile exactly with the interface totals. The interface counters are the
source of truth. The dashboard says so on the page.

Wi-Fi network names need Location Services on this version of macOS, so that is
behind a preference which is off by default. While it is off, CoreWLAN is never
touched and no permission prompt can appear.
