# Solo 2 Wi-Fi: what is known and how we find out the rest

AiM does not publish the protocol Race Studio 3 (RS3) uses to talk to its
loggers. This page separates what is established from what still has to be
captured from a real device.

## Established

From AiM's Solo 2 user guide:

- Default mode is access point: the Solo 2 creates a WPA2-PSK network named
  `AiM-Solo2-<serial>` (plus an optional suffix of up to 8 characters) for one computer.
- Alternative "existing network" mode: logger and computer both join a router's WLAN.
- Two password levels: network password and a per-device password.
- Wi-Fi setting on the device: ON, OFF, or AUTO (on when stopped, off once
  recording starts — speed above 10 km/h for 3 s with GPS fix).
- The RS3 Download tab lists stored sessions with lap count, best lap, date/time and size.

From the community RS3-on-Mac wrapper
([Rush-Auto-Works/aim-racestudio3-mac](https://github.com/Rush-Auto-Works/aim-racestudio3-mac),
`installer/bridge/`), which relays RS3's traffic and so documents its shape:

- The logger is the gateway of its own /24: `10.0.0.1`, `11.0.0.1` or `12.0.0.1`.
- **UDP 36002** carries discovery and keepalive ("aim-ka"). RS3 sends, the
  logger replies from `:36002`. The logger answers ephemeral source ports.
- **TCP 2000** is the data channel (session list, download, configuration).
- The TCP session is keepalive-gated: when UDP keepalives stop, the logger
  closes the TCP connection after about a second.

## Unknown (needs captures)

- UDP discovery/keepalive payload and reply layout (device name, serial, firmware?).
- TCP framing: headers, command IDs, checksums.
- Commands for: list sessions, download a session (does it arrive as `.xrk`
  bytes or get assembled by RS3?), device password authentication.
- Whether anything is encrypted beyond WPA2 (nothing suggests so; unverified).

## Capture plan

Needs: the Solo 2, a Windows machine or VM running RS3, Wireshark.

1. Join the Solo 2's Wi-Fi from the RS3 machine. Start Wireshark on that
   interface with filter `udp.port == 36002 || tcp.port == 2000`.
2. Capture each of these as a separate `.pcapng`, noting what was clicked when:
   1. RS3 launch through the device appearing in "Connected Devices" (idle 30 s).
   2. Opening the Download tab (session list).
   3. Downloading one small session. Keep the resulting `.xrk`.
   4. Downloading a second, different session.
3. Put captures and matching `.xrk` files in `captures/` (git-ignored; they
   contain your device serial and GPS traces).

With those, the work is: diff the two downloads to isolate framing from
payload, locate the `.xrk` bytes inside the TCP stream, then implement
`LapCore/Device` on `Network.framework` (`NWConnection` UDP + TCP) and test it
against a replay server built from the captures before touching the real device.

## Scope and safety

Read-only operations first (discover, list, download). Writing configuration
or firmware to the logger is out of scope until download is solid, because a
malformed write could leave the device needing recovery.

macOS notes: the app will need the Local Network permission, and joining the
logger's SSID programmatically uses CoreWLAN (macOS) or
`NEHotspotConfiguration` (iOS).
