# Thermometer profiles (ProbeBeacon)

Device support is defined in code (`ThermometerProfiles.swift`) and selected per probe in **Settings → Probes → Driver**.

| Profile | Discovery hints | Decode |
|---------|-----------------|--------|
| ThermoWorks BlueDOT | Name `BlueDOT` | GATT `783F2991-…` int32 °F |
| MEATER | Name `MEATER`, service `A75CC7FC-…` | `7EDDA774-…` 6-byte tip formula |
| Thermapen Blue | Name `Thermapen` | ETI int32 (same as BlueDOT) + standard 0x1809 / 0x2A6E fallbacks |
| Inkbird iBBQ | Name `iBBQ` / `Inkbird`, service `FFF0` | Notify `FFF4`, enable via `FFF5` |
| Auto-detect | Thermometer-like names/services | Tries standard GATT + ranked heuristics on notify data |

## Auto-detect (no driver)

When **Auto-detect** is chosen, after connect the app:

1. Subscribes to common temperature characteristics (Health Thermometer 0x2A1C, 0x2A6E, ETI/BlueDOT-style, Inkbird/MEATER notify UUIDs, etc.).
2. On each notification, runs **heuristic decoders** (scaled int16, int32 °F, float32, MEATER/Inkbird layouts).
3. Picks the first reading in a plausible food range with highest confidence and **locks** that characteristic + method for the session.

To add a device in a PR: extend `ThermometerProfileRegistry.catalog` and `TemperatureDecoders.decode`.
