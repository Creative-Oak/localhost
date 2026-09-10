# Spike

Answers step 1 of [../docs/design.md](../docs/design.md). Not shipped, not a
package — four standalone files, each built with `swiftc -O <file> -o <bin>`.

| File | Answers |
| --- | --- |
| `01-libproc-vs-lsof.swift` | Scan timings; cwd/argv availability bucketed by process owner |
| `02-pcblist64-and-permissions.swift` | Does `sysctl` see what libproc cannot; exact errno per fact for denied processes |
| `03-pcblist_n-pid-attribution.swift` | `so_last_pid` attribution, self-validated against libproc |
| `04-offset-ground-truth.swift` | Hexdump against a known socket to fix the private-struct offsets |

Results are in [../docs/spike-findings.md](../docs/spike-findings.md). Keep
`03` and `04`: the offsets in `03` were derived by `04` and are the only part
of this work that is expensive to redo.
