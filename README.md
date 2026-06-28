# Coldfront

Coldfront is an open source macOS fan and thermal tool.

Telemetry is the default path: fan count, current/min/max RPM, selected
temperature sensors, selected power sensors, and explicit SMC key reads with raw
bytes for auditability. Active fan control is explicit, sudo-gated, and records
a lease before changing fan state so `auto` can restore Apple's managed control.

The current active mode is deliberately simple: boost validated Apple Silicon
fans to maximum before heavy local work, then restore Apple's automatic fan
control when the work is done.

## Status

- macOS only
- Apple Silicon tested on `Mac16,5` / M4 Max and `Mac17,7` / M5 Max
- read-only SMC telemetry by default
- bounded 10-second hardware validation command
- manual max boost and auto restore on allowlisted Apple Silicon hardware
- no workload wrapper yet
- no background daemon
- no sudo requirement for telemetry reads

`boost` leaves fans at maximum until you run `auto`. There is no background
daemon yet. If you forget to restore, the intended failure mode is noisy fans
rather than silent heat buildup.

## Build

```sh
swift build -c release
```

## Run

```sh
.build/release/coldfront
```

Read explicit SMC keys. M4 models use `F{n}Md`; M5 models use `F{n}md`:

```sh
.build/release/coldfront read FNum F0Ac F0Mn F0Mx F0Tg F0md RPlt
```

Check the guarded active-control status:

```sh
.build/release/coldfront status --json
```

Run the bounded validation path. Validation always restores automatically:

```sh
sudo .build/release/coldfront validate --for 10s -y
```

Boost fans to maximum. This remains active until `auto` is run:

```sh
sudo .build/release/coldfront boost --for 10m -y
```

Restore Apple's automatic fan control:

```sh
sudo .build/release/coldfront auto
```

Example output:

```text
Coldfront

SMC
  Status: readable
  Key count: 3385
  Fan count: 2

Fans
  Fan 0
    Current: 0 [flt ]
    Minimum: 1350 [flt ]
    Maximum: 5777 [flt ]
    Target: 0 [flt ]
```

## Test

The installed Command Line Tools on the original development machine did not
expose `XCTest` or Swift `Testing` to SwiftPM, so the project uses small
executable test runners for deterministic coverage:

```sh
swift run FanProbeCoreTestRunner
swift run FanControlCoreTestRunner
```

## Safety Model

Coldfront uses one executable, but telemetry remains the default behavior.
Active writes are reachable only through explicit control commands. `boost` and
`validate` require `-y` or `--yes`.

The C read bridge only supports:

- open SMC user client
- close SMC user client
- read SMC key
- read SMC key by index

The active write stack uses package-scoped typed operations, not raw public SMC
writes. `boost` creates a lease before its first write. `auto` restores from
that captured lease and clears the lease only after managed mode and targets
settle. Active commands are model/platform allowlisted; unsupported machines
fail closed before writes.

## Roadmap

- Improve sensor labeling for Apple Silicon models.
- Add a compact menu-bar or terminal dashboard.
- Record bounded local thermal history.
- Consider workload integration after the manual `boost`/`auto` path is stable.
- Keep all active fan-control work opt-in and auditable.

## License

Apache-2.0
