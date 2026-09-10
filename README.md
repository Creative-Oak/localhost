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
swift build && swift test
./Scripts/bundle.sh          # assembles .build/…/Localhost.app
open "$(./Scripts/bundle.sh | tail -1)"
```

The app is a menu bar agent, so nothing appears in the Dock — look for the
network icon in the menu bar. Quit from the panel's footer.

Not signed or notarised yet; that is step 7. `Scripts/bundle.sh` produces an
unsigned bundle, so ad-hoc sign it (`codesign --force --sign - <app>`) if
macOS refuses to launch it.

To see the scan without the interface:

```sh
"$(swift build --show-bin-path)/Localhost" --list
```

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
