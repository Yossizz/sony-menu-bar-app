# xm-menubar

An unofficial macOS menu bar companion for Sony 1000X headphones, with the WH-1000XM6 as the primary target.
It is not made or endorsed by Sony.

## Status: Phase 0 (protocol spike)

`xmctl` is a Swift command-line tool. It connects to paired headphones over Bluetooth RFCOMM and talks
Sony's MDR protocol through [libmdr](https://github.com/mos9527/SonyHeadphonesClient) (MIT).
That library's docs list the WH-1000XM6 as supported, including noise control, EQ, battery, and multipoint.

Phase 0 is done when, on a real XM6, you can:

- [x] `xmctl list` shows the headphones
- [x] `xmctl status <MAC>` prints the model, firmware, `protocol: V2`, battery %, and noise-control state
- [x] `xmctl anc <MAC> nc|ambient|off` changes the mode, and `after →` shows the new mode

Verified on 2026-11-11 with a **WF-1000XM6** (firmware 2.0.5) over protocol V2: battery L/R/case,
noise cancelling ↔ ambient (level 10), 10-band EQ read, DSEE read, and the feature list.
Not yet tried: a WH-1000XM6, writing EQ, or the WH-1000XM4 (V1).

## Phase 2: menu bar app (XMBar)

`XMBar.app` is a menu bar-only app (no Dock icon). The menu bar shows a headphones or earbuds icon and the
lowest earbud battery percentage. Clicking it opens a panel with:

- the device picker, connection state, and firmware version
- battery for left, right, and the case
- noise control: Off, Noise Cancelling, or Ambient, plus the ambient level slider, automatic ambient, and focus on voice
- Connect, Disconnect, and Quit

It connects automatically at launch, and again whenever the selected headphones connect to the Mac. It
disconnects when they leave. Battery refreshes every 60 s. Changes made on the headphones themselves also
show up in the panel.

### Phase 3: headphone settings (the Sound and Settings tabs)

- **Sound:** EQ preset picker, a slider for each band (labeled by frequency; editing a band switches to
  Custom, as Sony's app does), Flat, Clear Bass on models that have it, and DSEE.
- **Settings:** Speak-to-Chat (on/off, voice detection, end after), touch controls, auto power-off,
  turn off when removed, and pause when removed. Each appears only if the headphones offer it.
- **Controls:** listening mode, shown when the device offers more than Standard.

### Phase 4: Mac integration

- **Launch at login** (`SMAppService`). macOS may ask you to allow it under Login Items.
- **Low-battery alerts** at 10, 15, 20, or 30%, once per earbud each time it drops below the threshold.
  Connect and disconnect notifications are optional.
- **Sound output:** "Use for Mac sound" button. By default the Mac's output also switches automatically when
  the headphones connect. The CoreAudio device is matched by the Bluetooth address in its UID.
- **Switching headphones:** picking another paired headset in the device picker opens its Bluetooth link,
  connects the control channel, and moves the Mac's sound to it.

### Tested on a WF-1000XM6 (FW 2.0.5) with `xmctl`

| Setting | Write result |
|---|---|
| EQ preset (Heavy ↔ Clear) | ✅ applied |
| EQ bands (switches to Custom automatically) | ✅ applied |
| DSEE on/off | ✅ applied |
| Speak-to-Chat on/off | ✅ applied |
| Touch controls | ❌ the earbuds ACK the command but keep the old mapping (tried 3 actions). The app reports this rather than snapping back silently. |
| Auto power-off | n/a: the device offers only "Never" |
| Listening mode | n/a: the device offers only Standard |

```bash
./scripts/bundle-app.sh
```

```bash
open build/XMBar.app
```

## Layout

| Path | What |
|---|---|
| `vendor/SonyHeadphonesClient` | git submodule, pinned to `ce2e54c`, the source of libmdr and libmdr-bt |
| `scripts/build-libmdr.sh` | builds `libmdr.a`, `libmdr-bt.a`, and `libfmt.a` into `build/lib` with CMake |
| `Sources/CMDR` | module map that exposes the libmdr C API (`mdr-c/*.h`) to Swift |
| `Sources/XMKit` | Swift helpers over libmdr shared by both targets: the blocking `Session`, device list, settings readers and writers (`Settings.swift`), CoreAudio output (`AudioOutput.swift`) |
| `Sources/xmctl` | the CLI |
| `Sources/XMBar` | the menu bar app: `HeadphonesController` (a non-blocking libmdr event loop) and the SwiftUI views |
| `scripts/bundle-app.sh` | builds `build/XMBar.app` and ad-hoc signs it |

## Build

```bash
brew install cmake ninja
```

```bash
git submodule update --init
```

```bash
./scripts/build-libmdr.sh
```

```bash
swift build
```

## Try it with your XM6

Pair the headphones in System Settings → Bluetooth first. The first run may ask for Bluetooth permission
for the app you launch it from (Terminal, iTerm, …).

```bash
.build/debug/xmctl list
```

```bash
.build/debug/xmctl status AA:BB:CC:DD:EE:FF -v
```

```bash
.build/debug/xmctl anc AA:BB:CC:DD:EE:FF ambient --level 10 --voice
```

Add `--trace` to dump every TX/RX frame as hex, which is useful for checking the protocol by hand.
Use `--v2` or `--v1` to force a protocol instead of trying V2, then V1.

## Notes

- **Bluetooth permission (TCC):** macOS charges Bluetooth access to the *responsible* app, meaning whatever
  launched the CLI. If that app has no Bluetooth usage string, the process is killed (`SIGABRT`, namespace
  TCC). `xmctl` re-spawns itself with responsibility disclaimed, so macOS uses its own embedded Info.plist.
  See `Responsibility.swift`. The menu bar `.app` won't need this.
- **WF-1000XM6 (earbuds) vs WH-1000XM6 (over-ear):** libmdr lists the WF-1000XM6 EQ as partial (🔄), and
  "pause when removed" as unsupported. See `vendor/SonyHeadphonesClient/docs/device-support/WF-1000XM6.md`.
- The control channel needs an active Bluetooth link. Earbuds in their case, or connected only to a phone,
  produce a "paired but not connected" error.

- The macOS backend runs all IOBluetooth work on the main queue, so the CLI pumps the main run loop between
  `mdrHeadphonesPoll` calls. See `pumpRunLoop` in `Session.swift`. The menu bar app will need the same
  arrangement, or a dedicated thread with its own run loop.
- The XM5 and XM6 advertise the V2 SDP service `956C7B26-…`; the XM4 and older advertise V1 `96CC203E-…`.
- macOS sends Bluetooth audio as AAC, so LDAC is not available regardless of this app.
