# Privacy Policy — Localhost

_Draft. Have a lawyer read this before publishing. Placeholders in **bold**._

**Last updated: 10 September 2026**

Localhost is a macOS utility published by Creative Oak ApS, **[CVR number and
registered address]**.

## The short version

Localhost sends nothing about you anywhere. It has no analytics, no telemetry,
no crash-reporting service, no licence server, and no account. Its one network
connection is a check for updates, described below, which you can turn off.

That is not a promise about intent; it is a property of the program, and it is
checkable — the source is public. Apart from the update check, the only socket
it opens is a Unix domain socket to Docker on your own machine, which is
inter-process communication and never leaves the Mac.

## What Localhost reads

To do its job it reads, from your Mac only:

- The list of TCP ports being listened on, and which process holds each one.
- For your own processes: the name, process ID, start time, command-line
  arguments, executable path and working directory.
- The project files at that working directory — `package.json`, `Cargo.toml`,
  `pyproject.toml`, `go.mod` — and `.git/HEAD`, to name the project and branch.
- If Docker is running, the list of containers and the ports they publish.

None of this is transmitted, recorded to a file, or retained after the panel
closes. It is read when the panel is open and discarded when it is not.

## What Localhost stores

Four things, in the app's own preferences on your Mac:

| Stored | Why |
| --- | --- |
| Your licence key | So you enter it once |
| The date of first launch | To count the trial |
| Your chosen browser and terminal | So "Open in…" remembers |
| The filename of the last crash report you were shown | So you are not asked twice |

There is no other storage, and no copy of any of it elsewhere.

## Licence keys

Licence keys are verified on your Mac using cryptography, not by contacting a
server. Activating Localhost involves no network request, so we do not learn
when, where, or how often you use it — we cannot.

## Updates

When you open the panel, at most once a day, Localhost downloads a small file
from GitHub (github.com, operated by GitHub, Inc.) listing the latest version.
If there is a newer one, it asks before downloading it, also from GitHub. You
can check by hand instead: turn off **Check for Updates Automatically** in the
gear menu.

The request carries the app's name and version in its user agent, and like any
connection it reveals your IP address to GitHub. Localhost sends nothing else
— no identifier, and no information about your Mac or what is running on it.
We do not receive these requests and cannot see them; GitHub's own privacy
statement governs what GitHub keeps.

## Crash reports

macOS writes crash reports to your own Mac whether or not Localhost is running.
If Localhost notices one of its own, it offers to copy it into an email for you
to send. Nothing is sent unless you choose to send it, and it is your ordinary
email — not an upload.

A crash report contains the state of the program when it stopped. Please read
it before sending if that concerns you.

## Your rights

Since no personal data reaches us, there is nothing for us to disclose, correct
or delete. If you email support, we hold that correspondence — write to
**support@creativeoak.dk** to have it deleted.

## Changes

If this policy ever changes, the version shipped with each release is the one
that applies to it.
