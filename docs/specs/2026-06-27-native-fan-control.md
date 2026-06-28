# Native Fan Control Spec

Status: implemented for manual `boost` / `auto` on `Mac16,5` and `Mac17,7`
Date: 2026-06-27
Updated: 2026-06-28

## Goal

Coldfront provides one macOS CLI:

```sh
coldfront
coldfront read FNum F0Ac F0Tg F0Md F0md Ftst
coldfront status --json
coldfront validate --for 10s -y
coldfront boost --for 10m -y
coldfront auto
```

Telemetry is the default. Active fan control is limited to validated Apple
Silicon hardware and only supports:

```text
boost fans to maximum -> explicit restore to Apple automatic control
```

There is no daemon, fan curve, prediction engine, or workload wrapper in the
current release.

## Prior Art And License

Coldfront is Apache-2.0 licensed. ThermalForge is MIT licensed. Coldfront may
adapt small implementation details, but copied or adapted source must preserve
MIT attribution.

References:

- ThermalForge: https://github.com/ProducerGuy/ThermalForge
- MTPLX: https://github.com/youssofal/MTPLX

## Transport

Coldfront talks to the AppleSMC user client through IOKit.

Known service names:

| Service | Notes |
| --- | --- |
| `AppleSMCKeysEndpoint` | Observed on local Apple Silicon MacBook Pro hardware. |
| `AppleSMC` | Older AppleSMC tools use this name. |

IOKit command constants:

| Constant | Value | Direction | Meaning |
| --- | ---: | --- | --- |
| `KERNEL_INDEX_SMC` | `2` | call selector | `IOConnectCallStructMethod` selector. |
| `SMC_CMD_READ_BYTES` | `5` | read | Read key bytes. |
| `SMC_CMD_WRITE_BYTES` | `6` | write | Write key bytes. Used only by typed fan operations. |
| `SMC_CMD_READ_INDEX` | `8` | read | Enumerate key by index. |
| `SMC_CMD_READ_KEYINFO` | `9` | read | Read key size, type, and attributes. |

The C read bridge exposes only open, close, read by key, and read by index. The
write path lives in `SMCControlTransport` and accepts only typed fan operations:

```text
unlock(Ftst)
mode(F{n}Md or F{n}md)
target(F{n}Tg)
```

No public raw SMC write API is exposed.

## Required Keys And Values

All keys are four ASCII bytes.

| Key | Type on Apple Silicon | Direction | Required | Meaning |
| --- | --- | --- | --- | --- |
| `FNum` | `ui8 ` | read | yes | Fan count. |
| `F{n}Ac` | `flt ` | read | yes | Fan `n` actual RPM. |
| `F{n}Mn` | `flt ` | read | yes | Fan `n` minimum running RPM. |
| `F{n}Mx` | `flt ` | read | yes | Fan `n` maximum RPM. |
| `F{n}Tg` | `flt ` | read/write | yes | Fan `n` target RPM. |
| `F{n}Md` | `ui8 ` | read/write | M1-M4 | Fan `n` mode, uppercase key. |
| `F{n}md` | `ui8 ` | read/write | M5 | Fan `n` mode, lowercase key. |
| `Ftst` | `ui8 ` | read/write | M1-M4 if present | Fan/test unlock. Not present on the `Mac17,7` M5 path. |
| `RPlt` | `ch8*` | read | yes | Platform identifier. |
| `#KEY` | `ui32` or raw | read | optional | SMC key count. |

Validated byte values on `Mac16,5`:

| Register | Value | Meaning |
| --- | ---: | --- |
| `F{n}Md` | `1` | Manual fan mode command. |
| `F{n}Md` | `0` | Release command. Hardware settles through this state. |
| `F{n}Md` | `3` | Apple/system-managed state observed after restore. |
| `Ftst` | `1` | Unlock fan writes. |
| `Ftst` | `0` | Lock/restore normal fan writes. |
| `F{n}Tg` | `0.0` | Validated target clear only after mode is non-manual. |

These mode and unlock fields are byte values, not bit masks. The legacy `FS! `
forced-mode bitmask is not required and was unavailable on local `Mac16,5`.
Coldfront does not write `FS! `.

Mode values on `Mac17,7`:

| Register | Value | Meaning |
| --- | ---: | --- |
| `F{n}md` | `0` | Apple/system-managed state observed before boost. |
| `F{n}md` | `1` | Manual fan mode command used by Coldfront. |
| `F{n}Tg` | `0.0` | Target clear value observed before boost. |

## Encoding

| SMC type | Encoding |
| --- | --- |
| `flt ` | Apple Silicon fan RPM values are IEEE 754 `Float`, little-endian. |
| `ui8 ` / `ui8` | One unsigned byte. |
| `ui16` | Big-endian unsigned integer unless model data proves otherwise. |
| `ui32` | Big-endian unsigned integer unless model data proves otherwise. |
| `ch8*` | Raw bytes plus printable ASCII when safe. |

Write `F{n}Tg` using little-endian `Float` bytes.

| RPM | Bytes |
| ---: | --- |
| `0` | `00 00 00 00` |
| `1350` | `00 C0 A8 44` |
| `5777` | `00 88 B4 45` |

## Validated Hardware

Observed on `Mac16,5` / M4 Max / platform `j616c`:

```sh
.build/release/coldfront read FNum F0Ac F0Mn F0Mx F0Tg F1Ac F1Mn F1Mx F1Tg F0Md F1Md 'FS! ' Ftst RPlt
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

Manual validation reached:

- fan 0: `5505 RPM`
- fan 1: `5199 RPM`
- threshold: `0.85 * 5777 = 4910 RPM`

After restore, hardware settled to `F0Md/F1Md=3`, `F0Tg/F1Tg=0`, and `Ftst=0`.

Observed on `Mac17,7` / M5 Max / platform `j714c`:

```sh
.build/release/coldfront read FNum F0Ac F0Mn F0Mx F0Tg F1Ac F1Mn F1Mx F1Tg F0md F1md Ftst RPlt
```

| Key | Value | Raw |
| --- | ---: | --- |
| `FNum` | `2` | `0x02` |
| `F0Ac` | `0` | `0x00000000` |
| `F0Mn` | `2317` | `0x00D01045` |
| `F0Mx` | `7826` | `0x0090F445` |
| `F0Tg` | `0` | `0x00000000` |
| `F1Ac` | `0` | `0x00000000` |
| `F1Mn` | `2317` | `0x00D01045` |
| `F1Mx` | `7826` | `0x0090F445` |
| `F1Tg` | `0` | `0x00000000` |
| `F0md` | `0` | `0x00` |
| `F1md` | `0` | `0x00` |
| `Ftst` | unavailable | unavailable |
| `RPlt` | `j714c` | `0x6A37313463000000` |

## Command Flows

`status --json`:

1. Resolve model and platform.
2. Read fan count, fan min/max/current/target/mode, and `Ftst` when the capability uses an unlock key.
3. Report whether the current executable enables active control on this host.

`boost --for <duration> -y`:

1. Resolve allowlisted model/platform.
2. Refuse unsupported hardware or invalid fan inventory.
3. Refuse if any fan is already manual or, for unlock-key models, `Ftst` is already unlocked.
4. Create a lease containing captured raw mode and target bytes.
5. Write `Ftst=1` and poll readback when the capability uses an unlock key.
6. Write max target as a pre-manual guard.
7. Write the allowlisted mode key to `1` with retry for transient `0x82` rejections.
8. Write `F{n}Tg=F{n}Mx` after manual readback.
9. Poll actual RPM until every fan reaches at least `0.85 * maxRPM`.
10. Leave fans boosted until explicit `coldfront auto`.

`auto`:

1. Read the current lease.
2. Write protective high targets.
3. Write mode release command `0`.
4. Write `Ftst=0` and poll readback when the capability uses an unlock key.
5. Wait for non-manual and managed mode.
6. Restore captured target bytes.
7. Clear the lease only after managed mode and target settle.

`validate --for 10s -y`:

1. Run the same boost path.
2. Hold for at most 10 seconds.
3. Always attempt restore before exiting.

## Lease And Audit

Lease and audit files are stored under:

```text
~/Library/Application Support/Coldfront/fan-control/
```

The lease stores:

- lease ID
- capability fingerprint
- owner process identity
- expiry time
- last heartbeat time
- captured raw mode bytes
- captured raw target bytes

The current CLI does not run a background watchdog daemon. `auto` is the active
restore command. Core recovery decision logic exists for expiry, missed
heartbeat, parent exit, corrupt lease, and capability mismatch, but no daemon
invokes it yet.

## Guardrails

- Active commands require `-y` or `--yes`.
- Active commands require sudo because SMC writes require privileges.
- Active commands are model/platform allowlisted.
- Fan count must match the capability.
- Fan minimum and maximum RPM must be sane: `Mn > 0`, `Mx > Mn`, `Mx <= 10000`.
- Target and mode key type/size must match the validated shape.
- Mode key case must match the allowlisted capability.
- Do not expose arbitrary SMC writes.
- Do not write keys outside `Ftst`, `F{n}Md` / `F{n}md`, and `F{n}Tg`.
- Do not clear target to zero while a fan is manual.
- Do not restore from a corrupt or mismatched lease.
- On boost failure after an accepted write, attempt immediate rollback.
- If restore cannot be verified, keep the lease for operator recovery.

## Current Limitations

- Only `Mac16,5` / `j616c` and `Mac17,7` / `j714c` are allowlisted.
- No custom RPM mode.
- No workload wrapper.
- No menu-bar app.
- No daemon watchdog.

## Tests

Current test runners:

```sh
swift run FanProbeCoreTestRunner
swift run FanControlCoreTestRunner
swift build -c release
```

Coverage includes:

- read-only C bridge has no write API
- typed write transport has no public raw write API
- command parsing for `status`, `validate`, `boost`, and `auto`
- rejection of removed workload-wrapper command
- rejection of old long acknowledgement flag
- capability resolution and hardware inventory validation
- fake SMC delayed `Ftst`, mode, and target readback
- boost lease-before-write and rollback behavior
- restore from captured lease state
- audit JSONL encoding
- recovery decision model
