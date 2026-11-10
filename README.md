# lap-analysis

A native Mac app for reviewing AiM Solo 2 data: open `.xrk`/`.xrz` sessions,
overlay laps on distance, see where the time went, and compare against a
friend's laps. Race Studio 3 is Windows-only; this is the Mac (and eventually
iOS) take on its analysis side.

Status: early. See the table below for what exists.

| Area | State |
| --- | --- |
| XRK/XRZ parsing (Swift port of libxrk) | Implemented; golden-file test passes in CI |
| Distance resampling, time delta, splits, histogram | Implemented; unit tests pass in CI |
| Mac app: load sessions, lap table, channel + delta plots, track map, splits | First version; compiles in CI, not yet run by a human |
| Wi-Fi download from the Solo 2 | Not started; needs packet captures (`docs/wifi-protocol.md`) |
| Sharing laps with friends | For now: load their `.xrk` alongside yours |
| iOS | Not started; `LapCore` is kept UI-free for it |

## Run

Requires macOS 14+ and Xcode 15+.

```sh
swift run LapAnalysisApp      # or open Package.swift in Xcode and run
swift test
```

Then File > Open… (or drag in) one or more `.xrk`/`.xrz` files. Race Studio 3
stores downloads under `AIM_SPORT/RaceStudio3/user/data/`.

## Layout

- `Sources/LapCore` — parsing and maths, no UI imports
- `Sources/LapAnalysisApp` — SwiftUI app
- `docs/` — research notes, architecture, Wi-Fi protocol plan

## Credits

XRK format knowledge comes from [libxrk](https://github.com/m3rlin45/libxrk)
(MIT). See `NOTICE.md`. Not affiliated with AiM.
