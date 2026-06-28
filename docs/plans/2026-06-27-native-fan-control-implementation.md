# Native Fan Control Implementation Plan

Status: current implementation baseline
Updated: 2026-06-28

## Scope

Coldfront has one binary:

```sh
coldfront
coldfront read FNum F0Ac F0Tg F0Md F0md Ftst
coldfront status --json
sudo coldfront validate --for 10s -y
sudo coldfront boost --for 10m -y
sudo coldfront auto
```

The separate control executable is removed. There is no workload wrapper in the
current interface.

## Completed

- Swift package renamed to `coldfront`.
- Single executable product: `coldfront`.
- Read-only telemetry remains the default command.
- Explicit SMC key reads use `coldfront read`.
- Active writes are limited to typed fan operations.
- Active commands require `-y` or `--yes`.
- `boost` creates a lease before the first write.
- `boost` writes max targets and verifies actual RPM ramp.
- `auto` restores from captured lease bytes.
- `validate` performs a bounded boost, hold, and restore.
- `Mac16,5` / `j616c` hardware validation is documented.
- `Mac17,7` / `j714c` support uses lowercase `F{n}md` mode keys without
  `Ftst`.
- Tests reject the old workload-wrapper command and old long acknowledgement
  flag.

## Current Architecture

| Module | Role |
| --- | --- |
| `FanProbeCore` | Read-only SMC snapshot, value decoding, and default output. |
| `CSMC` | C read bridge. No write function is exposed. |
| `FanControlCore` | Command parsing, capability model, leases, audit log, controller. |
| `SMCControlTransport` | Package-scoped typed fan writes. |
| `coldfront` | CLI entrypoint for telemetry, status, validate, boost, and auto. |

## Manual Boost Flow

1. User runs `sudo coldfront boost --for 10m -y`.
2. CLI resolves host model/platform and fan inventory.
3. Controller refuses unsupported hardware or unsafe current state.
4. Controller writes a lease with captured mode/target bytes.
5. Controller unlocks `Ftst` when required, enters manual mode, writes max
   targets, and polls actual RPM.
6. Fans remain boosted until the user runs `sudo coldfront auto`.

## Manual Auto Flow

1. User runs `sudo coldfront auto`.
2. CLI reads the lease.
3. Controller writes protective high targets, releases manual mode, turns
   `Ftst` off when required, restores captured targets, and waits for managed
   mode.
4. Lease is cleared only after restore settles.

## Guardrails

- No arbitrary SMC write API.
- No active control on unallowlisted model/platform pairs.
- Mode key case must match the allowlisted model/platform capability.
- No target clear while mode is manual.
- No restore from corrupt or mismatched leases.
- Roll back if boost fails after any accepted write.
- Audit writes to JSONL under Application Support.

## Next Work

- Add a manual recovery command that can inspect and explain a stuck lease.
- Add a daemon/watchdog if automatic recovery is required.
- Validate sleep/wake and parent-death recovery only after a daemon exists.
- Add more model capability entries from hardware logs.
- Consider workload integration after the manual `boost` / `auto` path is stable.

## Verification

Run before release:

```sh
swift run FanProbeCoreTestRunner
swift run FanControlCoreTestRunner
swift build -c release
.build/release/coldfront status --json
.build/release/coldfront read FNum F0Ac F0Tg F0Md F1Ac F1Tg F1Md F0md F1md Ftst RPlt
```
