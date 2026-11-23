# XMBar

A macOS menu bar app for Sony 1000X headphones and earbuds. Check battery, switch noise cancelling, tune the
EQ, and manage multipoint without reaching for your phone.

> **Unofficial.** XMBar isn't made, endorsed or supported by Sony. It talks to the headphones with the same
> Bluetooth protocol as Sony's app, through the open-source [libmdr](https://github.com/mos9527/SonyHeadphonesClient)
> library. Sony product names belong to Sony.

## Features

The menu bar shows your earbuds or headphones with their battery level. The number turns orange when the
battery runs low and red at 10%. Click it for the panel:

**Controls**
- Battery for left, right and the case, with an in-ear indicator per earbud
- Noise control (Noise Cancelling, Ambient or Off), the ambient level, automatic ambient and Focus on Voice
- Now playing: track info when the source device sends it, previous / play-pause / next, and volume
- Listening modes, on headphones that offer them

**Sound**
- EQ presets plus a slider for each band. Editing a band switches to Custom, as in Sony's app.
- Clear Bass and DSEE upscaling, where supported

**Devices** (multipoint)
- The phones and computers your headphones are connected to, and which one is playing
- Choose the device to play from, and connect or disconnect devices
- Turn automatic source switching on or off

**Settings**
- Speak-to-Chat with voice detection and timeout, touch controls, auto power-off, and turn off or pause when
  removed
- **Pause when an earbud is removed:** taking an earbud out pauses playback, and putting both back resumes it
- Low-battery notifications (10–30%), connect/disconnect notifications, launch at login
- Use the headphones for Mac sound automatically when they connect

**Mac integration**
- Connects automatically when your headphones connect to the Mac, and reconnects after they've been in the case
- Switch between several paired Sony headphones from the ⋯ menu. XMBar connects them and moves the Mac's sound
  to them.

Each control appears only if your model supports it.

## Supported headphones

XMBar works with the models libmdr supports, which covers the 1000X series and several other Sony models.
See libmdr's [device support notes](https://github.com/mos9527/SonyHeadphonesClient/tree/main/docs/device-support).

| Model | Protocol | Tested with XMBar |
|---|---|---|
| WF-1000XM6 | V2 | ✅ Firmware 2.0.5: battery, noise control, EQ presets and bands, DSEE, Speak-to-Chat, multipoint list, wearing status |
| WH-1000XM6, WH/WF-1000XM5 | V2 | Not yet; supported by libmdr |
| WH-1000XM4, WH-1000XM3 | V1 | Not yet; V1 offers fewer settings |

## Install

1. Download `XMBar-<version>.dmg` from [Releases](https://github.com/Yossizz/sony-menu-bar-app/releases).
2. Open it and drag **XMBar** into **Applications**.
3. XMBar isn't notarized by Apple, so macOS blocks it on first launch. Allow it once, using one of these:
   - right-click XMBar in Applications, choose **Open**, then confirm;
   - try to open it, then go to **System Settings → Privacy & Security** and click **Open Anyway**;
   - or run `xattr -dr com.apple.quarantine /Applications/XMBar.app`.
4. Allow Bluetooth access when asked.

Requires macOS 13 (Ventura) or later. Pair your headphones in **System Settings → Bluetooth** first. XMBar
finds paired headphones on its own.

## Known limitations

- **Touch controls on the WF-1000XM6** (firmware 2.0.5): the earbuds accept the command but keep their old
  mapping. XMBar tells you when that happens. Use Sony's app to change them on this model.
- **LDAC:** macOS streams Bluetooth audio as AAC, whatever app you use.
- **Track info** appears only when the playing device sends it to the headphones.
- XMBar needs an active Bluetooth connection to the headphones. Earbuds in their case, or connected only
  to your phone, show as "not connected to this Mac". Use **Connect** in the panel to bring them over.

## Building from source

Requirements: macOS 13+, the Xcode Command Line Tools (or Xcode), and CMake ≥ 3.31 plus Ninja.

```bash
brew install cmake ninja
```

```bash
git clone --recursive https://github.com/Yossizz/sony-menu-bar-app.git && cd sony-menu-bar-app
```

Build libmdr. This only needs to run once, or again after the submodule is updated:

```bash
./scripts/build-libmdr.sh
```

Build and launch the app (this writes `build/XMBar.app`):

```bash
./scripts/bundle-app.sh && open build/XMBar.app
```

To build everything, including the `xmctl` command-line tool:

```bash
swift build
```

If you cloned without `--recursive`, run `git submodule update --init` first.

## `xmctl` command-line tool

`xmctl` uses the same code as the app, and is handy for scripting or checking a model. Find your headphones'
address with `list`, then pass it to the other commands. Quit XMBar first, because only one app can hold the
headphones' control connection at a time.

| Command | What it does |
|---|---|
| `xmctl list` | Paired Bluetooth devices, and whether each is connected |
| `xmctl status <MAC>` | Model, firmware, battery, noise control, EQ, all settings and features |
| `xmctl anc <MAC> off\|nc\|ambient [--level N] [--voice]` | Set noise control |
| `xmctl eq <MAC> <preset-id>` | Pick an EQ preset (`status` lists the ids) |
| `xmctl eqbands <MAC> v1,v2,…` | Set every EQ band (switches to Custom) |
| `xmctl dsee <MAC> on\|off` | DSEE upscaling |
| `xmctl stc <MAC> on\|off` | Speak-to-Chat |
| `xmctl control <MAC> <key> <action>` | Remap a touch control (`status` lists the ids) |
| `xmctl autooff <MAC> <minutes>` | Auto power-off (0 = never) |
| `xmctl output` | Which Mac sound output belongs to each connected headset |

Options: `-v` for progress output, `--trace` to dump every Bluetooth frame as hex, and `--v1` / `--v2` to force a
protocol version.

## Development

### Layout

| Path | What |
|---|---|
| `vendor/SonyHeadphonesClient` | Git submodule with libmdr (the protocol) and libmdr-bt (Bluetooth transports) |
| `scripts/build-libmdr.sh` | Builds `libmdr.a`, `libmdr-bt.a` and `libfmt.a` into `build/lib` with CMake |
| `Sources/CMDR` | Module map that exposes libmdr's C API to Swift |
| `Sources/XMKit` | Swift helpers shared by both targets: the blocking `Session`, settings and connectivity readers and writers, CoreAudio output |
| `Sources/XMBar` | The app: `HeadphonesController` (a non-blocking libmdr event loop), the SwiftUI panel, the product icons |
| `Sources/xmctl` | The command-line tool |
| `scripts/bundle-app.sh` | Builds and ad-hoc signs `XMBar.app` (`VERSION=…` stamps a version) |
| `scripts/make-dmg.sh` | Packages the app into a DMG |

### How it works

- Headphones expose a Bluetooth Classic RFCOMM service. XM5 and newer use protocol V2 (SDP UUID `956C7B26-…`),
  and XM4 and older use V1 (`96CC203E-…`). XMBar tries V2, then V1.
- libmdr's macOS backend runs all IOBluetooth work on the main queue. The app polls libmdr from a main-run-loop
  timer, and `xmctl` pumps the run loop itself.
- Writes are staged and then committed once the device is ready. The panel always shows libmdr's *desired*
  value: your latest edit while it's in flight, and the device's own report once it settles.
- **Bluetooth permission and the CLI:** macOS charges Bluetooth access to the app that launched a process.
  `xmctl` re-launches itself as its own "responsible" process so that macOS uses `xmctl`'s embedded Info.plist
  (see `Responsibility.swift`).
- The macOS SDK implements SwiftUI's `@State` as a macro whose plugin doesn't ship with the Command Line Tools.
  View state therefore lives on `ObservableObject`s or `@AppStorage` instead.

### Debugging

- `XMBar --render-icons <dir>` writes PNG previews of the icons.
- `XMBar --debug-hooks` logs device events and accepts distributed notifications that run the same code as the
  panel buttons, so you can test against real headphones from a script:
  `local.xm-menubar.debug.setMode` (`off` / `nc` / `ambient`), `.playback` (`play` / `pause` / `next` /
  `previous`), and `.fakeBattery` (a percentage, or empty to clear it).

### CI and releases

- **Build** (`.github/workflows/build.yml`): runs on every push to `main` and on every pull request. It builds on
  macOS 15, caching libmdr by submodule commit, and uploads `XMBar.zip`.
- **Release** (`.github/workflows/release.yml`): runs when you push a `v*` tag. It stamps the version from the
  tag, builds the DMG and zip, and publishes a GitHub Release with install notes.

To cut a release:

```bash
git tag -a v0.4.0 -m "XMBar 0.4.0" && git push origin v0.4.0
```

## License

Copyright © 2026 Yossizz. Licensed under the [Apache License 2.0](LICENSE).

You're welcome to use, modify and share XMBar, **with credit**. If you redistribute it, or anything built
from it, in source or binary form, you must:
- keep the [NOTICE](NOTICE) file, which credits the original author, and include the license;
- mark the files you changed.

Third-party components keep their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The app
bundle ships LICENSE, NOTICE and the third-party notices.

## Credits

Built on [libmdr / SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) by
[@mos9527](https://github.com/mos9527), which continues [plutoberth's original project](https://github.com/plutoberth/SonyHeadphonesClient).
Both are MIT-licensed. Thanks to everyone who reverse-engineered the protocol and reported devices there.
