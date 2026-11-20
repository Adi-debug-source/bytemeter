# How Bytemeter works, and why

## Counting

1. **The interface counters are read every 5 seconds**, each reading diffed against the last, and the difference added to a one-minute bucket. Everything above a minute (hour, day, week, month, the averages, the projection) is computed at query time from those buckets, so no two figures on screen can ever disagree.
2. **The last raw reading is saved after every sample.** On launch the live counter is compared against the stored value, so traffic that happened while the app was not running is picked up rather than lost.
3. **A reading lower than the last one is a reset, not negative traffic.** The baseline moves and no phantom multi-gigabyte spike is booked. The kernel's boot session id, which changes only at a reboot, tells a genuine reboot (after which the bytes since boot are counted) from an interface reset (after which nothing is booked, because there is no start time to measure from).
4. **Only physical interfaces are counted**, meaning `en` followed by a number. VPN tunnels, bridges, AirDrop and loopback are all excluded, because a VPN's tunnel carries the very same bytes as the Wi-Fi interface underneath it; counting both would double every figure the moment a VPN came on.
5. **Units are decimal:** 1 GB is 1,000,000,000 bytes, the way internet providers and routers count, so the figures are in the same units as your bill.

## Where the counters come from

Not `getifaddrs`. On macOS `getifaddrs` returns a `struct if_data` whose `ifi_ibytes` is a `u_int32_t`, so it wraps every 4.29 GB, and the route-socket path `NET_RT_IFLIST2` returns the same truncated value. Either would lose roughly 4 GB at a time, silently, and every wrap would look just like a reboot.

Bytemeter reads `net.link.generic.ifdata.<index>.general` through `sysctl` instead, which fills a `struct ifmibdata` whose `ifmd_data` really is an `if_data64`. Its value matches `netstat -ib` exactly. The 32-bit counters are kept as a wrap-aware fallback for the rare case where the MIB is unavailable, and the app records which source is live.

## Staying light

The menu bar figure is asked for after every reading, so it is a running total: the hours that are over are added up once and kept, and only the current hour is read each time. The kept sum is thrown away the moment anything could have changed a row in it, and the self-test holds the figure to the same total read whole from the table, through every kind of write. A reading itself asks the kernel for its list of interfaces once.

[Back to the README](../README.md)
