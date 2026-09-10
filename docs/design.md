# Localhost — Build Plan

> Implementation design. The product brief lives in the company repository as
> `localhost.md` and stays there; see `docs/repository-conventions.md` there.
>
> **Amended by the spike (2026-09-10).** Step 1 is complete — see
> [spike-findings.md](spike-findings.md). Four things changed:
> `lsof` is dropped entirely, `sysctl(pcblist_n)` replaces libproc as the
> discovery spine, root-owned listeners turn out to be nameable, and the
> known-daemon table moves from polish into attribution. Sections below are
> updated; the reasoning is in the findings.

## The risky question — answered

Everything interesting about this app hinged on one thing: **can we reliably
read another process's working directory on current macOS?**

That is what turns

```
3000    node
```

into

```
3000    node        my-project
```

**Yes, for same-user processes, 100% of the time** — 370 of 370 on the test
machine, verified end-to-end from a real Next.js server on port 3001 through
to the label `rilo`. The project-attribution column exists, and the product is
the full-size version of itself.

## Discovery

Measured on macOS 26.6.2, 578 processes, 26 listeners:

| Approach | Median | Sees | PID |
| --- | --- | --- | --- |
| `sysctl … TCPCTL_PCBLIST` (`pcblist_n`) | 0.52 ms | every listener, all users | yes, approximate |
| libproc (`proc_pidfdinfo`) | 2.4 ms | same-user only | yes, exact |
| `lsof -i -P -n -sTCP:LISTEN` | 96 ms | same-user only | yes, exact |

**Ship `sysctl` as the spine, libproc for attribution, and no `lsof` at all.**

`lsof` is not setuid on macOS 26, so it sees precisely what libproc sees while
being 40× slower and requiring text parsing. It has no fallback value.
`LsofScanner` and its fixture test are cut from the design.

The two survivors have distinct jobs:

```
pcblist_n     → every listener: port, address, uid, pid     (the rows)
libproc       → same-user only: cwd, argv, name, start      (the project column)
proc_pidpath  → any pid, root included: executable path     (naming root rows)
```

`pcblist_n` reads XNU-private structs at offsets recovered by hexdump, so
`LibprocScanner` doubles as its oracle: at startup, cross-check `so_last_pid`
against libproc for same-user listeners. The spike scored 20/20. If that check
fails after an OS update, fall back to `pcblist64` — public structs, uid but no
PID — and root rows silently lose only their name, not their row.

## Types

```swift
struct Listener: Identifiable, Hashable {
    let port: UInt16
    let address: String          // 127.0.0.1, 0.0.0.0, ::1
    let family: Family
    let process: ProcessIdentity
}

struct ProcessIdentity: Hashable {
    let pid: pid_t
    let startedAt: time_t        // pbi_start_tvsec
    let name: String
    let executablePath: String?
    let arguments: [String]?
    let workingDirectory: String?
}
```

`startedAt` is the important one. Between the scan that drew a row and the
click that kills it, the process can exit and its PID be recycled. `(pid,
startedAt)` is a stable identity; the terminator re-verifies it immediately
before signalling and refuses if it does not match.

**Killing the wrong process because of a stale row is the worst bug this app
could ship.** It is worth a type, a test, and a re-scan on every kill.

Note that `startedAt` comes from `PROC_PIDTBSDINFO`, which is `EPERM` for
other users — so root-owned rows have no identity to verify. They are not
killable in v1 anyway, which keeps this consistent: no `startedAt`, no kill.

### Deduplication

One server usually binds IPv4 and IPv6, and sometimes several addresses, so it
appears two or three times. Group by `(pid, port)` and show one row.

## Structure

```
App/
  Ports/       Listener, PortScanning, PcbListScanner, LibprocScanner
  Processes/   ProcessDetails, ProjectResolver, ProcessTerminator, KnownDaemons
  Docker/      ContainerLabels
  UI/          MenuContent, ListenerRow, FreePortSheet
Tests/
```

Per the development principles, discovery and destruction are separate:
scanners have no way to signal a process, and `ProcessTerminator` scans only to
verify identity.

### ProjectResolver

A pure function. Walk up from the working directory looking for, in order:

1. `package.json` → its `name` field
2. `Cargo.toml`, `pyproject.toml`, `go.mod` → the package name
3. `.git` → the containing directory's name

First hit wins. If nothing matches, fall back to argv before the bare process
name — the spike showed argv is available 100% of the time and is often
self-describing (`next-server (v16.2.12)`, `Python -m http.server 31338`).
**Never invent a label.**

### KnownDaemons

Promoted out of polish, because for launchd-activated sockets `so_last_pid` is
`launchd` itself — accurate and useless. This table is the only thing that
makes those rows readable:

```
5000    ControlCenter    macOS AirPlay Receiver
                         Turn off in System Settings › General › AirDrop & Handoff
5900    launchd          Screen Sharing
                         Turn off in System Settings › General › Sharing
  88    kdc              Kerberos KDC (Heimdal)
```

Six or so entries. It is the moment the app feels like it knows something a
`lsof` wrapper does not.

## Docker

Container names are in, in v1, read-only. A single `GET /containers/json` over
Docker's Unix socket, via `NWConnection` with a `.unix` endpoint. Socket paths
to detect:

```
Docker Desktop   /var/run/docker.sock
OrbStack         ~/.orbstack/run/docker.sock
Colima           ~/.colima/default/docker.sock
```

Two rules keep this from becoming container management:

1. **We label, we never act.** No start, stop, restart, exec or logs. Ever.
2. **It degrades to nothing.** No socket, unreadable socket, or Docker not
   running means rows appear without container names. This feature can never be
   the reason the app fails.

Both rules hold, and both are tested. Rule 1 is structural: the only request
`ContainerLabels` can make is a GET of the container list, so there is no code
path that could grow a start or a stop. Rule 2 is tested against real sockets —
absent, present-but-refusing, and accepting-then-hanging — each of which must
produce an empty map in well under a second.

Measured against a live OrbStack daemon: the request costs 3-20ms, inside a
scan that must finish well within a two-second refresh.

## Interface

`MenuBarExtra` with `.menuBarExtraStyle(.window)`, because the app needs a
search field and `NSMenu` does not do that well.

If keyboard behaviour is not right — Escape to dismiss, arrows to move,
type-to-filter — drop to `NSStatusItem` with a custom panel without hesitating.
Keyboard-first is the feel of this app, and the design principles say to reach
for AppKit without guilt.

Scan when the menu opens, then roughly every two seconds while it is open, and
**never while it is closed**. A menu bar utility that polls in the background
has failed product principle 9. At 0.5 ms a scan this is free; there is no case
for caching, diffing, or a background daemon.

## Sandboxing and distribution

Inspecting and signalling other processes does not survive the App Sandbox, so:
**not sandboxed, direct distribution, notarised, hardened runtime.**

No entitlements beyond that, and — importantly — **no privileged helper**,
because v1 only signals processes you own. That removes `SMAppService`, a
helper install flow, an XPC service and a whole category of security surface.
Killing root-owned processes is a later conversation, if ever.

## Tests

- **Scanner.** The test process opens real listeners on ephemeral ports, then
  asserts the scanner finds them. Fast, real, no mocking.
- **Offset oracle.** Assert `pcblist_n` and libproc agree on `(port, pid)` for
  every same-user listener. This is the canary for an OS update moving a
  private struct field, and it runs in the app at startup too.
- **ProjectResolver.** Table-driven over temporary directory trees: nested
  markers, `package.json` with no `name`, symlinks, unreadable directories.
- **Terminator.** Spawn `/bin/sleep`, terminate it, assert. Then assert it
  *refuses* a stale `(pid, startedAt)`.
- **Docker labels.** Decode fixture JSON from each of the three runtimes.

## Order of work

1. ~~**Spike.**~~ Done — [spike-findings.md](spike-findings.md).
2. ~~**Walking skeleton.**~~ Done. The week of daily use before actions was
   skipped by decision.
3. ~~**Actions.**~~ Done: open, copy, reveal, quit — with a confirmation that
   names the process, and the identity re-check.
4. ~~**Attribution.**~~ Done: cwd → project label, argv → runtime and version,
   `.git/HEAD` → branch, known daemons, Docker container names.
5. ~~**Search**, and *free this port*.~~ Done, plus project grouping.
6. ~~**Polish.**~~ Done: empty states, degraded and permission-denied states,
   VoiceOver labels, Escape handling, a placeholder icon.
7. **Ship.** Sign, notarise, trial, product page.

Steps 2 and 3 are where the app will turn out to be subtly wrong about
something. Using it daily before adding actions is deliberate, not caution.

## Project stacks

Grouping rows by project is the same idea as a competitor's "profiles", arrived
at from the opposite direction. Rather than asking someone to declare that
their frontend, API and database belong together, the group falls out of
attribution that already happened: those rows resolve to the same project root,
and Compose names its own project. Nothing is configured, so nothing can be
configured wrongly.

This is the boundary of what the app does with a stack. It groups them and it
can quit them. It does not start them, because starting requires storing
commands, and storing commands is the beginning of being a process supervisor —
which needs a background daemon and fails product principle 9.

## Risks

- ~~**Working directory and argv may be restricted.**~~ Retired: both are
  available for 100% of same-user processes.
- ~~**Scan cost with many processes.**~~ Retired: 0.5 ms for a full scan.
- **Private struct offsets in `pcblist_n`** may move in a macOS update. Bounded
  by the startup oracle and the `pcblist64` fallback; the failure mode is root
  rows losing their names, not wrong data.
- **Docker runtime divergence** across Docker Desktop, OrbStack and Colima.
  All three speak the same API and are covered by decoding fixtures; only
  OrbStack has been exercised against a live daemon, and only with no
  containers running. The port-to-container mapping is therefore proven by
  fixture, not by observation.

## Looking like a first-party app

Grounded in the current Human Interface Guidelines rather than recollection.
The guidance that decided the most here: **Liquid Glass belongs to the
functional layer — controls and navigation floating above content — and not to
the content layer.** This panel is mostly content: a list of text. The HIG asks
for a standard material with vibrant system colours on top for exactly this
case, "components with a significant amount of text, such as alerts, sidebars,
or popovers".

So the panel uses `NSVisualEffectView` with the `.menu` material and
`.behindWindow` blending — the material the system's own menu bar extras use,
blending with the desktop rather than with the app. That single change is most
of what separated this from a white rectangle. It also handles Reduce
Transparency and Increase Contrast on its own, which hand-rolled translucency
would not.

Everything else follows from "use system components and semantic colours":

- Tabular figures in the system face rather than SF Mono. The port column still
  aligns, but the panel reads as a menu instead of a code editor.
- Regular weight throughout, as menus use. Hierarchy comes from the dimmer,
  smaller second line, not from bolding the first.
- `selectedContentBackgroundColor` for the highlight, inset from the panel edge
  the way `NSMenu` insets its rows, with *every* piece of text on the row
  turning light. Leaving the second line `.secondary` puts grey on selection
  blue, which fails contrast and looks unfinished.
- `NSColor.systemOrange` rather than `Color.orange`, so warnings stay correct
  in dark mode and under Increase Contrast.
- Actions are full-width rows that highlight edge to edge, like "Wi-Fi
  Settings…" at the foot of the Wi-Fi menu. A right-aligned push button reads
  as a dialog control.

### Seeing what AppKit actually draws

`ImageRenderer` draws the SwiftUI view tree with no window behind it, so it
cannot show a material, a vibrancy effect or a real selection highlight —
precisely the things that decide whether this looks like a system menu. It was
reporting a white panel that did not exist.

`Localhost --window [dark]` therefore opens the same content in a real
borderless `NSPanel` and prints its window number, and `Scripts/shoot-panel.sh`
captures **that window by id** — this app's window, never the screen. Both
appearances can be checked in a couple of seconds.

### macOS 27

Not targeted, and not targetable here: this machine runs macOS 26.6.2 and only
the macOS 26 SDKs are installed. Anything written against macOS 27 APIs could
be neither compiled nor tested, so it would be guesswork. The work above is
current-HIG and uses semantic materials and colours throughout, which is what
carries forward.
