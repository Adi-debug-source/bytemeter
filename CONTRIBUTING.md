# Contributing

Thank you for looking. Bytemeter's only claim is that its figures match what the network interfaces carried, so the most useful thing anyone can send is a check against reality.

## Three ways to help, smallest first

1. **Compare a figure with the kernel's own.** `netstat -ib` prints the counters Bytemeter reads. If a total in the menu or on the dashboard does not move with them, open an issue with the version (`VERSION`), what the menu or dashboard showed, and what you expected.
2. **Report a gap that is not written down.** [How accurate it is](docs/accuracy.md) lists every known gap with its size. A miss that is not on that list, or is larger than it says, is a bug.
3. **Send a change.** [MAINTENANCE.md](MAINTENANCE.md) says how the parts fit together, and covers the login item and the release steps. [CHANGELOG.md](CHANGELOG.md) says what each version changed and why.

Never attach your real database, dashboard or CSV export to an issue: they show your apps, your network names and when you were online. `Scripts/make_demo_db.py` writes an invented month if you need one.

## Before you open a pull request

```bash
swift run -c release BytemeterSelfTest
```

It needs only the Command Line Tools. Run it before and after your change; it must pass.

- **A fix for a counting bug comes with a check that fails without it.**
- **The engine stays free of AppKit,** so the self-test can check it and another platform could use it untouched.
- **The dashboard stays free of scripts and web addresses.** CI fails the build if either appears.
- **One change per pull request,** titled in the conventional form with plain words: `fix(menu): the counter no longer resets after sleep`.

[AGENTS.md](AGENTS.md) holds the working rules for coding agents on this repository; they are a fair summary of the standards for people too.

## Security

Please report a vulnerability privately, as [SECURITY.md](SECURITY.md) describes, not in a public issue.
