# Spike findings

Step 1 of [design.md](design.md), run 2026-09-10 on macOS 26.6.2 (build 25G83),
Apple silicon, Xcode 26.6 / Swift 6.3.3. Non-sandboxed, unsigned, run as uid 501.
578 processes, 26 TCP listeners. Sources in [../spike](../spike).

**The risky question is answered: yes.** Working directory and argv are fully
available for same-user processes. Project attribution is real, and the price
band in the brief holds.

The spike also found something the plan did not anticipate: `sysctl` beats
libproc on every axis, and `lsof` is worthless.

## Q1 — Scan cost and coverage

Median of 7 runs, warm:

| Scanner | Median | Listeners seen | PID? | Owner coverage |
| --- | --- | --- | --- | --- |
| `sysctl net.inet.tcp.pcblist64` | **0.17 ms** | 26 | no | **all users** |
| `sysctl net.inet.tcp.pcblist_n` | **0.52 ms** | 26 | yes (`so_last_pid`) | **all users** |
| libproc | 2.4 ms | 20 | yes | same-user only |
| `lsof -i -P -n -sTCP:LISTEN` | 96 ms | 20 | yes | same-user only |

libproc is ~40× faster than `lsof`; `sysctl` is ~5× faster again *and* sees
more. No caching or diffing is needed at any of these numbers — the plan's
"cache between scans if libproc is slow" risk is retired.

## Q2 — Working directory: available, 100%

`proc_pidinfo(PROC_PIDVNODEPATHINFO)` returned a path for **370 of 370**
same-user processes. Zero denials, zero blanks.

Verified end-to-end against a real dev server: port 3001 → cwd
`/Users/magnuskaspersen/Development/rilo` → `package.json` → **`rilo`**. A
synthetic server three levels deep inside a project resolved by walking up two
levels to `acme-dashboard`.

> An early run of this spike reported 380/386 blank paths and looked like the
> feature was dead. That was a bug in the spike, not the OS: passing a
> 1024-byte C array tuple through a parameter typed `Any` boxes it, so
> `withUnsafeBytes` read the existential box rather than the path. The reader
> must be generic over `T`. Worth remembering — the failure mode is a silent
> empty string, not an error.

## Q3 — argv: available, 100%

`sysctl(KERN_PROCARGS2)` returned argv for **370 of 370** same-user processes.

argv is a much stronger attribution signal than expected and should be used
alongside cwd, not just as a fallback. Real examples from this machine:

```
3001    next-server (v16.2.12)          ← Next.js rewrites its own argv
31338   Python -m http.server 31338
19646   Code Helper (Plugin) --type=utility --utility-sub-type=node.mojom.NodeService
```

## Q4 — Other-user processes: precise behaviour

208 of 578 processes were not same-user. Per fact:

| Call | Result |
| --- | --- |
| `PROC_PIDLISTFDS` | `EPERM` (all 208) |
| `PROC_PIDTBSDINFO` | `EPERM` (all 208) |
| `PROC_PIDVNODEPATHINFO` | `EPERM` (all 208) |
| `KERN_PROCARGS2` | `EINVAL` (all 208) — note: not `EPERM` |
| **`proc_pidpath`** | **succeeds, all 208** |

`proc_pidpath` working on processes we cannot otherwise touch is the useful
surprise: given a PID, a root-owned listener can still be *named*.

## The three root-owned listeners

libproc and `lsof` are both blind to these. `pcblist_n` plus `proc_pidpath`
resolves them completely:

```
  88   0.0.0.0, ::      uid=0  pid 657  …/Heimdal.framework/Helpers/kdc
5900   0.0.0.0, ::      uid=0  pid 1    /sbin/launchd
8021   127.0.0.1, ::1   uid=0  pid 1    /sbin/launchd
```

## Decisions the numbers force

**1. Drop `lsof` entirely — not even as a fallback.** `/usr/sbin/lsof` is
`-rwxr-xr-x root wheel`: **not setuid**. It therefore has exactly our
privileges and sees exactly what libproc sees — the two agreed on all 20
listeners, with zero divergence in either direction. It is 40× slower, forks a
process, parses text, and adds no coverage whatsoever. The plan's "keep an
`lsof` path as a diagnostic fallback" buys nothing; delete `LsofScanner` and
its fixture test from the design.

**2. `sysctl(pcblist_n)` becomes the discovery spine, not libproc.** It is
faster, and it is the only unprivileged way to see root-owned listeners —
which the brief requires us to show.

**3. libproc is still required, for attribution.** `pcblist_n` gives
port/address/state/uid/pid; cwd and argv come only from libproc + `KERN_PROCARGS2`.
So both, with distinct jobs:

```
pcblist_n   → every listener: port, address, uid, pid        (the rows)
libproc     → same-user only: cwd, argv, name, start time    (the project column)
proc_pidpath→ any pid, including root: executable path       (naming root rows)
```

**4. The `so_last_pid` fragility is real, and self-checkable.** `xsocket_n` /
`xinpcb_n` are XNU-private; the field offsets below were recovered by hexdump
against a socket of known port/address/pid/uid, not from a header:

| Record | Field | Offset |
| --- | --- | --- |
| `XSO_INPCB` (0x010) | `inp_lport` (big-endian) | +18 |
| | `inp_vflag` | +44 |
| | `inp_dependladdr` (IPv4 at +12) | +64 |
| `XSO_SOCKET` (0x001) | `so_uid` | +64 |
| | `so_last_pid` | +68 |
| `XSO_TCPCB` (0x020) | `t_state` | +36 |

Records are **8-byte aligned** — advance by `(len + 7) & ~7`, not `len`. The
204-byte TCPCB record pads to 208; missing this silently truncates the walk to
one socket.

Because these can break on an OS update, the scanner must **validate itself at
startup**: cross-check `so_last_pid` against libproc for same-user listeners,
where we have independent ground truth. The spike does this and scored **20/20
matched, 0 mismatched**. If that check ever fails, fall back to `pcblist64`
(public structs, `so_uid` but no PID) plus libproc — rows still appear, root
rows just lose their name. This makes the risky parse fail loudly and degrade
gracefully instead of silently misattributing.

**5. The known-daemon table is load-bearing, not a nicety.** For
launchd-activated sockets, `so_last_pid` is `launchd` (pid 1) rather than the
real service — see 5900 and 8021 above. "Port 5900 — launchd" is true and
useless; "Port 5900 — Screen Sharing, turn off in System Settings › General ›
Sharing" is the product. The table is now the *only* way those rows read well,
so it moves from step 6 polish into the attribution work in step 4.

## Not yet answered

**Docker.** The OrbStack socket exists at `~/.orbstack/run/docker.sock` and is
readable, but the daemon was not running, so `GET /containers/json` could not
be exercised. The degrade path was confirmed — `ECONNREFUSED`, caught, rows
render without container names. Docker Desktop and Colima were not installed
and remain untested.

**Root-owned killing.** Out of scope for v1 by design; not tested. `sudo` was
unavailable in this session, so "what happens when we signal a root process"
is assumed `EPERM` rather than measured.
