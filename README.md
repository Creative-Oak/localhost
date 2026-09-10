# Localhost

A menu bar utility that answers "what is running on port 3000?" — and, more
usefully, "which of my projects is it?"

Design is in [docs/design.md](docs/design.md); the measurements that shaped it
are in [docs/spike-findings.md](docs/spike-findings.md).

## Status

Step 3 of the plan. It lists every TCP listener with its process, project,
branch and runtime, and can open, copy, reveal and quit.

Quitting a process is the only irreversible thing here, so it is the most
guarded: `(pid, startedAt)` is re-read immediately before the signal and the
terminator refuses if the process behind that pid has changed. A stale row
cannot take an innocent process with it. `LocalhostKit` scanners have no code
path that can signal anything; `ProcessTerminator` re-reads one process by pid
and cannot find a listener.

## Build

```sh
swift test
./Scripts/run.sh             # rebuild, re-bundle, relaunch
```

Always launch through `Scripts/run.sh`. `swift build` updates the binary but
not `Localhost.app`, so the running menu bar app quietly stays on old code —
which looks exactly like a fix not working.

The app is a menu bar agent, so nothing appears in the Dock — look for the
network icon in the menu bar. Quit from the panel's footer.

Not signed or notarised yet; that is step 7. `Scripts/bundle.sh` produces an
unsigned bundle, so ad-hoc sign it (`codesign --force --sign - <app>`) if
macOS refuses to launch it.

To see the scan without the interface:

```sh
"$(swift build --show-bin-path)/Localhost" --list
```

Diagnostics, all on the same binary:

```sh
Localhost --list                  # what the menu would show
Localhost --window [dark]         # the panel in a real window, for screenshots
Localhost --bench                 # per-phase timings
Localhost --soak [pooled]         # footprint over 1000 scans
Localhost --window confirm        # panel plus the termination alert
```

`Scripts/list-windows.swift <pid>` lists the windows a process owns, which is
how a modal is checked for actually appearing — a dialog that fails to present
raises no error and draws nothing, so nothing else catches it.

`Scripts/shoot-panel.sh out.png [dark]` captures the panel **by window id**, so
only this app's window is ever in the picture. Use it rather than `ImageRenderer`
for anything involving materials, vibrancy or selection — `ImageRenderer` draws
the view tree with no window behind it and cannot show any of them.

To check the panel's layout without opening it on a screen:

```sh
"$(swift build --show-bin-path)/Localhost" --render /tmp/panel.png
```

This draws the real panel with live data. A menu bar panel is otherwise only
inspectable by opening it, which makes layout regressions easy to miss —
`ScrollView` reporting no intrinsic height once shrank the whole list to a
single row, and the header count was the only clue.

`Tests/LocalhostUITests` renders the panel the same way and asserts on it, so
that class of bug fails the build rather than the eye. `TextField` and `Button`
do not draw under `ImageRenderer`; they appear as coloured blocks in a render
and are fine in the running app.

## Layout

```
Sources/LocalhostKit/     discovery and attribution; cannot signal a process
  Ports/                  scanners, the oracle that validates them, search
  Processes/              process facts, project + runtime + branch, daemons
Sources/LocalhostUI/      views and view state, separate so layout is testable
Sources/Localhost/        the executable and its diagnostics
spike/                    step 1; kept for the struct offsets it recovered
```

Discovery and destruction stay in separate types on purpose. `LocalhostKit`
has no code path that can signal anything, and when a terminator arrives it
will scan only to re-verify identity before acting.
