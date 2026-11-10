# Research notes: Race Studio 3 and the Solo 2

Compiled November 2026. Sources at the end.

## The pipeline RS3 implements

1. **Connect.** The Solo 2 is reachable only over Wi-Fi. RS3 discovers it on
   the local network and lists it under Connected Devices. Details and open
   questions: [wifi-protocol.md](wifi-protocol.md).
2. **Download.** The Download tab lists sessions on the logger; chosen ones
   are saved as `.xrk` (or `.xrz`, the same data zlib-compressed) under
   `AIM_SPORT/RaceStudio3/user/data/<date>/`.
3. **Analyse.** RS3 Analysis loads sessions into a database and presents them
   through layouts.

## What is in an .xrk

Per-channel sample streams at their own rates, plus header metadata and lap
markers. A Solo 2 (no ECU) records GPS position, speed, altitude and heading,
3-axis acceleration and gyro, and logger housekeeping channels; the DL variant
adds ECU channels. The logger also stores its own predictive-time and
lap-difference channels.

The format is proprietary but has been reverse-engineered by
[libxrk](https://github.com/m3rlin45/libxrk) (MIT), which ships an executable
spec and real test files. A TypeScript port (xrk-js) reports 99.97% sample
agreement with AiM's own DLL on newer expansion messages. Our Swift parser is
a port of libxrk.

## How the analyses are derived

Everything rests on two derived quantities per lap:

- **Lap boundaries** from the start/finish line crossing (the logger records
  them; the track database supplies the line coordinates).
- **Distance along the lap** from integrating speed over time.

With those, each view is a projection of the same data:

| RS3 layout | What it computes |
| --- | --- |
| Time/Distance | Any channel vs lap distance (or time), laps overlaid. Modes: overlapped, mixed, tiled; snap; zoom |
| Time compare (delta) | Time difference vs a reference lap at equal distance |
| Track map | GPS trace, optionally coloured by a channel; cursor linked to the plots |
| Split report | Track divided into segments; per-lap split times, best splits, theoretical best, statistics (mean, median…) |
| Histogram | Time spent per value band of a channel |
| Scatter (XY) | One channel vs another, e.g. lateral vs longitudinal g |
| Channels report | Min/max/avg per channel per lap |
| Math channels | User formulas over channels, with built-ins such as braking/coasting/throttle time and distance |
| Reference / predictive lap | A chosen lap becomes the baseline pushed back to the logger |
| Movies | Video synced to data (SmartyCam) |

## Existing alternatives

- **AimMac** (aimmac.app): free, closed source, macOS 14+ and Windows. Wi-Fi
  download, distance-based compare with Δt, RS3-syntax math channels, video
  overlays. No mobile app or friend sharing advertised. Proof that the Wi-Fi
  protocol can be implemented independently.
- **RS3 under Wine** (Rush-Auto-Works/aim-racestudio3-mac): runs the real RS3
  on Apple Silicon.
- **APEX Pro** mobile app imports Solo 2 `.xrk` over Wi-Fi; LapLift and Brake
  Point read `.xrk` in the browser.

Where this project aims to differ: open source, lap sharing with friends as a
first-class feature, and a shared core for iOS.

## Roadmap

1. v0.1 — open `.xrk/.xrz`, lap table, channel + delta plots, track map, splits (this commit).
2. Histogram, scatter (g-g), channels report views; track-map colouring by any channel; zoom/pan.
3. Session library with persistence; lap export/import as a small share file.
4. Wi-Fi download (after captures).
5. Math channels.
6. iOS app on the same `LapCore`.

## Sources

- AiM Solo 2 user guide: https://www.aimtechnologies.com/aim-support/docs/SOLO2-user-guide-100.pdf
- RS3 Analysis manual (contents): https://www.aim-sportline.com/aim-software-betas/Software/Docs/RSA3_101_eng_20240111_1500.pdf
- libxrk: https://github.com/m3rlin45/libxrk
- xrk-js: https://github.com/cyprien0312/xrk-js
- aim-racestudio3-mac: https://github.com/Rush-Auto-Works/aim-racestudio3-mac
- AimMac: https://aimmac.app/
- Brake Point XRK guide: https://www.brakepoint.io/en/guides/aim-xrk/
- APEX Pro Solo 2 import: https://apextrackcoach.com/2026/04/26/import-aim-solo-ii-xrk-files-into-the-apex-pro-app/
