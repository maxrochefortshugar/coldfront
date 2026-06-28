# Mac17,7 Fan Control Inventory

Model: Mac17,7
Chip: M5 Max
Platform: j714c
Date: 2026-06-28

Coldfront enables the guarded manual boost path for `Mac17,7` / `j714c` using
the M5 lowercase mode keys. Unlike the existing `Mac16,5` path, this inventory
does not expose a readable `Ftst` unlock key, so the capability skips the
unlock/lock step and writes only typed fan mode and target operations.

On this hardware, a pre-manual target write can be accepted without becoming
visible in `F{n}Tg` while the fan remains in managed mode. The active path still
requests max target before manual mode, but it does not require that target to
read back until after lowercase manual mode is visible.

Observed pre-boost inventory:

| Key | Value | Raw |
| --- | ---: | --- |
| `FNum` | `2` | `0x02` |
| `F0Ac` | `0` | `0x00000000` |
| `F0Mn` | `2317` | `0x00D01045` |
| `F0Mx` | `7826` | `0x0090F445` |
| `F0Tg` | `0` | `0x00000000` |
| `F0md` | `0` | `0x00` |
| `F1Ac` | `0` | `0x00000000` |
| `F1Mn` | `2317` | `0x00D01045` |
| `F1Mx` | `7826` | `0x0090F445` |
| `F1Tg` | `0` | `0x00000000` |
| `F1md` | `0` | `0x00` |
| `Ftst` | unavailable | unavailable |
| `RPlt` | `j714c` | `0x6A37313463000000` |
