# Native Fan Control Spec

Status: draft
Date: 2026-06-27

## Goal

Build a native Coldfront fan-control module for Apple Silicon Macs.

Initial active mode is deliberately simple:

```text
boost -> restore auto
```

No prediction, no fan curves, and no dependency on ThermalForge, TG Pro, Macs
Fan Control, or any other runtime CLI.

Read-only telemetry remains the default. Active fan control is opt-in and
allowlisted by Mac model.

## Prior Art And License

ThermalForge and MTPLX already implement useful Apple Silicon fan-control and
local-workload fan behavior:

- ThermalForge: https://github.com/ProducerGuy/ThermalForge
- MTPLX: https://github.com/youssofal/MTPLX

Coldfront is Apache-2.0 licensed. ThermalForge is MIT licensed. Coldfront
may adapt small implementation details, but must preserve MIT attribution in
any copied/adapted source:

```text
Portions of the SMC fan-control implementation are adapted from ThermalForge:
https://github.com/ProducerGuy/ThermalForge
Copyright (c) 2026 ProducerGuy
Licensed under the MIT License.
```

## SMC Transport

Coldfront talks to the AppleSMC user client through IOKit.

Known service names:

| Service | Notes |
| --- | --- |
| `AppleSMCKeysEndpoint` | Observed on local `Mac16,5` M4 Max. |
| `AppleSMC` | Used by older AppleSMC tools and ThermalForge. |

Coldfront should try both services and record which one opened.

IOKit call shape:

| Constant | Value | Meaning |
| --- | ---: | --- |
| `KERNEL_INDEX_SMC` | `2` | `IOConnectCallStructMethod` selector. |
| `SMC_CMD_READ_BYTES` | `5` | Read key bytes. |
| `SMC_CMD_WRITE_BYTES` | `6` | Write key bytes. Active helper only. |
| `SMC_CMD_READ_INDEX` | `8` | Enumerate key by index. |
| `SMC_CMD_READ_KEYINFO` | `9` | Read size, type, attributes. |

Normal CLI target must expose read commands only. Write support belongs in a
separate native helper module.

## Required SMC Keys

All keys are four ASCII bytes.

### Common Fan Keys

| Key | Type on M4 Max | Direction | Required | Meaning |
| --- | --- | --- | --- | --- |
| `FNum` | `ui8 ` | read | yes | Fan count. |
| `F{n}Ac` | `flt ` | read | yes | Fan `n` actual RPM. |
| `F{n}Mn` | `flt ` | read | yes | Fan `n` minimum running RPM. |
| `F{n}Mx` | `flt ` | read | yes | Fan `n` maximum RPM. |
| `F{n}Tg` | `flt ` | read/write | yes | Fan `n` target RPM. |
| `F{n}Md` | `ui8 ` | read/write | M1-M4 | Fan `n` mode, uppercase key. |
| `F{n}md` | `ui8 ` | read/write | M5+ | Fan `n` mode, lowercase key. |
| `Ftst` | `ui8 ` | read/write | M1-M4 if present | Fan/test unlock. |
| `RPlt` | `ch8*` | read | recommended | Platform identifier. |
| `#KEY` | `ui32`/raw | read | recommended | SMC key count. |

### Legacy Key Not Required

| Key | Meaning | Coldfront policy |
| --- | --- | --- |
| `FS! ` | Legacy fan forced-mode bitmask. | Do not require. It is unavailable on local `Mac16,5`. |

If `FS! ` is available on older hardware, treat it as legacy evidence only
until separately validated.

## Observed Local Values

Observed on `Mac16,5` / M4 Max / platform `j616c`:

```sh
.build/release/coldfront FNum F0Ac F0Mn F0Mx F0Tg F1Ac F1Mn F1Mx F1Tg F0Md F1Md 'FS! ' Ftst RPlt
```

| Key | Value | Raw |
| --- | ---: | --- |
| `FNum` | `2` | `0x02` |
| `F0Ac` | `0` | `0x00000000` |
| `F0Mn` | `1350` | `0x00C0A844` |
| `F0Mx` | `5777` | `0x0088B445` |
| `F0Tg` | `0` | `0x00000000` |
| `F1Ac` | `0` | `0x00000000` |
| `F1Mn` | `1350` | `0x00C0A844` |
| `F1Mx` | `5777` | `0x0088B445` |
| `F1Tg` | `0` | `0x00000000` |
| `F0Md` | `3` | `0x03` |
| `F1Md` | `3` | `0x03` |
| `Ftst` | `0` | `0x00` |
| `FS! ` | unavailable | unavailable |
| `RPlt` | `j616c` | `0x6A36313663000000` |

Interpretation for local M4:

- `F{n}Md = 3` appears to be Apple/system-controlled state.
- `F{n}Md = 1` is manual-control state.
- `F{n}Md = 0` is a release/intermediate state. After restore settles, local
  hardware returned to `3`.
- `Ftst = 1` is the M1-M4 unlock step. Readback is delayed and must be polled.
- `Ftst = 0` is the expected restore step.
- `F{n}Tg = 0` was observed while fans were system controlled. Treat this as
  "no manual target exposed", not proof that Apple's desired fan speed is zero.

## Hardware Validation Run

Validated on local `Mac16,5` / M4 Max / `j616c` with a short validation probe.

Observed behavior:

- `Ftst = 1` accepted with SMC result `0`, but readback changed only after
  repeated writes/polling.
- While unlocked but not manual, requested `F{n}Tg = F{n}Mx` did not stick.
  Targets settled to safe nonzero/minimum values.
- `F{n}Md = 1` initially returned SMC result `0x82`, then eventually accepted.
- After mode readback `1`, `F{n}Tg = F{n}Mx` stuck.
- Actual RPM reached boost threshold:
  - fan 0: `5505 RPM`
  - fan 1: `5199 RPM`
  - threshold: `0.85 * 5777 = 4910 RPM`
- Restore required polling `Ftst = 0`.
- After restore, mode first read `0`; after a short settle window it returned to
  `3`, target `0`, actual `0`.

## Value Encoding

| SMC type | Encoding |
| --- | --- |
| `flt ` | Apple Silicon fan RPM values are IEEE 754 `Float`, little-endian. |
| `ui8 ` / `ui8` | One unsigned byte. |
| `ui16` | Big-endian unsigned integer unless model data proves otherwise. |
| `ui32` | Big-endian unsigned integer unless model data proves otherwise. |
| `ch8*` | Raw bytes plus printable ASCII when safe. |

Write `F{n}Tg` using little-endian `Float` bytes.

Examples:

| RPM | Bytes |
| ---: | --- |
| `0` | `00 00 00 00` |
| `1350` | `00 C0 A8 44` |
| `5777` | `00 88 B4 45` |

## Mode Detection

At startup, the control module detects fan mode key shape:

1. Try reading `F0md`.
2. If present, use lowercase `F{n}md` for all fans. This is the M5-style path.
3. Otherwise read `F0Md`.
4. If present, use uppercase `F{n}Md` for all fans. This is the M1-M4-style path.
5. If neither key is readable, active control is disabled.

Then detect unlock support:

1. Read key info for `Ftst`.
2. If present, use `Ftst` unlock/restore.
3. If absent, do not use `Ftst`.

## Control API

The helper exposes only three operations:

```text
status()
boostMax(lease)
restoreAuto(reason)
```

No arbitrary SMC write API is exposed to the CLI, UI, or workload integrations.

## Status Operation

`status()` reads:

- model identifier
- platform identifier when available
- opened SMC service name
- fan count
- per-fan actual RPM
- per-fan target RPM
- per-fan min RPM
- per-fan max RPM
- per-fan mode
- `Ftst` value when available

If fan count, min RPM, max RPM, target key, or mode key is missing, active
control is unavailable.

## Boost Max Flow

For each allowlisted model:

1. Read `FNum`; require `1...8`.
2. Read every fan's `Ac`, `Mn`, `Mx`, `Tg`, and mode key.
3. Save raw pre-boost mode and target bytes in the lease marker.
4. Refuse to take over an already-manual fan unless an existing Coldfront
   lease owns it.
5. Validate each `Mn > 0`, `Mx > Mn`, and `Mx <= 10000`.
6. Create a lease marker on disk before writing.
7. If `Ftst` exists, write `Ftst = 1` and poll until readback is `1`.
8. Request `F{n}Tg = F{n}Mx` while not manual.
9. Before manual mode, require every target to read back at least `0.95 * Mn`.
   On local M4, max target did not stick until manual mode.
10. Retry each fan mode key to manual `1` until write succeeds and readback is
    `1`.
11. After manual readback, write `F{n}Tg = F{n}Mx` and poll until target
    readback matches max.
12. Poll actual RPM for up to 30 seconds.
13. Consider boost verified when every fan's actual RPM is at least
   `0.85 * maxRPM`.
14. Keep heartbeat active until lease ends or workload exits.

If any step fails, immediately call `restoreAuto("boost failed")`.

## Restore Auto Flow

Restore must be safe to call repeatedly.

For each fan:

1. Keep or rewrite `F{n}Tg = F{n}Mx` as a safe high target before release.
2. Write mode key to release: expected command value `0`.

Then:

1. If `Ftst` exists, write `Ftst = 0` and poll until readback is `0`.
2. Poll until every fan mode is not manual.
3. Restore captured target bytes. If the captured target was `0`, write
   `F{n}Tg = 0` only after non-manual readback.
4. Re-read mode, target, and actual RPM through a settle window.
5. Restore is verified when no fan is manual, `Ftst = 0`, and target/actual RPM
   return to the model's managed idle state.
6. Clear the lease marker only after restore is verified.

If restore cannot be verified, leave the marker in place and print a clear
manual recovery command once such a command exists.

## Lease And Watchdog

Every active boost is a lease.

Defaults:

| Setting | Value |
| --- | ---: |
| Default lease | `10m` |
| Max lease | `2h` |
| Heartbeat interval | `2s` |
| Missed heartbeat restore | `15s` |
| Actual RPM verification timeout | `30s` |

Restore auto on:

- normal workload exit
- explicit `coldfront auto`
- Ctrl-C
- SIGTERM
- parent process death
- helper restart with stale marker
- sleep
- wake
- unreadable SMC state
- failed write
- model mismatch

## Safety Rules

- Active control is disabled by default.
- Active control requires a model allowlist entry.
- Active control requires explicit user opt-in.
- Do not write any key outside the required fan-control key set.
- Do not treat immediate readback as authoritative for mode, target, or `Ftst`;
  use retry/poll windows.
- Never set a manual target below `F{n}Mn`.
- Never set a manual target above `F{n}Mx`.
- `F{n}Tg = 0` is allowed only during auto restore, after mode is no longer
  manual, and only for models where zero is validated as a safe clear value.
- Initial active mode only supports max boost and auto restore.
- No quiet/manual/custom-RPM mode until max/auto is validated.
- The read-only binary must not link or expose write symbols.
- All writes must log key, old raw bytes, new raw bytes, result, and reason.
- If macOS thermal state is `serious` or `critical`, restore auto or keep fans
  at max; never hold a lower manual target.

## Model Capability File

Initial `Mac16,5` capability file:

```yaml
model: Mac16,5
platform: j616c
fan_count: 2
smc_services:
  - AppleSMCKeysEndpoint
  - AppleSMC
encoding:
  fan_float: little_endian_ieee754_float
keys:
  count: FNum
  actual: "F{n}Ac"
  minimum: "F{n}Mn"
  maximum: "F{n}Mx"
  target: "F{n}Tg"
  mode: "F{n}Md"
  unlock: Ftst
values:
  manual_command: 1
  release_command: 0
  managed_observed_state: 3
  target_clear: 0
  unlock_on: 1
  unlock_off: 0
strategy:
  unlock: ftst_delayed_retry
  pre_manual_target: require_nonzero_minimum
  manual: retry_until_readback
  target_max: after_manual_readback
  restore: release_then_ftst_off_then_clear_target
validation:
  read: verified
  boost_max_one_shot: verified
  restore_auto_one_shot: verified
  target_clear_after_non_manual: verified
  crash_recovery: unverified
  sleep_wake_recovery: unverified
active_control:
  enabled: false
```

Keep `active_control.enabled: false` until crash and sleep/wake recovery are
verified. One-shot max/restore is hardware-validated for `Mac16,5`.

Set `active_control.enabled: true` only after local hardware validation proves:

- `Ftst = 1` unlock works.
- `F{n}Md = 1` manual mode works.
- `F{n}Tg = F{n}Mx` ramps actual fan RPM.
- `F{n}Md = 0`, captured target restore or validated target clear, and
  `Ftst = 0` restore automatic control.
- Crash/watchdog restore works.
- Sleep/wake restore works.

## Commands

Target commands:

```sh
coldfront status --json
coldfront boost --for 10m -y
coldfront auto
```

`coldfront boost` flow:

1. Start helper lease.
2. Verify fans ramp.
3. Leave fans boosted until explicit `coldfront auto`.

`coldfront auto` flow:

1. Read current lease.
2. Restore captured automatic state.
3. Clear lease after managed mode and target settle.
5. Exit with workload exit code unless restore fails, in which case report both.

## Tests

Required before enabling active writes:

- Unit tests for fan key formatting.
- Unit tests for little-endian float encode/decode.
- Unit tests for target clamping.
- Unit tests for mode-key detection.
- Unit tests for `Ftst` present/absent paths.
- Unit tests for delayed readback polling.
- Unit tests that target clear is impossible while mode reads manual.
- Unit tests for lease expiry.
- Unit tests for stale marker recovery.
- Integration tests against a fake SMC backend.
- Static test that read-only target has no write API.
- Manual hardware log for boost.
- Manual hardware log for restore auto.
- Manual hardware log for crash recovery.
- Manual hardware log for sleep/wake recovery.

## References

- ThermalForge: https://github.com/ProducerGuy/ThermalForge
- MTPLX fan runtime: https://github.com/youssofal/MTPLX/blob/main/mtplx/thermal.py
- Linux macsmc docs: https://docs.kernel.org/hwmon/macsmc-hwmon.html
- Apple IOKit fundamentals: https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/IOKitFundamentals/Introduction/Introduction.html
