# Predictive Thermal Control Spec

Status: draft
Owner: ThermalPilot
Date: 2026-06-27

## Purpose

ThermalPilot should evolve from a read-only thermal probe into a predictive,
inference-aware thermal assistant for Apple Silicon Macs.

The goal is not to replace Apple's thermal controller. The goal is to detect
that a sustained workload is likely to cause throttling and temporarily assist
cooling before the machine reaches a hot or throttled state.

The active-control path must remain opt-in, reversible, auditable, and model
allowlisted. Read-only mode remains the default.

## Product Gap

Current Mac fan tools mostly provide reactive controls:

- fixed fan RPM
- sensor-based fan curves
- alerts
- manual boost modes
- menu-bar telemetry

Those tools are useful, but they generally respond to current temperature. They
do not know that an MLX inference workload is about to run for several minutes,
or that current heat slope plus sustained package power means the machine will
likely throttle in 60-180 seconds.

ThermalPilot's differentiator is predictive pre-cooling:

1. Observe temperatures, fan RPM, power sensors, and thermal state.
2. Estimate short-horizon thermal risk.
3. Use workload intent, especially MLX inference intent, as an early signal.
4. Pre-cool upward for a bounded lease window.
5. Restore system control automatically.

## Current Implementation Boundary

The repository currently exposes read-only SMC operations only:

- `CSMCOpen`
- `CSMCClose`
- `CSMCReadKey`
- `CSMCReadKeyAtIndex`

There is no SMC write function in the current code. This must remain true for
the normal telemetry binary until an active-control helper is introduced behind
an explicit feature gate.

## SMC Model

Apple does not publish a stable public fan-control API for these keys. The SMC
surface used here is a private key/value interface exposed through IOKit user
clients named `AppleSMC` on older Macs and `AppleSMCKeysEndpoint` on this M4
Max machine.

ThermalPilot treats each SMC key as a four-byte register name. Examples:

- `FNum`: fan count
- `F0Ac`: fan 0 actual speed
- `F0Mn`: fan 0 minimum speed
- `F0Mx`: fan 0 maximum speed
- `F0Tg`: fan 0 target speed
- `F0Md`: fan 0 mode
- `TC*` / `TD*` / `TH*`: temperature-like keys
- `P*`: power-like keys

### IOKit Call Register Map

The current bridge uses `IOConnectCallStructMethod` with external method index
`2`. The input and output payloads use the AppleSMC-style `SMCKeyData` layout.

| Name | Value | Direction | Meaning |
| --- | ---: | --- | --- |
| `KERNEL_INDEX_SMC` | `2` | method selector | IOKit external method used for AppleSMC commands. |
| `SMC_CMD_READ_BYTES` | `5` | `input.data8` | Read the bytes for `input.key` after key info has been read. |
| `SMC_CMD_WRITE_BYTES` | `6` | `input.data8` | Known legacy write command. Forbidden in the read-only binary. |
| `SMC_CMD_READ_INDEX` | `8` | `input.data8` | Read key name at `input.data32` index. |
| `SMC_CMD_READ_KEYINFO` | `9` | `input.data8` | Read size, type, and attributes for `input.key`. |
| `SMC_CMD_READ_PLIMIT` | `11` | `input.data8` | Known power-limit read command in legacy tooling. Not used today. |
| `SMC_CMD_READ_VERS` | `12` | `input.data8` | Known version read command in legacy tooling. Not used today. |

ThermalPilot may add read-only support for version and power-limit commands.
It must not add write support to the normal probe target.

### SMCKeyData Layout

The C bridge currently uses this layout:

| Field | Type | Meaning |
| --- | --- | --- |
| `key` | `uint32_t` | FourCC SMC key, big-endian textual form. |
| `version` | struct | SMC version data for version commands. |
| `pLimitData` | struct | Power-limit data for power-limit commands. |
| `keyInfo.dataSize` | `uint32_t` | Number of value bytes, capped to 32 by ThermalPilot. |
| `keyInfo.dataType` | `uint32_t` | FourCC data type such as `flt `, `ui8 `, `sp78`, `fpe2`. |
| `keyInfo.dataAttributes` | `uint8_t` | SMC metadata. The bit layout is private and must be logged raw. |
| `result` | `uint8_t` | SMC command result. Non-zero is failure. |
| `status` | `uint8_t` | SMC status. Log raw when debugging. |
| `data8` | `uint8_t` | Command selector. |
| `data32` | `uint32_t` | Index for `READ_INDEX`; command-specific otherwise. |
| `bytes` | `uint8_t[32]` | Value bytes. |

## Data Type Decoding

ThermalPilot must keep raw bytes available for every decoded value. SMC type
semantics are partly model-specific.

| Type | Decoder | Notes |
| --- | --- | --- |
| `flt ` | IEEE 754 single-precision, little-endian on local M4 Max | Current M4 Max evidence: `F0Mn raw=0x00C0A844` decodes to `1350`. |
| `fpe2` | unsigned fixed-point, big-endian, divided by 4 | Common legacy RPM encoding. |
| `sp78` | signed 7.8 fixed-point, big-endian | Common legacy temperature encoding. |
| `ui8 ` / `ui8` | unsigned 8-bit integer | Used by `FNum`, `F0Md`, `Ftst`. |
| `ui16` | unsigned 16-bit integer, big-endian | Used by some status/speed-like keys. |
| `ui32` | unsigned 32-bit integer, big-endian | Used by count-like keys on some systems. |
| `ch8*` | byte string | Log raw and printable ASCII when safe. |

If a numeric decoder produces `NaN`, infinity, or an implausible value for a
sensor class, ThermalPilot must display raw bytes and exclude the value from
control decisions.

## Observed Registers On Mac16,5 / M4 Max

Observed by running:

```sh
.build/release/thermalpilot FNum F0Ac F0Mn F0Mx F0Tg F1Ac F1Mn F1Mx F1Tg F0Md F1Md 'FS! ' Ftst RPlt
```

Results on 2026-06-27:

| Key | Type | Value | Raw | Control role |
| --- | --- | ---: | --- | --- |
| `FNum` | `ui8 ` | `2` | `0x02` | Fan count. Read-only. |
| `F0Ac` | `flt ` | `0` | `0x00000000` | Fan 0 actual speed. Read-only. |
| `F0Mn` | `flt ` | `1350` | `0x00C0A844` | Fan 0 minimum. Clamp lower bound. |
| `F0Mx` | `flt ` | `5777` | `0x0088B445` | Fan 0 maximum. Clamp upper bound. |
| `F0Tg` | `flt ` | `0` | `0x00000000` | Fan 0 target. Potential future control register. |
| `F1Ac` | `flt ` | `0` | `0x00000000` | Fan 1 actual speed. Read-only. |
| `F1Mn` | `flt ` | `1350` | `0x00C0A844` | Fan 1 minimum. Clamp lower bound. |
| `F1Mx` | `flt ` | `5777` | `0x0088B445` | Fan 1 maximum. Clamp upper bound. |
| `F1Tg` | `flt ` | `0` | `0x00000000` | Fan 1 target. Potential future control register. |
| `F0Md` | `ui8 ` | `3` | `0x03` | Fan 0 mode. Semantics unverified; do not write yet. |
| `F1Md` | `ui8 ` | `3` | `0x03` | Fan 1 mode. Semantics unverified; do not write yet. |
| `Ftst` | `ui8 ` | `0` | `0x00` | Fan/test status. Semantics unverified; do not write. |
| `FS! ` | unavailable | unavailable | unavailable | Legacy forced-mode mask unavailable on this M4 Max. |
| `RPlt` | `ch8*` | `j616c` | `0x6A36313663000000` | Platform identifier. Read-only. |

This evidence means active fan control on this machine must not assume the
legacy `FS! ` mask exists. Any future controller needs a separate Apple Silicon
mode-register validation pass.

## Fan Control Registers And Bit Masks

### Legacy Forced-Mode Mask: `FS! `

Older AppleSMC tools and Linux drivers describe `FS!`/`FS! ` as a fan
manual/forced-mode mask. ThermalPilot treats this as a legacy convention, not
as a guaranteed Apple Silicon control register.

If present, the mask must be interpreted as a bitset:

| Bit | Meaning |
| ---: | --- |
| `1 << 0` | Fan 0 is in manual/forced mode. |
| `1 << 1` | Fan 1 is in manual/forced mode. |
| `1 << n` | Fan n is in manual/forced mode. |

Common values:

| Mask | Meaning |
| ---: | --- |
| `0x0000` | All fans automatic/system-controlled. |
| `0x0001` | Fan 0 manual/forced. |
| `0x0002` | Fan 1 manual/forced. |
| `0x0003` | Fan 0 and fan 1 manual/forced. |

Guardrail: even if this key exists, writes to it are forbidden until a
model-specific rollback test proves that writing `0x0000` reliably returns all
fans to automatic control.

### Per-Fan Target: `F{n}Tg`

`F0Tg`, `F1Tg`, and equivalent keys are target-speed registers in legacy
AppleSMC tooling. On the local M4 Max they read as `flt ` values and currently
return `0` while the system is idle with fans stopped.

Future writes to target registers must obey:

- target must be greater than or equal to discovered minimum RPM
- target must be less than or equal to discovered maximum RPM
- target must not be below current actual RPM when ThermalPilot is active
- target must be rounded to a conservative hardware-safe increment
- target must be time-limited by a control lease

### Per-Fan Mode: `F{n}Md`

`F0Md` and `F1Md` are present on the local M4 Max and read as `ui8 = 3`. This
likely reflects an Apple Silicon fan mode/state, but write semantics are not
verified.

ThermalPilot must not write `F{n}Md` until:

1. The meaning of each observed value is documented per model.
2. Automatic-mode value is known and tested.
3. Manual-mode value is known and tested.
4. A crash-safe rollback path is implemented.
5. The model is explicitly allowlisted.

### Test/Status Register: `Ftst`

`Ftst` is present on the local M4 Max and reads as `ui8 = 0`. Treat it as a
status/test register. It must remain read-only unless independent evidence
proves a safe use.

### Safe-Speed Registers: `F{n}Sf`

`F0Sf` and `F1Sf` read as `ui16 = 0` on the local M4 Max. Treat these as
read-only unknowns. Do not use them for control decisions until labeled.

## Predictive Control Design

### Inputs

The predictor consumes a rolling window of local observations:

- fan actual/min/max/target/mode
- selected temperature sensors
- selected power sensors
- `ProcessInfo.thermalState`
- CPU, GPU, and memory pressure when available
- AC versus battery state
- process-level workload hints
- MLX inference hints when available

MLX hints should eventually include:

- workload starting soon
- model identifier
- quantization or parameter class
- prompt/context size
- expected max output tokens
- concurrency or batch size
- current tokens per second
- expected duration band

### Risk Score

The first version should use a transparent rules model before ML:

```text
risk =
  heat_slope_score
  + sustained_power_score
  + fan_idle_or_lag_score
  + thermal_state_score
  + workload_intent_score
  + recent_throttle_or_pressure_score
```

Risk windows:

- `30s`: immediate fan response
- `60s`: normal pre-cool decision
- `180s`: MLX/inference planning window

Initial examples:

- If thermal state is `fair` and max selected temp is rising, pre-cool.
- If an MLX job is about to run for more than 60 seconds, pre-cool before
  launch even if current temperature is moderate.
- If fans are stopped and temperature slope is steep under sustained package
  power, pre-cool.
- If thermal state reaches `serious` or `critical`, stop prediction and enter
  failsafe behavior.

### Control States

| State | Writes allowed | Behavior |
| --- | --- | --- |
| `observe` | no | Read telemetry and compute risk. |
| `advise` | no | Print or surface what ThermalPilot would do. |
| `preCoolLease` | yes, helper only | Temporarily raise fan target for a bounded window. |
| `release` | yes, helper only | Restore automatic/system mode. |
| `failsafe` | yes, helper only | Prefer system automatic control; if automatic restoration fails, drive fans high and alert. |

The first shipped intelligent mode should be `advise`. Active fan writes come
after the predictor has produced useful dry-run decisions.

## Active-Control Safeguards

### Global Defaults

- Read-only mode is default.
- Active control requires explicit user opt-in.
- Active control requires a privileged helper; the normal CLI/UI must not write
  SMC keys directly.
- Active control is disabled unless the Mac model is allowlisted.
- Active control is disabled unless all required registers are readable and
  validated.
- Active control is disabled if fan count, min RPM, or max RPM is unavailable.

### Write Isolation

All writes must live in one small helper module with a narrow API:

```text
requestPreCool(targets, leaseDuration, reason)
restoreAutomatic(reason)
emergencyRelease(reason)
```

The helper must not accept arbitrary SMC key writes from the UI, CLI, or MLX
integration.

### Lease-Based Control

Every active fan request is a lease:

- default lease: 30 seconds
- maximum single lease: 120 seconds
- renewal requires fresh telemetry and a still-valid risk score
- expired lease restores automatic control
- missed heartbeat restores automatic control

### Fan Target Clamps

For fan `n`:

```text
minRPM = read(F{n}Mn)
maxRPM = read(F{n}Mx)
currentRPM = read(F{n}Ac)
targetRPM = requested pre-cool target

effectiveTarget =
  clamp(targetRPM, minRPM, maxRPM)
```

Additional constraints:

- never request below `minRPM`
- never request below `currentRPM` while ThermalPilot holds a lease
- never exceed `maxRPM`
- do not change target more often than once every 5 seconds
- avoid target jumps larger than 500 RPM unless entering failsafe
- prefer symmetric targets for dual-fan systems until per-fan thermal zones are
  mapped

Initial target bands:

| Band | Formula |
| --- | --- |
| quiet pre-cool | `minRPM + 0.20 * (maxRPM - minRPM)` |
| normal pre-cool | `minRPM + 0.35 * (maxRPM - minRPM)` |
| aggressive pre-cool | `minRPM + 0.60 * (maxRPM - minRPM)` |
| failsafe high | `minRPM + 0.85 * (maxRPM - minRPM)` or restore automatic |

For the observed M4 Max range `1350-5777`, normal pre-cool is approximately
`2900 RPM`.

### Automatic Restoration

ThermalPilot must restore automatic/system control on:

- normal exit
- SIGINT
- SIGTERM
- crash detected by helper heartbeat expiry
- sleep
- wake
- user logout
- helper restart
- thermal state `serious`
- thermal state `critical`
- unreadable fan telemetry
- failed write
- model mismatch after OS update

If the known automatic-mode register is unavailable or unverified, active
control must remain disabled.

### Thermal Emergency Rule

When `ProcessInfo.thermalState` becomes `serious` or `critical`, ThermalPilot
must stop trying to be predictive.

The emergency policy is:

1. Restore automatic/system control if the automatic rollback path is verified.
2. If rollback fails and a high-fan target path is verified, set a high bounded
   target and alert.
3. If neither path is verified, stop writing and alert loudly.

ThermalPilot must never hold a quiet or moderate manual target during a thermal
emergency.

### Audit Log

Every future write decision must log:

- timestamp
- model identifier
- platform identifier
- fan count
- min/max/current RPM
- selected temperatures
- selected power readings
- thermal state
- requested target
- clamped target
- lease duration
- reason code
- SMC registers written
- raw bytes before and after
- rollback result

Logs must avoid capturing prompts, file paths, or user content from MLX
workloads. Workload metadata should be coarse unless the user opts in.

### Model Allowlist

Active control requires a per-model capability file:

```yaml
model: Mac16,5
platform: j616c
fan_count: 2
value_encoding:
  flt: little_endian
fan_keys:
  actual: "F{n}Ac"
  minimum: "F{n}Mn"
  maximum: "F{n}Mx"
  target: "F{n}Tg"
  mode: "F{n}Md"
automatic_restore:
  verified: false
active_control:
  enabled: false
```

The initial `Mac16,5` entry must keep `active_control.enabled: false` until the
write and rollback path is verified.

## MLX Integration Contract

ThermalPilot should not require MLX to use the telemetry and predictor. MLX
integration is an optional workload-intent source.

Minimum local API:

```text
thermalpilot workload begin --kind mlx --expected-duration 300 --intensity high
thermalpilot workload end --id <id>
```

Future Swift API:

```swift
let lease = ThermalPilot.shared.beginWorkload(
    kind: .mlxInference,
    expectedDuration: .seconds(300),
    intensity: .high
)
defer { lease.end() }
```

The predictor may pre-cool when a workload begins. It must not inspect prompt
text or model inputs.

## Implementation Phases

### Phase 0: Better Read-Only Telemetry

- Improve sensor labeling.
- Persist bounded local time-series windows.
- Add JSON output.
- Add explicit raw mode for all key reads.
- Add model capability snapshot generation.

### Phase 1: Advisor Mode

- Run predictor in dry-run mode.
- Print decisions such as `would_pre_cool normal 2900rpm for 60s`.
- Compare predictions against later thermal state and temperature curves.
- Tune thresholds without any fan writes.

### Phase 2: Privileged Helper Skeleton

- Add helper process with no active write support by default.
- Add lease, heartbeat, and rollback machinery.
- Add simulated SMC backend for safety tests.
- Keep real writes behind compile-time and runtime gates.

### Phase 3: Model-Specific Control Validation

- Validate automatic restore semantics on one allowlisted model.
- Validate target write semantics.
- Validate sleep/wake and crash rollback.
- Publish raw validation notes.

### Phase 4: Opt-In Active Pre-Cool

- Enable pre-cool leases for allowlisted models only.
- Ship `--dry-run` as default for new users.
- Require explicit command or settings confirmation for active mode.

## Verification Requirements

Before active control ships:

- Unit tests for all value decoders.
- Unit tests for fan mask encode/decode.
- Unit tests for target clamp math.
- Unit tests for lease expiry.
- Unit tests for rollback on simulated failures.
- Integration tests against a fake SMC backend.
- Static check that the read-only target does not link write symbols.
- Manual hardware validation with raw before/after SMC key logs.
- Sleep/wake validation.
- Crash validation.
- Thermal emergency validation.

## Source Notes

The SMC command numbers and key conventions are private AppleSMC conventions
documented by open source tools and drivers, not by Apple as a public fan
control API. ThermalPilot should preserve source links in code comments where
private conventions are encoded.

References:

- Apple thermal-state guidance: https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/RespondToThermalStateChanges.html
- Apple `ProcessInfo.ThermalState`: https://developer.apple.com/documentation/foundation/processinfo/thermalstate
- Apple IOKit fundamentals: https://developer.apple.com/library/archive/documentation/DeviceDrivers/Conceptual/IOKitFundamentals/Introduction/Introduction.html
- Linux macsmc hardware-monitoring documentation: https://docs.kernel.org/hwmon/macsmc-hwmon.html
- Legacy SMC user-space tooling: https://github.com/jcsalterego/smc
- Macs Fan Control prior art: https://crystalidea.com/macs-fan-control
- iStat Menus fan-control prior art: https://bjango.com/help/istatmenus7/fans/
- MLX Swift: https://github.com/ml-explore/mlx-swift
