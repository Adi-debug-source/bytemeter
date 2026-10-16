# Security

Bytemeter is a menu bar app that counts network traffic and keeps everything
on the Mac it runs on. It makes no network requests, reads no file outside its
own data folder, and runs no command but `nettop`. A report that it does any
of those things, or that someone else's data can reach its database, its
dashboard or its CSV export, is a security report.

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's private
vulnerability reporting instead: on the repository's Security tab, choose
Report a vulnerability. That reaches the maintainer alone.

Say what you found, how to reproduce it, and which version: `VERSION` in the
repository, or for the installed app
`plutil -extract CFBundleShortVersionString raw -o - ~/Applications/Bytemeter.app/Contents/Info.plist`. You will get a reply
within a week, and a fix, when one is needed, in the next release, with
credit if you want it.

## What is in scope

- Anything that makes Bytemeter send data off the Mac.
- A way to read or change the database, the dashboard or the export from
  another user account on the same Mac.
- A process name, a network name or any other outside text that breaks the
  dashboard's HTML or makes the CSV export run as a spreadsheet formula.
- A crash or a wrong figure caused by crafted input: a counter reading, a
  clock change, a database from another version.

## Supported versions

The latest release only. Both install routes build from source, so a fix is
available as soon as it is tagged.
