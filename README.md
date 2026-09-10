# Localhost

A menu bar utility that answers "what is running on port 3000?" — and, more
usefully, "which of my projects is it?"

Design is in [docs/design.md](docs/design.md); the measurements that shaped it
are in [docs/spike-findings.md](docs/spike-findings.md).

## Status

Step 2 of the plan: a walking skeleton. It lists every TCP listener with its
process and project, and **it cannot act on anything** — no kill, no open, no
copy. Those arrive in step 3, deliberately after a week of daily use.

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

To check the panel's layout without opening it on a screen:

```sh
"$(swift build --show-bin-path)/Localhost" --render /tmp/panel.png
```

This draws the real panel with live data. A menu bar panel is otherwise only
inspectable by opening it, which makes layout regressions easy to miss —
`ScrollView` reporting no intrinsic height once shrank the whole list to a
single row, and the header count was the only clue.

## Layout

```
Sources/LocalhostKit/     discovery and attribution; cannot signal a process
  Ports/                  scanners, and the oracle that validates them
  Processes/              process facts, project resolution, daemon table
Sources/Localhost/        the menu bar app
spike/                    step 1; kept for the struct offsets it recovered
```

Discovery and destruction stay in separate types on purpose. `LocalhostKit`
has no code path that can signal anything, and when a terminator arrives it
will scan only to re-verify identity before acting.
