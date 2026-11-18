# DualPod

**English** · [繁體中文](README.zh-TW.md)

A macOS menu bar app that plays your Mac's sound on two HomePod minis as left and right, even when they can't be paired as a stereo pair (for example, one of each generation). The Mac's own speakers can play along, aligned in time.

<img src="docs/menu.png" width="279" alt="DualPod menu: two HomePod minis playing left and right, plus This Mac">

## Why this exists

I happily bought a HomePod mini (2nd generation) to go with the first-generation one I already had, got it home, and found out the two can't be set up as a stereo pair. That was annoying enough to start this project.

## Requirements

- A Mac with Apple silicon, on macOS 14.4 or later.
- One or two HomePods on the same network as the Mac. Tested with HomePod mini, 1st and 2nd generation. The full-size HomePod shows up in DualPod's speaker list but hasn't been tested. Other AirPlay receivers don't show up.
- An administrator password to install, update, or remove the background helper (the part that does the streaming).

## Install

1. Download `DualPod-<version>.zip` from [Releases](https://github.com/NightLightTw/dualpod/releases), unzip it, and drag `DualPod.app` to Applications.
2. Open it. DualPod is free and isn't notarized by Apple, so macOS blocks it the first time with a message that Apple could not verify it. That message means the app hasn't been through Apple's paid notarization, not that malware was found. The source is in this repository if you'd rather build it yourself.
   - macOS 15 or later: click Done, open System Settings → Privacy & Security, scroll down, click Open Anyway next to DualPod, and enter your password.
   - macOS 14: Control-click the app in Finder, choose Open, then click Open.
3. DualPod asks "Install the background helper?". Click Install and enter your password.
4. Before selecting speakers, set the Home app to allow speaker access without a password, as described in [Home app setting](#home-app-setting). Otherwise the HomePods stay silent.
5. Click the DualPod icon (two overlapping rings) in the menu bar. HomePods on your network appear within a minute. Select the ones to play on.
6. The first time it plays, macOS asks for permission to record system audio. Allow it, or the speakers stay silent.

### Permissions, and why

| What | Why | If you said no |
|---|---|---|
| Administrator password | Installs the background helper that does the streaming and binds the network ports AirPlay timing needs. After that, switching speakers needs no password | Nothing streams |
| Record system audio | Captures what the Mac is playing so it can be sent to the speakers. It doesn't record the microphone, and the sound goes only to the speakers you selected | System Settings → Privacy & Security → Screen & System Audio Recording, turn on DualPod or audiotee (the audio capture tool inside DualPod), then deselect and reselect a speaker |
| Microphone (optional) | Only for Align Automatically, which lines up the Mac's speakers with the HomePods. It listens to the speakers for up to a minute | System Settings → Privacy & Security → Microphone |

After installing, System Settings → General → Login Items & Extensions lists a background item named **zsh**. That is DualPod's helper (a shell script run by launchd). Turning it off stops DualPod from playing.

### Home app setting

DualPod doesn't support HomeKit pairing or speaker passwords. In the Home app, open Home Settings → Speakers & TV, choose Anyone On the Same Network, and turn off Require Password. This lets anyone on your network play to the HomePods, so use DualPod on a home network you trust. If access is limited to people sharing the home, or a password is set, the HomePods stay silent and DualPod doesn't say why.

## Usage

Settings… is in the DualPod menu in the menu bar, not in System Settings. The app follows the system language, and you can change it in Settings… → General → Language.

- Select one HomePod: it plays the full stereo mix.
- Select two HomePods: one plays left, the other right. To check which is which, open Settings… → Audio → Stereo Pair and click a speaker. It chimes from that side. If they're backwards, click Swap Left and Right.
- Select This Mac too: the Mac's speakers play the full mix along with the HomePods. If you hear an echo, use Settings… → Audio → This Mac's Speakers → Align Automatically… in a quiet room.
- Each speaker has its own volume slider in the menu.
- Settings… → Glow lights up the top of the HomePods while streaming (Sound Glow). It needs HomePod software 27.2 and Sound Glow turned on in the Home app.
- Quit DualPod stops streaming and returns sound to the Mac.

<img src="docs/glow.png" width="400" alt="DualPod Settings, Glow pane with color presets">

## Known limitations

- The sound reaches the HomePods about 0.3 seconds after the Mac plays it. With music you won't notice. With video, the sound can trail the picture slightly.
- If the stream keeps failing, for example because Wi-Fi is down, DualPod gives up after more than 5 restarts in 5 minutes. Deselect and reselect a speaker when the network is back.
- If another device (an iPhone, another Mac) starts playing to a HomePod DualPod is using, DualPod steps aside instead of taking it back, and the menu offers "Take Them Back". A HomePod plays one source at a time, so both can't play together.
- With a VPN or several network interfaces active, DualPod may stream from the wrong one and the speakers stay silent. Turn off the VPN, then deselect and reselect a speaker.

## Troubleshooting

1. The menu says the background helper stopped, or offers to update it (this DualPod carries a different helper than the installed one, usually after you install another version): click that menu item to reinstall or update the helper.
2. Playing but no sound: check the recording permission and the Home app setting above, and turn off any VPN.
3. A HomePod doesn't appear: make sure it's on and on the same network as the Mac. The list refreshes about once a minute.
4. Still stuck: Settings… → General → Troubleshooting → Open Log Folder, or Copy Diagnostics to report it.

## Uninstall

Settings… → General → Background helper → Manage → Remove…, then move DualPod to the Trash. When the helper is stopped or needs an update, that page shows Remove the helper → Remove… instead of Manage.

If the app is already gone, remove the helper in Terminal. The names say AirPlay Stereo because that was DualPod's earlier name. Open Terminal (Applications → Utilities), paste the lines one at a time, and press Return after each. The first `sudo` asks for your Mac password, and nothing appears on screen while you type it.

```bash
sudo launchctl bootout system/local.airplay-stereo
sudo rm -f /Library/LaunchDaemons/local.airplay-stereo.plist
sudo rm -rf "/Library/Application Support/AirPlayStereo"
rm -rf ~/Library/Application\ Support/AirPlayStereo
```

## Reporting a problem

Open an [issue](https://github.com/NightLightTw/dualpod/issues) with your Mac model, macOS version, HomePod models and their software version, the DualPod version (in the Releases file name), and what you did before it went wrong. Paste the output of Copy Diagnostics if you can. It replaces IP addresses, device IDs, and speaker names with placeholders, but read it before posting.

## Privacy

- DualPod collects nothing. It finds speakers with Bonjour on the local network and sends sound only to the speakers you select.
- Its only internet connection is to GitHub, when it opens and once a day after that, to check for a newer version. The menu then shows the new version and links to its download page. Nothing is downloaded or installed automatically. Turn it off in Settings… → General → Check for updates automatically.
- Logs stay on the Mac, under `/Library/Application Support/AirPlayStereo/logs`. Session logs are deleted after 7 days.

## How it works

```
system audio ──audiotee (Core Audio process tap)──▶ stereotool split ──L──▶ cliairplay ──AirPlay 2──▶ speaker 1
                                                                     ├─R──▶ cliairplay ──AirPlay 2──▶ speaker 2
                                                                     └─LR─▶ localplay (This Mac)
                        one PTP clock (cliairplay --ptp-daemon), one shared start time
```

- `stereo.sh` is the background helper, a root LaunchDaemon. It finds speakers, starts and watches the stream, and reads the app's choices from files in `~/Library/Application Support/AirPlayStereo/`.
- `run_pair.sh` starts one streaming session.
- `app/` is the menu bar app (Swift, AppKit and SwiftUI). It installs the helper through macOS's own password dialog.
- `tools/stereotool` keeps the clock and splits the channels. `tools/localplay` plays the Mac's share in time.

On one test setup, the timing gap between the left and right HomePods measured 0.7 to 3.3 ms. Apple Music sending the same sound to both measured 0.5 to 2.2 ms, so DualPod's left/right timing is close to Apple Music's.

## Build from source

```bash
zsh scripts/fetch-deps.sh      # clone airplay-cli (cliairplay) and audiotee, apply patches/, build them
zsh app/build.sh               # app/DualPod.app for yourself
```

Requires an Apple silicon Mac and Xcode or the Command Line Tools.

Release zips are built from a fresh clone checked out at a `vX.Y.Z` tag:

```bash
zsh scripts/fetch-deps.sh && zsh app/build.sh dist   # writes dist/DualPod-X.Y.Z.zip
```

The dist build refuses to run if the checkout has uncommitted changes, or if the dependencies differ from the pinned commits plus `patches/`.

The measurement tools are for development only, used by the test and measure modes of `run_pair.sh`. They need Python with numpy and scipy, and Homebrew ffmpeg. Set them up with:

```bash
swiftc tools/rec.swift -o tools/rec
mkdir signals checks && python measure.py gen signals
```

## License and credits

Copyright (C) 2026 NightLightTw. DualPod is free software under the GNU General Public License, version 3. See [LICENSE](LICENSE).

DualPod streams with [cliairplay (airplay-cli)](https://github.com/music-assistant/airplay-cli) from Music Assistant and captures audio with [audiotee](https://github.com/makeusabrew/audiotee) by Nick Payne, both with small patches. Their licenses, the exact commits, and what was changed are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

DualPod is an independent project and is not affiliated with, endorsed by, or sponsored by Apple Inc. Apple, AirPlay, HomePod, HomePod mini, and Mac are trademarks of Apple Inc., registered in the U.S. and other countries and regions.
