DualPod install guide
繁體中文：安裝說明.txt

DualPod plays your Mac's sound on two HomePod minis as left and right, even when they can't be paired as a stereo pair. The Mac's own speakers can play along.

Needs
- An Apple silicon Mac on macOS 14.4 or later.
- One or two HomePods on the same network. Tested with HomePod mini, 1st and 2nd generation.
- Your admin password to install, update, or remove the background helper (the part that does the streaming).

Install
1. Unzip and drag "DualPod.app" to Applications.
2. Open it. DualPod is free and isn't notarized by Apple, so macOS says Apple could not verify it. That means it hasn't been notarized, not that malware was found.
   - macOS 15 or later: click Done, open System Settings → Privacy & Security, scroll down, click Open Anyway next to DualPod, and enter your password.
   - macOS 14: Control-click the app in Finder, choose Open, then click Open.
3. When asked "Install the background helper?", click Install and enter your password.
4. Before selecting speakers, set up the Home app as described in "Home app setting" below, or the HomePods stay silent.
5. Click the DualPod icon (two overlapping rings) in the menu bar. HomePods appear within a minute. Select the ones to play on.
6. The first time it plays, macOS asks to let it record system audio. Allow it, or the speakers stay silent.
   If you declined: System Settings → Privacy & Security → Screen & System Audio Recording, turn on DualPod or audiotee (the audio capture tool inside DualPod), then deselect and reselect a speaker.

Permissions
- Admin password: installs the background helper that does the streaming. After that, switching speakers needs no password.
- Record system audio: captures what the Mac plays and sends it only to the speakers you select. It doesn't record the microphone.
- Microphone (optional): only for Align Automatically, which lines up the Mac's speakers with the HomePods. To allow it later: System Settings → Privacy & Security → Microphone.

After installing, System Settings → General → Login Items & Extensions lists a background item named "zsh". That is DualPod's helper. Turning it off stops DualPod from playing.

Home app setting
DualPod doesn't support HomeKit pairing or speaker passwords. In the Home app, open Home Settings → Speakers & TV, choose Anyone On the Same Network, and turn off Require Password. This lets anyone on your network play to the HomePods, so use DualPod on a home network you trust. If access is limited to people sharing the home, or a password is set, the HomePods stay silent and DualPod doesn't say why.

Use
Settings… is in the DualPod menu in the menu bar, not in System Settings. The app follows the system language. Change it in Settings… → General → Language.
- One HomePod plays the full stereo mix.
- Two HomePods play left and right. Settings… → Audio → Stereo Pair: click a speaker to hear a chime from that side, and click Swap Left and Right if needed.
- Select This Mac too to play along on the Mac's speakers. If you hear an echo, use Settings… → Audio → This Mac's Speakers → Align Automatically… in a quiet room.
- Settings… → Glow lights up the HomePods while streaming (needs HomePod software 27.2 and Sound Glow on in the Home app).
- Quit DualPod stops streaming and returns sound to the Mac.

Known limitations
- Sound plays a little later than it would on the Mac alone, by about the buffer you pick in Settings (200 ms by default). When This Mac is also on, its speakers wait too, so all of them stay in time. With music you won't notice. With video, the sound can trail the picture slightly.
- If the stream keeps failing (for example, Wi-Fi is down), DualPod gives up after more than 5 restarts in 5 minutes. Deselect and reselect a speaker when the network is back.
- If another device plays to one of the HomePods, the two take turns grabbing it. Stop one of them.
- With a VPN or several active network interfaces, DualPod may stream from the wrong one and the speakers stay silent. Turn off the VPN, then deselect and reselect a speaker.

Troubleshooting
- The menu says the background helper stopped, or offers to update it (this DualPod carries a different helper than the installed one, usually after you install another version): click that item.
- Playing but no sound: check the recording permission and the Home app setting above, and turn off any VPN.
- A HomePod doesn't appear: make sure it's on and on the same network. The list refreshes about once a minute.
- Still stuck: Settings… → General → Troubleshooting has Open Log Folder and Copy Diagnostics.

Uninstall: Settings… → General → Background helper → Manage → Remove…, then move the app to the Trash. When the helper is stopped or needs an update, that page shows Remove the helper → Remove… instead of Manage.
If the app is already gone, run these in Terminal (AirPlay Stereo is DualPod's earlier name). Terminal is in Applications → Utilities. Paste one line at a time and press Return. The first sudo asks for your Mac password, and nothing appears on screen while you type it.
  sudo launchctl bootout system/local.airplay-stereo
  sudo rm -f /Library/LaunchDaemons/local.airplay-stereo.plist
  sudo rm -rf "/Library/Application Support/AirPlayStereo"
  rm -rf ~/Library/Application\ Support/AirPlayStereo

Report a problem: https://github.com/NightLightTw/dualpod/issues, with your Mac model, macOS version, HomePod models and software version, the DualPod version (the number in the download's file name), and the Copy Diagnostics output. It replaces IP addresses, device IDs, and speaker names with placeholders, but read it before posting.

Privacy: DualPod collects nothing, and logs stay on this Mac. Its only internet connection is to GitHub, when it opens and once a day after that, to check for a newer version. Nothing is downloaded or installed automatically. To turn it off: Settings… → General → Check for updates automatically.

License: GNU GPL version 3, see LICENSE and THIRD_PARTY_NOTICES.md in this folder.
Source: https://github.com/NightLightTw/dualpod (the release with the same version number as this download).
DualPod is an independent project and is not affiliated with, endorsed by, or sponsored by Apple Inc. Apple, AirPlay, HomePod, HomePod mini, and Mac are trademarks of Apple Inc., registered in the U.S. and other countries and regions.
