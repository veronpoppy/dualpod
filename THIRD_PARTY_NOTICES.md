# Third-party notices

DualPod is licensed under the GNU General Public License, version 3 (see [LICENSE](LICENSE)). The release zip bundles two programs built from other projects: cliairplay (from the airplay-cli repository) and audiotee. Both are fetched from upstream and patched by the source repository's [scripts/fetch-deps.sh](scripts/fetch-deps.sh), using the patches in its [patches/](patches) folder. Neither scripts/ nor patches/ is in the release zip. The source, scripts, and patches for each release are in the DualPod repository, https://github.com/NightLightTw/dualpod, under the matching tag (tag vX.Y.Z for DualPod-X.Y.Z.zip). The first line of each patch states who made the change and when (DualPod's changes date from November 2026).

## cliairplay (airplay-cli)

- Source: https://github.com/music-assistant/airplay-cli, commit `0a58c239d5fb3cf8927b9707a71c6fe897266b6a`
- License: GNU General Public License, version 3. Its own third-party components (libraop, mdnssd, OpenSSL, ALAC, and others) are listed in [third_party/cliairplay-THIRD_PARTY_NOTICES.md](third_party/cliairplay-THIRD_PARTY_NOTICES.md), copied from upstream unchanged. Where that file says to `git clone --recursive` its repository, the equivalent here is to clone this repository at the release tag and run `scripts/fetch-deps.sh`.
- OpenSSL: the build uses `STATIC=1`, which links the prebuilt static library that libraop ships for macOS arm64. That library is **OpenSSL 3.5.4** (Apache License 2.0, compatible with GPLv3), not the 1.1.1u listed in the upstream notices. Its source: https://github.com/openssl/openssl/releases/tag/openssl-3.5.4 The full Apache License 2.0 text is in the cliairplay notices file linked above.
- Known upstream ambiguity: libraop's `pairing.cpp` and `bplist.cpp` carry no explicit license grant (see "Note on libraop's license" in the upstream notices). The upstream project distributes binaries containing them under GPLv3, and DualPod distributes them the same way.
- Patches:
  - `patches/airplay-cli/0001-upstream-pr100-homepod-mini-2-ptp.diff` is the change proposed upstream in music-assistant/airplay-cli pull request #100 by Jonathan Delgado. It fixes the HomePod mini (2nd generation) staying silent.
  - `patches/airplay-cli/0002-bind-ptp-to-interface-on-macos.diff` binds PTP ports 319/320 to the chosen interface address, because macOS's own gPTP holds the wildcard sockets.
  - `patches/airplay-cli/0003-log-retransmit-requests.diff` logs, every 5 seconds and when a stream stops, how many lost packets the speaker asked to have resent, and how long after a packet was sent the request for it arrived. DualPod uses it to tell whether a smaller buffer leaves too little time to recover lost packets.

## audiotee

- Source: https://github.com/makeusabrew/audiotee, commit `56ac954369a09318e46b88a6eec33c2d2b0d32a3`
- License: MIT
- Patches:
  - `patches/audiotee/0001-converter-supply-input-once.diff` hands each input chunk to the sample-rate converter once. The unpatched converter replayed the chunk when asked for more input, which added an audible hiss to music.
  - `patches/audiotee/0002-log-chunk-age.diff` logs, every 10 seconds, how old the last captured sample is when each capture callback writes its last chunk out (not counting the resampler). DualPod uses it to measure latency.

```
The MIT License

Copyright (C) 2025 Nick Payne.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit
persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
