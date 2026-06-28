# Coldfront

Coldfront is a macOS fan and thermal probe with guarded fan-control validation
for Apple Silicon Macs.

The first release focuses on trustworthy telemetry: fan count, current/min/max
RPM, selected temperature sensors, selected power sensors, and explicit SMC key
reads with raw bytes for auditability. Active fan control is opt-in and records
a lease before changing fan state so `auto` can restore Apple's managed control.

The longer-term goal is a native open source thermal assistant for Apple
Silicon machines: boost fans before local AI inference or other heavy work,
then restore Apple's automatic fan control.

## Status

- macOS only
- Apple Silicon tested on `Mac16,5` / M4 Max
- read-only SMC telemetry by default
- bounded 10-second hardware validation command
- manual max boost and auto restore on validated hardware
- no workload wrapper yet
- no background daemon
- no sudo requirement for telemetry reads

`boost` leaves fans at maximum until you run `auto`. There is no background
daemon yet; if you forget to restore, the failure mode is noisy fans rather than
silent heat buildup.

## Build

```sh
swift build -c release
```

## Run

```sh
.build/release/coldfront
```

Read explicit SMC keys:

```sh
.build/release/coldfront read FNum F0Ac F0Mn F0Mx F0Tg
```

Check the guarded active-control status:

```sh
.build/release/coldfront status --json
```

Run the bounded validation path:

```sh
sudo .build/release/coldfront validate --for 10s -y
```

Boost fans to maximum:

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
settle.

## Roadmap

- Improve sensor labeling for Apple Silicon models.
- Add a compact menu-bar or terminal dashboard.
- Record bounded local thermal history.
- Add a workload wrapper for local inference and other heavy commands.
- Keep all active fan-control work opt-in and auditable.

## License

Apache-2.0
