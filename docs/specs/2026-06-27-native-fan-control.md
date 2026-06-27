# Native Fan Control Spec

Status: draft
Date: 2026-06-27

## Goal

Build a native ThermalPilot fan-control module for Apple Silicon Macs.

Initial active mode is deliberately simple:

```text
boost max -> run workload -> restore auto
```

No prediction, no fan curves, and no dependency on ThermalForge, TG Pro, Macs
Fan Control, or any other runtime CLI.

Read-only telemetry remains the default. Active fan control is opt-in and
allowlisted by Mac model.

## Prior Art And License

ThermalForge and MTPLX already implement useful Apple Silicon fan-control and
MLX-workload fan behavior:

- ThermalForge: https://github.com/ProducerGuy/ThermalForge
- MTPLX: https://github.com/youssofal/MTPLX

ThermalForge is MIT licensed. ThermalPilot may adapt small implementation
details, but must preserve attribution in any copied/adapted source:

```text
Portions of the SMC fan-control implementation are adapted from ThermalForge:
https://github.com/ProducerGuy/ThermalForge
Copyright (c) 2026 ProducerGuy
Licensed under the MIT License.
```

## SMC Transport

ThermalPilot talks to the AppleSMC user client through IOKit.

Known service names:

| Service | Notes |
| --- | --- |
| `AppleSMCKeysEndpoint` | Observed on local `Mac16,5` M4 Max. |
| `AppleSMC` | Used by older AppleSMC tools and ThermalForge. |

ThermalPilot should try both services and record which one opened.

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

| Key | Meaning | ThermalPilot policy |
| --- | --- | --- |
| `FS! ` | Legacy fan forced-mode bitmask. | Do not require. It is unavailable on local `Mac16,5`. |

If `FS! ` is available on older hardware, treat it as legacy evidence only
until separately validated.

## Observed Local Values

Observed on `Mac16,5` / M4 Max / platform `j616c`:

```sh
.build/release/thermalpilot FNum F0Ac F0Mn F0Mx F0Tg F1Ac F1Mn F1Mx F1Tg F0Md F1Md 'FS! ' Ftst RPlt
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

Interpretation for M4:

- `F{n}Md = 3` appears to be Apple/system-controlled state.
- `F{n}Md = 1` is the expected manual-control state based on ThermalForge prior
  art, but must be verified locally before enabling active control.
- `F{n}Md = 0` is the expected auto-restore state based on ThermalForge prior
  art, but must be verified locally before enabling active control.
- `Ftst = 1` is the expected M1-M4 unlock step based on ThermalForge prior art.
- `Ftst = 0` is the expected restore step.

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
3. Validate each `Mn > 0`, `Mx > Mn`, and `Mx <= 10000`.
4. Create a lease marker on disk before writing.
5. If `Ftst` exists, write `Ftst = 1`.
6. Write each fan mode key to manual: expected value `1`.
7. For each fan, write `F{n}Tg = F{n}Mx`.
8. Poll actual RPM for up to 30 seconds.
9. Consider boost verified when every fan's actual RPM is at least
   `0.85 * maxRPM`.
10. Keep heartbeat active until lease ends or workload exits.

If any step fails, immediately call `restoreAuto("boost failed")`.

## Restore Auto Flow

Restore must be safe to call repeatedly.

For each fan:

1. Write mode key to auto: expected value `0`.
2. Write `F{n}Tg = 0`.

Then:

1. If `Ftst` exists, write `Ftst = 0`.
2. Re-read mode, target, and actual RPM.
3. Restore is verified if mode is `0` or returns to known system state and target
   is `0`.
4. Clear the lease marker only after restore is verified.

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
- explicit `thermalpilot auto`
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
- Never set target below `F{n}Mn`.
- Never set target above `F{n}Mx`.
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
  manual_mode: 1
  auto_mode: 0
  observed_system_mode: 3
  unlock_on: 1
  unlock_off: 0
validation:
  read: verified
  boost_max: unverified
  restore_auto: unverified
active_control:
  enabled: false
```

Set `active_control.enabled: true` only after local hardware validation proves:

- `Ftst = 1` unlock works.
- `F{n}Md = 1` manual mode works.
- `F{n}Tg = F{n}Mx` ramps actual fan RPM.
- `F{n}Md = 0`, `F{n}Tg = 0`, and `Ftst = 0` restore automatic control.
- Crash/watchdog restore works.
- Sleep/wake restore works.

## Commands

Target commands:

```sh
thermalpilot status --json
thermalpilot boost max --for 10m
thermalpilot auto
thermalpilot run --boost max -- <workload command>
```

`thermalpilot run --boost max -- <workload>` flow:

1. Start helper lease.
2. Verify fans ramp.
3. Run workload command.
4. Restore auto in `defer`/`finally`.
5. Exit with workload exit code unless restore fails, in which case report both.

## Tests

Required before enabling active writes:

- Unit tests for fan key formatting.
- Unit tests for little-endian float encode/decode.
- Unit tests for target clamping.
- Unit tests for mode-key detection.
- Unit tests for `Ftst` present/absent paths.
- Unit tests for lease expiry.
- Unit tests for stale marker recovery.
- Integration tests against a fake SMC backend.
- Static test that read-only target has no write API.
- Manual hardware log for boost max.
- Manual hardware log for restore auto.
- Manual hardware log for crash recovery.
- Manual hardware log for sleep/wake recovery.

## References

- ThermalForge: https://github.com/ProducerGuy/ThermalForge
- MTPLX fan runtime: https://github.com/youssofal/MTPLX/blob/main/mtplx/thermal.py
- Linux macsmc docs: https://docs.kernel.org/hwmon/macsmc-hwmon.html
- Apple IOKit fundamentals: https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/IOKitFundamentals/Introduction/Introduction.html
